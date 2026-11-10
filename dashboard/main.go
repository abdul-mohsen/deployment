// Package main is the entry point for the Dokku admin dashboard.
//
// The dashboard runs on each environment's server (one container per env),
// mounts /var/run/docker.sock and /usr/local/bin/dokku, and exposes a
// password-protected web UI for listing, controlling, and tailing logs of all
// Dokku apps living on that host.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo"
	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logging"
	"github.com/abdul-mohsen/deployment/dashboard/internal/retention"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/abdul-mohsen/deployment/dashboard/internal/web"
)

func main() {
	build := buildinfo.Current()
	logger := logging.New(logging.Options{
		Level:       os.Getenv("DASHBOARD_LOG_LEVEL"),
		Format:      os.Getenv("DASHBOARD_LOG_FORMAT"),
		Service:     "dokku-dashboard",
		Environment: os.Getenv("DASHBOARD_ENV"),
		Build:       build,
	})
	slog.SetDefault(logger)
	fatal := func(code, message string, err error) {
		logger.Error(message, logging.ErrorCodeAttr(code), logging.ErrorAttr(err))
		os.Exit(1)
	}

	// Pull MYSQL_*, BASE_DOMAIN, etc. from the deployment env files. Compose
	// injects dashboard.env before startup, so deployment-owned URL settings
	// are explicitly reloaded from the configured deployment file below.
	depDir := os.Getenv("DEPLOYMENT_DIR")
	if depDir == "" {
		depDir = "/opt/deployment"
	}
	configPath := os.Getenv("DEPLOY_CONFIG_FILE")
	if configPath == "" {
		configPath = filepath.Join(depDir, "config.env")
	}
	config.LoadEnvFiles(filepath.Join(depDir, "install.env"), configPath)
	if err := config.OverrideEnvFileValues(configPath, "BASE_DOMAIN", "PUBLIC_PROTOCOL"); err != nil {
		fatal("deployment_config_load_failed", "deployment config load failed", err)
	}

	cfg, err := config.Load()
	if err != nil {
		fatal("dashboard_config_invalid", "dashboard configuration failed", err)
	}
	logger = logging.New(logging.Options{
		Level:       cfg.LogLevel,
		Format:      cfg.LogFormat,
		Service:     "dokku-dashboard",
		Environment: cfg.EnvName,
		Build:       build,
	})
	slog.SetDefault(logger)
	fatal = func(code, message string, err error) {
		logger.Error(message, logging.ErrorCodeAttr(code), logging.ErrorAttr(err))
		os.Exit(1)
	}

	client := dokku.New(cfg.DockerBin, cfg.DokkuContainer)
	store, err := logbuf.NewPersistent(cfg.LogBufferLines, cfg.LogDir)
	if err != nil {
		fatal("activity_log_store_init_failed", "activity log store initialization failed", err)
	}
	runner := scripts.NewRunner(cfg.DockerBin, cfg.RunnerImage, cfg.ScriptsHostPath, cfg.ConfigFile)
	if cfg.BackupDir != "" {
		runner.SetBackupDir(cfg.BackupDir)
	}
	if cfg.StorageRoot != "" {
		runner.SetStorageRoot(cfg.StorageRoot)
	}

	// Start the daily backup retention policy. User-origin backups are never
	// pruned by this policy.
	retentionRunner := retention.New(cfg.DockerBin, cfg.RunnerImage, cfg.ScriptsHostPath, cfg.BackupRetentionDays)
	if cfg.BackupDir != "" {
		retentionRunner.SetBackupDir(cfg.BackupDir)
	}
	retentionRunner.SetLogger(logger)
	bgCtx, bgCancel := context.WithCancel(context.Background())
	retentionRunner.Start(bgCtx)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           web.Router(cfg, client, store, runner),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		logger.Info("dashboard listening", "listen", cfg.Listen)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fatal("dashboard_listener_failed", "dashboard listener failed", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	bgCancel()
	retentionRunner.Stop()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
