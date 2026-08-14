package web

import "net/http"

// securityHeaders adds a small set of low-risk defensive HTTP response
// headers to every dashboard response. Nothing here breaks the app —
// no CSP `script-src` restrictions (some templates inline scripts), no
// HSTS (host nginx already terminates TLS and can add HSTS if wanted).
//
// If you tighten this later, run the e2e suite first — Playwright will
// catch anything that breaks htmx / inline scripts / iframes.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()

		// Stop browsers from sniffing declared MIME types.
		if h.Get("X-Content-Type-Options") == "" {
			h.Set("X-Content-Type-Options", "nosniff")
		}

		// Refuse to be framed by other origins — clickjacking defense.
		if h.Get("X-Frame-Options") == "" {
			h.Set("X-Frame-Options", "DENY")
		}

		// Do not leak the current URL as Referer on outbound links.
		if h.Get("Referrer-Policy") == "" {
			h.Set("Referrer-Policy", "no-referrer")
		}

		// Turn off browser features we never need.
		if h.Get("Permissions-Policy") == "" {
			h.Set("Permissions-Policy", "geolocation=(), microphone=(), camera=(), payment=()")
		}

		next.ServeHTTP(w, r)
	})
}
