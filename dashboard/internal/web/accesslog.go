package web

import (
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// RequestEvent is the bounded request observation emitted by AccessMiddleware.
// It intentionally contains no headers, cookies, query values, or bodies.
type RequestEvent struct {
	RequestID string
	Method    string
	Route     string
	Status    int
	Duration  time.Duration
	ClientIP  string
}

// RequestObserver is an extension point for future metrics or tracing
// integrations without coupling the dashboard to a telemetry SDK.
type RequestObserver func(RequestEvent)

// AccessMiddleware logs one structured access event after the request has
// completed. It should be installed after Chi's RequestID, RealIP, and
// recovery middleware.
func AccessMiddleware(logger *slog.Logger, observer RequestObserver) func(http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			recorder := &statusRecorder{ResponseWriter: w}
			completed := false
			defer func() {
				status := recorder.statusCode()
				if !completed && recorder.status == 0 {
					status = http.StatusInternalServerError
				}
				emitRequestEvent(logger, observer, r, status, time.Since(start))
			}()
			next.ServeHTTP(recorder, r)
			completed = true
		})
	}
}

func emitRequestEvent(logger *slog.Logger, observer RequestObserver, r *http.Request, status int, duration time.Duration) {
	event := RequestEvent{
		RequestID: sanitizedRequestID(middleware.GetReqID(r.Context())),
		Method:    r.Method,
		Route:     routePattern(r),
		Status:    status,
		Duration:  duration,
		ClientIP:  sanitizedClientIP(r.RemoteAddr),
	}
	if observer != nil {
		observer(event)
	}

	level := slog.LevelInfo
	switch {
	case event.Status >= http.StatusInternalServerError:
		level = slog.LevelError
	case event.Status >= http.StatusBadRequest:
		level = slog.LevelWarn
	}
	logger.LogAttrs(r.Context(), level, "http request",
		slog.String("request_id", event.RequestID),
		slog.String("method", event.Method),
		slog.String("route", event.Route),
		slog.Int("status", event.Status),
		slog.Int64("duration_ms", event.Duration.Microseconds()/1000),
		slog.String("client_ip", event.ClientIP),
	)
}

func routePattern(r *http.Request) string {
	if routeContext := chi.RouteContext(r.Context()); routeContext != nil {
		if pattern := routeContext.RoutePattern(); pattern != "" {
			return pattern
		}
	}
	return "unmatched"
}

func sanitizedClientIP(remoteAddr string) string {
	remoteAddr = strings.TrimSpace(remoteAddr)
	if host, _, err := net.SplitHostPort(remoteAddr); err == nil {
		remoteAddr = host
	}
	remoteAddr = strings.Trim(remoteAddr, "[]")
	if ip := net.ParseIP(remoteAddr); ip != nil {
		return ip.String()
	}
	return "unknown"
}

func sanitizedRequestID(requestID string) string {
	requestID = strings.TrimSpace(requestID)
	if requestID == "" || len(requestID) > 128 {
		return "unknown"
	}
	for _, r := range requestID {
		if (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			strings.ContainsRune("._-", r) {
			continue
		}
		return "unknown"
	}
	return requestID
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	if r.status != 0 {
		return
	}
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(body []byte) (int, error) {
	if r.status == 0 {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(body)
}

func (r *statusRecorder) Flush() {
	if r.status == 0 {
		r.WriteHeader(http.StatusOK)
	}
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}

func (r *statusRecorder) statusCode() int {
	if r.status == 0 {
		return http.StatusOK
	}
	return r.status
}
