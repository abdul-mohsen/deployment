// Package config loads dashboard configuration from environment variables.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config is the runtime configuration for the dashboard.
type Config struct {
	EnvName          string // e.g. "dev" / "prod" — shown in the header.
	Listen           string // host:port to listen on.
	DockerBin        string // path to the docker binary.
	DokkuContainer   string // name of the dokku-in-docker container.
	BaseDomain       string // base domain shown for app URLs.
	AdminUser        string // single admin username.
	AdminHash        string // bcrypt hash of the admin password.
	SessionKey       []byte // cookie signing key.
	LogBufferLines   int    // ring-buffer size per app for log aggregation.
	CookieSecure     bool   // set Secure flag on session cookie.
	ScriptsHostPath  string // host path to /opt/deployment (for sidecar runner).
	RunnerImage      string // image used to execute deployment scripts.
	ConfigFile       string // optional --config file path inside runner.
	DashboardEnvFile string // optional writable env file for dashboard credentials.
}

// Load reads configuration from the process environment.
//
// Required:
//
//	ADMIN_USER, ADMIN_PASSWORD_HASH (bcrypt)
//
// Optional with defaults:
//
//	DASHBOARD_ENV=dev|prod    (default "dev")
//	LISTEN=:8080
//	DOCKER_BIN=docker
//	DOKKU_CONTAINER=dokku
//	BASE_DOMAIN=localhost
//	SESSION_KEY=<hex>         (auto-generated if missing — sessions reset on restart)
//	LOG_BUFFER_LINES=2000
//	COOKIE_SECURE=false
func Load() (Config, error) {
	c := Config{
		EnvName:          envOr("DASHBOARD_ENV", "dev"),
		Listen:           envOr("LISTEN", ":8080"),
		DockerBin:        envOr("DOCKER_BIN", "docker"),
		DokkuContainer:   envOr("DOKKU_CONTAINER", "dokku"),
		BaseDomain:       envOr("BASE_DOMAIN", "localhost"),
		AdminUser:        os.Getenv("ADMIN_USER"),
		AdminHash:        os.Getenv("ADMIN_PASSWORD_HASH"),
		LogBufferLines:   envInt("LOG_BUFFER_LINES", 2000),
		CookieSecure:     strings.EqualFold(os.Getenv("COOKIE_SECURE"), "true"),
		ScriptsHostPath:  envOr("SCRIPTS_HOST_PATH", ""),
		RunnerImage:      envOr("SCRIPT_RUNNER_IMAGE", "mysql:8.0"),
		ConfigFile:       envOr("DEPLOY_CONFIG_FILE", ""),
		DashboardEnvFile: envOr("DASHBOARD_ENV_FILE", ""),
	}
	if c.AdminUser == "" || c.AdminHash == "" {
		return c, fmt.Errorf("ADMIN_USER and ADMIN_PASSWORD_HASH are required")
	}
	if k := os.Getenv("SESSION_KEY"); k != "" {
		raw, err := hex.DecodeString(k)
		if err != nil {
			return c, fmt.Errorf("SESSION_KEY must be hex: %w", err)
		}
		c.SessionKey = raw
	} else {
		c.SessionKey = make([]byte, 32)
		if _, err := rand.Read(c.SessionKey); err != nil {
			return c, err
		}
	}
	return c, nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
