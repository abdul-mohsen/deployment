package config

import "testing"

func TestLoadReadsDashboardLoggingConfiguration(t *testing.T) {
	t.Setenv("DASHBOARD_ENV", "dev")
	t.Setenv("BASE_DOMAIN", "dev.example.com")
	t.Setenv("PUBLIC_PROTOCOL", "http")
	t.Setenv("ADMIN_USER", "admin")
	t.Setenv("ADMIN_PASSWORD_HASH", "bcrypt-hash")
	t.Setenv("SESSION_KEY", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	t.Setenv("DASHBOARD_LOG_LEVEL", "debug")
	t.Setenv("DASHBOARD_LOG_FORMAT", "text")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.LogLevel != "debug" || cfg.LogFormat != "text" {
		t.Fatalf("logging config = %q/%q, want debug/text", cfg.LogLevel, cfg.LogFormat)
	}
}
