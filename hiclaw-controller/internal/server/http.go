package server

import (
	"net/http"

	authpkg "github.com/hiclaw/hiclaw-controller/internal/auth"
	"github.com/hiclaw/hiclaw-controller/internal/backend"
	"github.com/hiclaw/hiclaw-controller/internal/credentials"
	"github.com/hiclaw/hiclaw-controller/internal/gateway"
	"github.com/hiclaw/hiclaw-controller/internal/proxy"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// ServerDeps aggregates all dependencies needed by the HTTP API handlers.
type ServerDeps struct {
	Client     client.Client
	Backend    *backend.Registry
	Gateway    gateway.Client
	STS        *credentials.STSService
	AuthMw     *authpkg.Middleware
	KubeMode   string
	Namespace  string
	SocketPath string // Docker proxy (embedded only)
}

// HTTPServer serves the unified controller REST API.
type HTTPServer struct {
	Addr string
	Mux  *http.ServeMux
}

func NewHTTPServer(addr string, deps ServerDeps) *HTTPServer {
	mux := http.NewServeMux()
	s := &HTTPServer{Addr: addr, Mux: mux}

	mw := deps.AuthMw

	managerOrAdmin := []string{authpkg.RoleAdmin, authpkg.RoleManager}

	// --- Status / health (no auth) ---
	sh := NewStatusHandler(deps.Client, deps.Namespace, deps.KubeMode)
	mux.HandleFunc("GET /healthz", sh.Healthz)

	// --- Status endpoints (auth required) ---
	mux.Handle("GET /api/v1/status", mw.RequireAny(http.HandlerFunc(sh.ClusterStatus)))
	mux.Handle("GET /api/v1/version", mw.RequireAny(http.HandlerFunc(sh.Version)))

	// --- Declarative resource CRUD ---
	rh := NewResourceHandler(deps.Client, deps.Namespace)

	// Workers: manager and admin can create/update/delete
	mux.Handle("POST /api/v1/workers", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.CreateWorker)))
	mux.Handle("GET /api/v1/workers", mw.RequireAny(http.HandlerFunc(rh.ListWorkers)))
	mux.Handle("GET /api/v1/workers/{name}", mw.RequireAny(http.HandlerFunc(rh.GetWorker)))
	mux.Handle("PUT /api/v1/workers/{name}", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.UpdateWorker)))
	mux.Handle("DELETE /api/v1/workers/{name}", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.DeleteWorker)))

	// Teams
	mux.Handle("POST /api/v1/teams", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.CreateTeam)))
	mux.Handle("GET /api/v1/teams", mw.RequireAny(http.HandlerFunc(rh.ListTeams)))
	mux.Handle("GET /api/v1/teams/{name}", mw.RequireAny(http.HandlerFunc(rh.GetTeam)))
	mux.Handle("PUT /api/v1/teams/{name}", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.UpdateTeam)))
	mux.Handle("DELETE /api/v1/teams/{name}", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.DeleteTeam)))

	// Humans
	mux.Handle("POST /api/v1/humans", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.CreateHuman)))
	mux.Handle("GET /api/v1/humans", mw.RequireAny(http.HandlerFunc(rh.ListHumans)))
	mux.Handle("GET /api/v1/humans/{name}", mw.RequireAny(http.HandlerFunc(rh.GetHuman)))
	mux.Handle("DELETE /api/v1/humans/{name}", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(rh.DeleteHuman)))

	// --- Imperative lifecycle ---
	lh := NewLifecycleHandler(deps.Client, deps.Backend, deps.Namespace)
	mux.Handle("POST /api/v1/workers/{name}/wake", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(lh.Wake)))
	mux.Handle("POST /api/v1/workers/{name}/sleep", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(lh.Sleep)))
	mux.Handle("POST /api/v1/workers/{name}/ensure-ready", mw.RequireRoles(managerOrAdmin, http.HandlerFunc(lh.EnsureReady)))
	mux.Handle("POST /api/v1/workers/{name}/ready", mw.RequireWorker(http.HandlerFunc(lh.Ready)))
	mux.Handle("GET /api/v1/workers/{name}/status", mw.RequireAny(http.HandlerFunc(lh.GetWorkerRuntimeStatus)))

	// --- Gateway ---
	gh := NewGatewayHandler(deps.Gateway)
	mux.Handle("POST /api/v1/gateway/consumers", mw.RequireManager(http.HandlerFunc(gh.CreateConsumer)))
	mux.Handle("POST /api/v1/gateway/consumers/{id}/bind", mw.RequireManager(http.HandlerFunc(gh.BindConsumer)))
	mux.Handle("DELETE /api/v1/gateway/consumers/{id}", mw.RequireManager(http.HandlerFunc(gh.DeleteConsumer)))

	// --- Credentials ---
	ch := NewCredentialsHandler(deps.STS)
	mux.Handle("POST /api/v1/credentials/sts", mw.RequireWorker(http.HandlerFunc(ch.RefreshSTS)))

	// --- Docker API passthrough (embedded mode only) ---
	if deps.KubeMode == "embedded" && deps.SocketPath != "" {
		validator := proxy.NewSecurityValidator()
		proxyHandler := proxy.NewHandler(deps.SocketPath, validator)
		mux.Handle("/docker/", mw.RequireManager(http.StripPrefix("/docker", proxyHandler)))
	}

	return s
}

func (s *HTTPServer) Start() error {
	logger := log.Log.WithName("http-server")
	logger.Info("starting unified REST API server", "addr", s.Addr)
	return http.ListenAndServe(s.Addr, s.Mux)
}
