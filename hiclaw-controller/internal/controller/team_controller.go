package controller

import (
	"context"
	"fmt"
	"time"

	v1beta1 "github.com/hiclaw/hiclaw-controller/api/v1beta1"
	"github.com/hiclaw/hiclaw-controller/internal/agentconfig"
	"github.com/hiclaw/hiclaw-controller/internal/backend"
	"github.com/hiclaw/hiclaw-controller/internal/executor"
	"github.com/hiclaw/hiclaw-controller/internal/gateway"
	"github.com/hiclaw/hiclaw-controller/internal/matrix"
	"github.com/hiclaw/hiclaw-controller/internal/oss"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// TeamReconciler reconciles Team resources using pure Go service clients.
type TeamReconciler struct {
	client.Client

	Matrix      matrix.Client
	Gateway     gateway.Client
	OSS         oss.StorageClient
	OSSAdmin    oss.StorageAdminClient
	AgentConfig *agentconfig.Generator
	Backend     *backend.Registry
	Creds       CredentialStore

	Executor *executor.Shell
	Packages *executor.PackageResolver

	KubeMode          string
	ManagerConfigPath string
	AgentFSDir        string
	WorkerAgentDir    string
	RegistryPath      string
	StoragePrefix     string
	MatrixDomain      string
	AdminUser         string
}

func (r *TeamReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx)

	var team v1beta1.Team
	if err := r.Get(ctx, req.NamespacedName, &team); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	if !team.DeletionTimestamp.IsZero() {
		if controllerutil.ContainsFinalizer(&team, finalizerName) {
			if err := r.handleDelete(ctx, &team); err != nil {
				logger.Error(err, "failed to delete team", "name", team.Name)
				return reconcile.Result{RequeueAfter: 30 * time.Second}, err
			}
			controllerutil.RemoveFinalizer(&team, finalizerName)
			if err := r.Update(ctx, &team); err != nil {
				return reconcile.Result{}, err
			}
		}
		return reconcile.Result{}, nil
	}

	if !controllerutil.ContainsFinalizer(&team, finalizerName) {
		controllerutil.AddFinalizer(&team, finalizerName)
		if err := r.Update(ctx, &team); err != nil {
			return reconcile.Result{}, err
		}
	}

	switch team.Status.Phase {
	case "", "Failed":
		return r.handleCreate(ctx, &team)
	default:
		return r.handleUpdate(ctx, &team)
	}
}

func (r *TeamReconciler) handleCreate(ctx context.Context, t *v1beta1.Team) (reconcile.Result, error) {
	logger := log.FromContext(ctx)
	logger.Info("creating team", "name", t.Name)

	t.Status.Phase = "Pending"
	t.Status.TotalWorkers = len(t.Spec.Workers)
	if err := r.Status().Update(ctx, t); err != nil {
		return reconcile.Result{}, err
	}

	managerMatrixID := r.Matrix.UserID("manager")
	adminMatrixID := r.Matrix.UserID(r.AdminUser)
	leaderMatrixID := r.Matrix.UserID(t.Spec.Leader.Name)

	// --- Step 1: Create Team Room (Leader + Admin + all Workers) ---
	logger.Info("creating team room", "team", t.Name)
	teamInvites := []string{adminMatrixID, leaderMatrixID}
	for _, w := range t.Spec.Workers {
		teamInvites = append(teamInvites, r.Matrix.UserID(w.Name))
	}
	teamPowerLevels := map[string]int{
		managerMatrixID: 100,
		adminMatrixID:   100,
		leaderMatrixID:  100,
	}

	teamRoom, err := r.Matrix.CreateRoom(ctx, matrix.CreateRoomRequest{
		Name:           fmt.Sprintf("Team: %s", t.Name),
		Topic:          fmt.Sprintf("Team room for %s", t.Name),
		Invite:         teamInvites,
		PowerLevels:    teamPowerLevels,
		ExistingRoomID: t.Status.TeamRoomID,
	})
	if err != nil {
		return r.failTeam(ctx, t, fmt.Sprintf("team room creation failed: %v", err))
	}
	t.Status.TeamRoomID = teamRoom.RoomID
	logger.Info("team room ready", "roomID", teamRoom.RoomID)

	// --- Step 2: Create Leader DM Room (Leader + Admin, optionally Team Admin) ---
	leaderDMInvites := []string{adminMatrixID, leaderMatrixID}
	if t.Spec.Admin != nil && t.Spec.Admin.MatrixUserID != "" {
		leaderDMInvites = append(leaderDMInvites, t.Spec.Admin.MatrixUserID)
	}
	leaderDMRoom, err := r.Matrix.CreateRoom(ctx, matrix.CreateRoomRequest{
		Name:        fmt.Sprintf("Leader DM: %s", t.Spec.Leader.Name),
		Topic:       fmt.Sprintf("DM channel for team leader %s", t.Spec.Leader.Name),
		Invite:      leaderDMInvites,
		PowerLevels: teamPowerLevels,
	})
	if err != nil {
		return r.failTeam(ctx, t, fmt.Sprintf("leader DM room creation failed: %v", err))
	}
	logger.Info("leader DM room ready", "roomID", leaderDMRoom.RoomID)
	t.Status.LeaderDMRoomID = leaderDMRoom.RoomID

	// --- Step 3: Write inline configs for leader + workers ---
	if t.Spec.Leader.Identity != "" || t.Spec.Leader.Soul != "" || t.Spec.Leader.Agents != "" {
		agentDir := fmt.Sprintf("%s/%s", r.AgentFSDir, t.Spec.Leader.Name)
		if err := executor.WriteInlineConfigs(agentDir, "", t.Spec.Leader.Identity, t.Spec.Leader.Soul, t.Spec.Leader.Agents); err != nil {
			return r.failTeam(ctx, t, fmt.Sprintf("write leader inline configs failed: %v", err))
		}
	}
	for _, w := range t.Spec.Workers {
		if w.Identity != "" || w.Soul != "" || w.Agents != "" {
			agentDir := fmt.Sprintf("%s/%s", r.AgentFSDir, w.Name)
			if err := executor.WriteInlineConfigs(agentDir, w.Runtime, w.Identity, w.Soul, w.Agents); err != nil {
				return r.failTeam(ctx, t, fmt.Sprintf("write worker %s inline configs failed: %v", w.Name, err))
			}
		}
	}

	// --- Step 4: Create Worker CRs (leader + workers) ---
	leaderCR := r.buildLeaderCR(t)
	if err := r.createOrUpdateWorkerCR(ctx, leaderCR); err != nil {
		return r.failTeam(ctx, t, fmt.Sprintf("create leader Worker CR failed: %v", err))
	}
	logger.Info("leader Worker CR created", "name", t.Spec.Leader.Name)

	// Worker CRs with worker role
	for _, w := range t.Spec.Workers {
		workerCR := r.buildWorkerCR(t, w, "worker", t.Spec.Leader.Name, t.Name)
		if err := r.createOrUpdateWorkerCR(ctx, workerCR); err != nil {
			logger.Error(err, "failed to create team worker CR (non-fatal)", "worker", w.Name)
		} else {
			logger.Info("team worker CR created", "name", w.Name)
		}
	}

	// --- Step 4.5: Inject coordination context for leader ---
	leaderAgentPrefix := fmt.Sprintf("agents/%s", t.Spec.Leader.Name)
	teamWorkers := make([]agentconfig.TeamWorkerInfo, 0, len(t.Spec.Workers))
	for _, w := range t.Spec.Workers {
		teamWorkers = append(teamWorkers, agentconfig.TeamWorkerInfo{
			Name: w.Name,
		})
	}
	coordCtx := agentconfig.CoordinationContext{
		WorkerName:     t.Spec.Leader.Name,
		Role:           "team_leader",
		MatrixDomain:   r.MatrixDomain,
		TeamName:       t.Name,
		TeamRoomID:     teamRoom.RoomID,
		LeaderDMRoomID: leaderDMRoom.RoomID,
		TeamWorkers:    teamWorkers,
	}
	if t.Spec.Admin != nil {
		coordCtx.TeamAdminID = t.Spec.Admin.MatrixUserID
	}
	existing, _ := r.OSS.GetObject(ctx, leaderAgentPrefix+"/AGENTS.md")
	injected := agentconfig.InjectCoordinationContext(string(existing), coordCtx)
	if err := r.OSS.PutObject(ctx, leaderAgentPrefix+"/AGENTS.md", []byte(injected)); err != nil {
		logger.Error(err, "leader coordination context injection failed (non-fatal)")
	}

	// --- Expose ports for team workers ---
	workerExposed := make(map[string][]v1beta1.ExposedPortStatus)
	for _, w := range t.Spec.Workers {
		if len(w.Expose) > 0 {
			exposed, exposeErr := ReconcileExpose(ctx, r.Gateway, w.Name, w.Expose, nil)
			if exposeErr != nil {
				logger.Error(exposeErr, "failed to expose ports for team worker (non-fatal)", "worker", w.Name)
			}
			if len(exposed) > 0 {
				workerExposed[w.Name] = exposed
			}
		}
	}

	_ = r.Get(ctx, client.ObjectKeyFromObject(t), t)
	t.Status.Phase = "Active"
	t.Status.LeaderReady = true
	t.Status.ReadyWorkers = len(t.Spec.Workers)
	t.Status.TeamRoomID = teamRoom.RoomID
	t.Status.LeaderDMRoomID = leaderDMRoom.RoomID
	t.Status.Message = ""
	if len(workerExposed) > 0 {
		t.Status.WorkerExposedPorts = workerExposed
	}
	if err := r.Status().Update(ctx, t); err != nil {
		logger.Error(err, "failed to update team status (non-fatal)")
	}

	logger.Info("team created", "name", t.Name, "teamRoomID", teamRoom.RoomID)
	return reconcile.Result{}, nil
}

func (r *TeamReconciler) handleUpdate(ctx context.Context, t *v1beta1.Team) (reconcile.Result, error) {
	// TODO: detect worker list changes and reconcile Worker CRs
	return reconcile.Result{}, nil
}

func (r *TeamReconciler) handleDelete(ctx context.Context, t *v1beta1.Team) error {
	logger := log.FromContext(ctx)
	logger.Info("deleting team", "name", t.Name)

	// Clean up exposed ports for team workers
	for _, w := range t.Spec.Workers {
		var currentExposed []v1beta1.ExposedPortStatus
		if t.Status.WorkerExposedPorts != nil {
			currentExposed = t.Status.WorkerExposedPorts[w.Name]
		}
		if len(currentExposed) == 0 && len(w.Expose) > 0 {
			for _, ep := range w.Expose {
				currentExposed = append(currentExposed, v1beta1.ExposedPortStatus{
					Port:   ep.Port,
					Domain: domainForExpose(w.Name, ep.Port),
				})
			}
		}
		if len(currentExposed) > 0 {
			if _, err := ReconcileExpose(ctx, r.Gateway, w.Name, nil, currentExposed); err != nil {
				logger.Error(err, "failed to clean up exposed ports for team worker (non-fatal)", "worker", w.Name)
			}
		}
	}

	// Delete Worker CRs (workers first, then leader)
	ns := t.Namespace
	for _, w := range t.Spec.Workers {
		workerCR := &v1beta1.Worker{}
		workerCR.Name = w.Name
		workerCR.Namespace = ns
		if err := r.Delete(ctx, workerCR); err != nil {
			logger.Error(err, "failed to delete team worker CR (may not exist)", "worker", w.Name)
		}
	}
	leaderCR := &v1beta1.Worker{}
	leaderCR.Name = t.Spec.Leader.Name
	leaderCR.Namespace = ns
	if err := r.Delete(ctx, leaderCR); err != nil {
		logger.Error(err, "failed to delete team leader CR (may not exist)", "leader", t.Spec.Leader.Name)
	}

	// Clean up teams-registry (legacy, embedded mode)
	if r.Executor != nil {
		_, err := r.Executor.RunSimple(ctx,
			"/opt/hiclaw/agent/skills/team-management/scripts/manage-teams-registry.sh",
			"--action", "remove", "--team-name", t.Name,
		)
		if err != nil {
			logger.Error(err, "failed to remove team from registry (non-fatal)")
		}
	}

	logger.Info("team deleted", "name", t.Name)
	return nil
}

func (r *TeamReconciler) buildLeaderCR(t *v1beta1.Team) *v1beta1.Worker {
	return &v1beta1.Worker{
		ObjectMeta: metav1.ObjectMeta{
			Name:      t.Spec.Leader.Name,
			Namespace: t.Namespace,
			Annotations: map[string]string{
				"hiclaw.io/role": "team_leader",
				"hiclaw.io/team": t.Name,
			},
			Labels: map[string]string{
				"hiclaw.io/team": t.Name,
				"hiclaw.io/role": "team_leader",
			},
		},
		Spec: v1beta1.WorkerSpec{
			Model:         t.Spec.Leader.Model,
			Identity:      t.Spec.Leader.Identity,
			Soul:          t.Spec.Leader.Soul,
			Agents:        t.Spec.Leader.Agents,
			Package:       t.Spec.Leader.Package,
			ChannelPolicy: t.Spec.Leader.ChannelPolicy,
		},
	}
}

func (r *TeamReconciler) buildWorkerCR(t *v1beta1.Team, w v1beta1.TeamWorkerSpec, role, leaderName, teamName string) *v1beta1.Worker {
	annotations := map[string]string{
		"hiclaw.io/role": role,
		"hiclaw.io/team": teamName,
	}
	if leaderName != "" {
		annotations["hiclaw.io/team-leader"] = leaderName
	}

	return &v1beta1.Worker{
		ObjectMeta: metav1.ObjectMeta{
			Name:        w.Name,
			Namespace:   t.Namespace,
			Annotations: annotations,
			Labels: map[string]string{
				"hiclaw.io/team": teamName,
				"hiclaw.io/role": role,
			},
		},
		Spec: v1beta1.WorkerSpec{
			Model:         w.Model,
			Runtime:       w.Runtime,
			Image:         w.Image,
			Identity:      w.Identity,
			Soul:          w.Soul,
			Agents:        w.Agents,
			Skills:        w.Skills,
			McpServers:    w.McpServers,
			Package:       w.Package,
			Expose:        w.Expose,
			ChannelPolicy: w.ChannelPolicy,
		},
	}
}

func (r *TeamReconciler) createOrUpdateWorkerCR(ctx context.Context, desired *v1beta1.Worker) error {
	existing := &v1beta1.Worker{}
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), existing)
	if err != nil {
		if client.IgnoreNotFound(err) != nil {
			return err
		}
		return r.Create(ctx, desired)
	}
	existing.Spec = desired.Spec
	if existing.Annotations == nil {
		existing.Annotations = make(map[string]string)
	}
	for k, v := range desired.Annotations {
		existing.Annotations[k] = v
	}
	return r.Update(ctx, existing)
}

func (r *TeamReconciler) failTeam(ctx context.Context, t *v1beta1.Team, msg string) (reconcile.Result, error) {
	_ = r.Get(ctx, client.ObjectKeyFromObject(t), t)
	t.Status.Phase = "Failed"
	t.Status.Message = msg
	r.Status().Update(ctx, t)
	return reconcile.Result{RequeueAfter: time.Minute}, fmt.Errorf("%s", msg)
}

func (r *TeamReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&v1beta1.Team{}).
		Complete(r)
}
