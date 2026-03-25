package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	v1 "github.com/hiclaw/hiclaw-controller/api/v1"
	"github.com/hiclaw/hiclaw-controller/internal/controller"
	"github.com/hiclaw/hiclaw-controller/internal/executor"
	"github.com/hiclaw/hiclaw-controller/internal/server"
	"github.com/hiclaw/hiclaw-controller/internal/store"
	"github.com/hiclaw/hiclaw-controller/internal/watcher"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

func main() {
	ctrl.SetLogger(zap.New())
	logger := ctrl.Log.WithName("hiclaw-controller")

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	kubeMode := os.Getenv("HICLAW_KUBE_MODE")
	if kubeMode == "" {
		kubeMode = "embedded"
	}

	dataDir := os.Getenv("HICLAW_DATA_DIR")
	if dataDir == "" {
		dataDir = "/data/hiclaw-controller"
	}

	httpAddr := os.Getenv("HICLAW_HTTP_ADDR")
	if httpAddr == "" {
		httpAddr = ":8090"
	}

	configDir := os.Getenv("HICLAW_CONFIG_DIR")
	if configDir == "" {
		configDir = "/root/hiclaw-fs/hiclaw-config"
	}

	// Build scheme
	scheme := runtime.NewScheme()
	if err := v1.AddToScheme(scheme); err != nil {
		logger.Error(err, "failed to add hiclaw types to scheme")
		os.Exit(1)
	}

	// Initialize executors
	shell := executor.NewShell("/opt/hiclaw/agent/skills")
	packages := executor.NewPackageResolver("/tmp/import")

	if kubeMode == "embedded" {
		// ── Embedded mode: kine + file watcher ──
		logger.Info("starting embedded mode", "dataDir", dataDir, "configDir", configDir)

		// 1. Start kine (SQLite backend)
		kineServer, err := store.StartKine(ctx, store.Config{
			DataDir:       dataDir,
			ListenAddress: "127.0.0.1:2379",
		})
		if err != nil {
			logger.Error(err, "failed to start kine")
			os.Exit(1)
		}
		logger.Info("kine started", "endpoints", kineServer.ETCDConfig.Endpoints)

		// TODO: start embedded API server using kine as backend, get client.Client
		// For now, placeholders for controller wiring
		var k8sClient ctrl.Manager
		_ = k8sClient

		// 2. Initial sync: scan all YAML files in configDir → write to kine
		fw := watcher.New(configDir, nil) // TODO: pass real client once API server is wired
		if err := fw.InitialSync(ctx); err != nil {
			logger.Error(err, "initial sync failed")
		}

		// 3. Start fsnotify watcher in background
		go func() {
			if err := fw.Watch(ctx); err != nil && ctx.Err() == nil {
				logger.Error(err, "file watcher stopped unexpectedly")
			}
		}()
		logger.Info("file watcher started", "dir", configDir)

		// 4. Register controllers (placeholder until API server wired)
		_ = &controller.WorkerReconciler{Executor: shell, Packages: packages}
		_ = &controller.TeamReconciler{Executor: shell, Packages: packages}
		_ = &controller.HumanReconciler{Executor: shell}

	} else {
		// ── In-cluster mode: connect to K8s API Server directly ──
		logger.Info("starting in-cluster mode")

		// No kine, no file watcher, no MinIO config dependency
		// TODO: use ctrl.GetConfigOrDie() + ctrl.NewManager() + register reconcilers
		_ = &controller.WorkerReconciler{Executor: shell, Packages: packages}
		_ = &controller.TeamReconciler{Executor: shell, Packages: packages}
		_ = &controller.HumanReconciler{Executor: shell}
	}

	// Start HTTP API server in background
	go func() {
		httpServer := server.NewHTTPServer(httpAddr, kubeMode)
		if err := httpServer.Start(); err != nil {
			logger.Error(err, "HTTP server failed")
		}
	}()

	logger.Info("hiclaw-controller ready", "kubeMode", kubeMode, "httpAddr", httpAddr)
	fmt.Println("hiclaw-controller is running. Press Ctrl+C to stop.")

	<-ctx.Done()
	logger.Info("shutting down")
}
