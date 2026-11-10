package web

import (
	"log/slog"
	"net/http"
	"reflect"

	"github.com/go-chi/chi/v5/middleware"
)

// RecoveryMiddleware converts handler panics into a generic 500 response.
// It logs only the panic's type and the correlated request ID; panic values
// and stack traces may contain credentials or request data.
func RecoveryMiddleware(logger *slog.Logger) func(http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			completed := false
			defer func() {
				recovered := recover()
				if completed && recovered == nil {
					return
				}

				panicType := "nil"
				if recovered != nil {
					panicType = reflect.TypeOf(recovered).String()
				}
				logger.ErrorContext(r.Context(), "http panic recovered",
					slog.String("request_id", sanitizedRequestID(middleware.GetReqID(r.Context()))),
					slog.String("panic_type", panicType),
				)
				http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
			}()

			next.ServeHTTP(w, r)
			completed = true
		})
	}
}
