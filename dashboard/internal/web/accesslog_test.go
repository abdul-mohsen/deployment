package web

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

func TestAccessMiddlewareCorrelatesRequestAndRedactsIdentityInputs(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	var observed RequestEvent

	router := chi.NewRouter()
	router.Use(middleware.RequestID)
	router.Use(middleware.RealIP)
	router.Use(RecoveryMiddleware(logger))
	router.Use(AccessMiddleware(logger, func(event RequestEvent) {
		observed = event
	}))
	router.Get("/tenants/{name}/activity", func(w http.ResponseWriter, r *http.Request) {
		if got := middleware.GetReqID(r.Context()); got == "" {
			t.Fatal("request ID was not installed")
		}
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/tenants/acme/activity?secret=query-value", nil)
	req.RemoteAddr = "203.0.113.7:4567"
	req.Header.Set("X-Request-ID", "request-from-client")
	req.Header.Set("Authorization", "Bearer header-secret")
	req.Header.Set("Cookie", "session=cookie-secret")
	rr := httptest.NewRecorder()
	router.ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusNoContent)
	}
	if observed.RequestID == "" {
		t.Fatal("request ID was not observed")
	}
	if observed.Method != http.MethodGet || observed.Route != "/tenants/{name}/activity" ||
		observed.Status != http.StatusNoContent || observed.ClientIP != "203.0.113.7" {
		t.Fatalf("observed event = %+v", observed)
	}
	if observed.Duration < 0 {
		t.Fatalf("duration = %s, want non-negative", observed.Duration)
	}

	var record map[string]any
	if err := json.Unmarshal(output.Bytes(), &record); err != nil {
		t.Fatalf("access event is not JSON: %v\n%s", err, output.String())
	}
	if record["request_id"] != observed.RequestID || record["route"] != observed.Route {
		t.Fatalf("correlation fields = %v, observed = %+v", record, observed)
	}
	for _, secret := range []string{"header-secret", "cookie-secret", "query-value", "Cookie", "Authorization"} {
		if strings.Contains(output.String(), secret) {
			t.Fatalf("request secret %q leaked in %s", secret, output.String())
		}
	}
	if _, ok := record["headers"]; ok {
		t.Fatalf("headers were logged: %v", record)
	}
	if _, ok := record["body"]; ok {
		t.Fatalf("body was logged: %v", record)
	}
}

func TestAccessMiddlewareUsesStatusAndSupportsStreaming(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	router := chi.NewRouter()
	router.Use(middleware.RequestID)
	router.Use(AccessMiddleware(logger, nil))
	router.Get("/stream", func(w http.ResponseWriter, _ *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("wrapped writer lost http.Flusher")
		}
		_, _ = w.Write([]byte("chunk"))
		flusher.Flush()
	})

	rr := httptest.NewRecorder()
	router.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/stream", nil))
	if rr.Code != http.StatusOK || rr.Body.String() != "chunk" {
		t.Fatalf("response = %d %q", rr.Code, rr.Body.String())
	}
	if !strings.Contains(output.String(), `"status":200`) {
		t.Fatalf("access event did not capture implicit 200: %s", output.String())
	}
}

func TestAccessMiddlewareRecordsRecoveredPanicsAsInternalErrors(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	var observed RequestEvent

	router := chi.NewRouter()
	router.Use(middleware.RequestID)
	router.Use(RecoveryMiddleware(logger))
	router.Use(AccessMiddleware(logger, func(event RequestEvent) {
		observed = event
	}))
	router.Get("/panic", func(http.ResponseWriter, *http.Request) {
		panic("panic-secret")
	})

	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/panic", nil)
	req.Header.Set("Authorization", "header-secret")
	req.Header.Set("Cookie", "session=cookie-secret")
	router.ServeHTTP(rr, req)
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusInternalServerError)
	}
	if observed.Status != http.StatusInternalServerError {
		t.Fatalf("observed event = %+v, want status %d", observed, http.StatusInternalServerError)
	}
	if !strings.Contains(output.String(), `"status":500`) {
		t.Fatalf("panic access event did not capture 500: %s", output.String())
	}
	if !strings.Contains(output.String(), `"panic_type":"string"`) {
		t.Fatalf("recovery event omitted panic type: %s", output.String())
	}
	for _, secret := range []string{"panic-secret", "header-secret", "cookie-secret"} {
		if strings.Contains(output.String(), secret) || strings.Contains(rr.Body.String(), secret) {
			t.Fatalf("panic/request secret %q leaked in logs or response", secret)
		}
	}
}

func TestSanitizedClientIP(t *testing.T) {
	tests := map[string]string{
		"203.0.113.7:4567":    "203.0.113.7",
		"[2001:db8::7]:4567":  "2001:db8::7",
		"2001:db8::8":         "2001:db8::8",
		"not-an-address:4567": "unknown",
	}
	for input, want := range tests {
		t.Run(input, func(t *testing.T) {
			if got := sanitizedClientIP(input); got != want {
				t.Fatalf("sanitizedClientIP(%q) = %q, want %q", input, got, want)
			}
		})
	}
}

func TestSanitizedRequestIDRejectsHeaderInjection(t *testing.T) {
	if got := sanitizedRequestID("request-id\nsecret"); got != "unknown" {
		t.Fatalf("sanitizedRequestID accepted control characters: %q", got)
	}
	if got := sanitizedRequestID("request-id-123"); got != "request-id-123" {
		t.Fatalf("sanitizedRequestID changed valid ID: %q", got)
	}
}

func TestRequestEventDurationIsRepresentable(t *testing.T) {
	event := RequestEvent{Duration: 1500 * time.Microsecond}
	if got := event.Duration.Microseconds() / 1000; got != 1 {
		t.Fatalf("duration milliseconds = %d, want 1", got)
	}
}
