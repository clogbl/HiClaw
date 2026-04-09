package initializer

import (
	"context"
	"fmt"
	"time"

	v1beta1 "github.com/hiclaw/hiclaw-controller/api/v1beta1"
	"github.com/hiclaw/hiclaw-controller/internal/matrix"
	"github.com/hiclaw/hiclaw-controller/internal/oss"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
)

// Config holds parameters for cluster initialization.
type Config struct {
	ManagerEnabled bool
	ManagerModel   string
	ManagerRuntime string
	ManagerImage   string
	AdminUser      string
	AdminPassword  string
	Namespace      string
}

// Initializer performs one-time cluster bootstrap: waits for infrastructure,
// initializes storage structure, registers the admin account, and optionally
// creates the Manager CR.
type Initializer struct {
	OSS     oss.StorageClient
	Matrix  matrix.Client
	RestCfg *rest.Config
	Config  Config
}

func (i *Initializer) Run(ctx context.Context) error {
	logger := ctrl.Log.WithName("initializer")
	logger.Info("starting cluster initialization")

	if err := i.waitForOSS(ctx); err != nil {
		return fmt.Errorf("OSS not ready: %w", err)
	}
	logger.Info("OSS is ready")

	if err := i.ensureOSSStructure(ctx); err != nil {
		return fmt.Errorf("OSS structure init failed: %w", err)
	}
	logger.Info("OSS directory structure initialized")

	if err := i.waitForMatrix(ctx); err != nil {
		return fmt.Errorf("Matrix not ready: %w", err)
	}
	logger.Info("Matrix is ready")

	if err := i.registerAdmin(ctx); err != nil {
		return fmt.Errorf("admin registration failed: %w", err)
	}
	logger.Info("admin account ready", "user", i.Config.AdminUser)

	if i.Config.ManagerEnabled {
		if err := i.ensureManagerCR(ctx); err != nil {
			return fmt.Errorf("Manager CR creation failed: %w", err)
		}
		logger.Info("Manager CR ensured", "name", "default")
	}

	logger.Info("cluster initialization complete")
	return nil
}

// waitForOSS polls MinIO/OSS until the bucket is accessible.
func (i *Initializer) waitForOSS(ctx context.Context) error {
	if bm, ok := i.OSS.(oss.BucketManager); ok {
		return retry(ctx, 3*time.Second, 120*time.Second, func() error {
			return bm.EnsureBucket(ctx)
		})
	}
	return retry(ctx, 3*time.Second, 120*time.Second, func() error {
		_, err := i.OSS.ListObjects(ctx, "")
		return err
	})
}

func (i *Initializer) ensureOSSStructure(ctx context.Context) error {
	dirs := []string{
		"shared/knowledge/",
		"shared/tasks/",
		"workers/",
		"hiclaw-config/workers/",
		"hiclaw-config/teams/",
		"hiclaw-config/humans/",
		"agents/",
	}
	for _, dir := range dirs {
		if err := i.OSS.PutObject(ctx, dir+".gitkeep", []byte("")); err != nil {
			return fmt.Errorf("create %s: %w", dir, err)
		}
	}
	return nil
}

// waitForMatrix polls the Matrix server until it responds.
func (i *Initializer) waitForMatrix(ctx context.Context) error {
	return retry(ctx, 3*time.Second, 120*time.Second, func() error {
		_, err := i.Matrix.Login(ctx, "__healthcheck__", "invalid")
		if err != nil && isMatrixConnError(err) {
			return err
		}
		// Any non-connection error (403, 401, etc.) means Matrix is up.
		return nil
	})
}

func (i *Initializer) registerAdmin(ctx context.Context) error {
	_, err := i.Matrix.EnsureUser(ctx, matrix.EnsureUserRequest{
		Username: i.Config.AdminUser,
		Password: i.Config.AdminPassword,
	})
	return err
}

func (i *Initializer) ensureManagerCR(ctx context.Context) error {
	logger := ctrl.Log.WithName("initializer")

	dynClient, err := dynamic.NewForConfig(i.RestCfg)
	if err != nil {
		return fmt.Errorf("create dynamic client: %w", err)
	}

	gvr := schema.GroupVersionResource{
		Group:    v1beta1.GroupName,
		Version:  v1beta1.Version,
		Resource: "managers",
	}

	ns := i.Config.Namespace
	name := "default"

	_, err = dynClient.Resource(gvr).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	if err == nil {
		logger.Info("Manager CR already exists, skipping creation")
		return nil
	}

	spec := map[string]interface{}{
		"model":   i.Config.ManagerModel,
		"runtime": i.Config.ManagerRuntime,
	}
	if i.Config.ManagerImage != "" {
		spec["image"] = i.Config.ManagerImage
	}

	obj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": v1beta1.GroupName + "/" + v1beta1.Version,
			"kind":       "Manager",
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": ns,
			},
			"spec": spec,
		},
	}

	_, err = dynClient.Resource(gvr).Namespace(ns).Create(ctx, obj, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("create Manager CR: %w", err)
	}
	return nil
}

// retry calls fn repeatedly until it succeeds or the timeout is reached.
func retry(ctx context.Context, interval, timeout time.Duration, fn func() error) error {
	deadline := time.Now().Add(timeout)
	for {
		err := fn()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out after %v: %w", timeout, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(interval):
		}
	}
}

// isMatrixConnError returns true if the error indicates a transport-level failure
// (connection refused, DNS error, etc.) as opposed to an HTTP-level response.
func isMatrixConnError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	for _, sub := range []string{"connection refused", "no such host", "dial tcp", "i/o timeout", "EOF"} {
		if contains(msg, sub) {
			return true
		}
	}
	return false
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchString(s, substr)
}

func searchString(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
