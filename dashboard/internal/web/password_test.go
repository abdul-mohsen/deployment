package web

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"golang.org/x/crypto/bcrypt"
)

func TestHandlePasswordSubmitUpdatesEnvFileAndLiveHash(t *testing.T) {
	oldHash, err := bcrypt.GenerateFromPassword([]byte("old-password"), 10)
	if err != nil {
		t.Fatal(err)
	}
	envFile := filepath.Join(t.TempDir(), "dashboard.env")
	if err := os.WriteFile(envFile, []byte("ADMIN_USER=admin\nADMIN_PASSWORD_HASH='"+string(oldHash)+"'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ADMIN_PASSWORD_HASH", string(oldHash))

	srv := &server{cfg: config.Config{
		AdminUser:        "admin",
		AdminHash:        string(oldHash),
		DashboardEnvFile: envFile,
	}}
	form := url.Values{
		"current_password": {"old-password"},
		"new_password":     {"new-password"},
		"confirm_password": {"new-password"},
	}
	req := httptest.NewRequest(http.MethodPost, "/settings/password", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()

	srv.handlePasswordSubmit(w, req)

	if w.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusSeeOther)
	}
	if got := w.Header().Get("Location"); got != "/settings/password?saved=1" {
		t.Fatalf("redirect = %q", got)
	}
	if srv.passwordMatches("old-password") {
		t.Fatal("old password still matches live hash")
	}
	if !srv.passwordMatches("new-password") {
		t.Fatal("new password does not match live hash")
	}
	data, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	out := string(data)
	if strings.Contains(out, string(oldHash)) {
		t.Fatalf("old hash was not replaced:\n%s", out)
	}
	if !strings.Contains(out, "ADMIN_PASSWORD_HASH='$2a$") {
		t.Fatalf("new hash was not persisted with env quoting:\n%s", out)
	}
}

func TestHandlePasswordSubmitRejectsWrongCurrentPassword(t *testing.T) {
	oldHash, err := bcrypt.GenerateFromPassword([]byte("old-password"), 10)
	if err != nil {
		t.Fatal(err)
	}
	envFile := filepath.Join(t.TempDir(), "dashboard.env")
	if err := os.WriteFile(envFile, []byte("ADMIN_USER=admin\nADMIN_PASSWORD_HASH='"+string(oldHash)+"'\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	srv := &server{cfg: config.Config{AdminHash: string(oldHash), DashboardEnvFile: envFile}}
	form := url.Values{
		"current_password": {"wrong"},
		"new_password":     {"new-password"},
		"confirm_password": {"new-password"},
	}
	req := httptest.NewRequest(http.MethodPost, "/settings/password", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()

	srv.handlePasswordSubmit(w, req)

	if w.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusSeeOther)
	}
	if got := w.Header().Get("Location"); got != "/settings/password?e=current" {
		t.Fatalf("redirect = %q", got)
	}
	if !srv.passwordMatches("old-password") {
		t.Fatal("old password should still match")
	}
}
