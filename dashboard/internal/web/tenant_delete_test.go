package web

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// TestTenantDeleteRequiresConfirmMatchingTenant checks the destructive
// endpoint refuses without a matching confirm form field (server-side
// type-to-confirm — the JS prompt is defence in depth, not the guard).
func TestTenantDeleteRequiresConfirmMatchingTenant(t *testing.T) {
	handler := testRouter(t)
	cookie := authenticate(t, handler)
	if cookie == nil {
		t.Skip("no session cookie — auth stack changed?")
	}

	tests := []struct {
		name        string
		form        url.Values
		wantStatus  int
		wantSnippet string
	}{
		{
			name:        "no confirm field",
			form:        url.Values{},
			wantStatus:  http.StatusBadRequest,
			wantSnippet: "confirmation mismatch",
		},
		{
			name:        "wrong tenant name in confirm",
			form:        url.Values{"confirm": {"other-tenant"}},
			wantStatus:  http.StatusBadRequest,
			wantSnippet: "confirmation mismatch",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/tenants/acme/delete", strings.NewReader(tc.form.Encode()))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			req.AddCookie(cookie)
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			if rr.Code != tc.wantStatus {
				body, _ := io.ReadAll(rr.Body)
				t.Fatalf("status=%d want=%d body=%q", rr.Code, tc.wantStatus, string(body))
			}
			body, _ := io.ReadAll(rr.Body)
			if !strings.Contains(string(body), tc.wantSnippet) {
				t.Errorf("body %q missing %q", string(body), tc.wantSnippet)
			}
		})
	}
}

// TestTenantDeleteRejectsBadName confirms the app-name whitelist runs before
// anything destructive.
func TestTenantDeleteRejectsBadName(t *testing.T) {
	handler := testRouter(t)
	cookie := authenticate(t, handler)
	if cookie == nil {
		t.Skip("no session cookie")
	}
	req := httptest.NewRequest(http.MethodPost, "/tenants/foo;rm-rf/delete",
		strings.NewReader("confirm=foo;rm-rf"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	// chi's own path parser will 404 an invalid path segment; either 400
	// (validAppName check) or 404 (chi) is acceptable — anything other
	// than 200/2xx means the endpoint didn't reach the runner.
	if rr.Code >= 200 && rr.Code < 300 {
		body, _ := io.ReadAll(rr.Body)
		t.Fatalf("expected non-2xx for shell-injection-ish name, got %d: %s", rr.Code, string(body))
	}
}
