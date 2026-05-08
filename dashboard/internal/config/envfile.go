package config

import (
	"bufio"
	"os"
	"strings"
)

// LoadEnvFiles reads simple KEY=VALUE files (shell-style, with optional
// `export ` prefix and # comments) and merges them into the process
// environment. Files listed earlier win — i.e. an existing key is never
// overwritten. This mirrors `verify-mysql.sh`, which reads install.env first
// and falls back to config.env, so the dashboard sees the exact same MySQL
// admin credentials the deployment scripts use.
//
// Quoting:
//   FOO=bar         -> bar
//   FOO="bar baz"   -> bar baz
//   FOO='bar baz'   -> bar baz
//
// Missing files are silently skipped.
func LoadEnvFiles(paths ...string) {
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			line = strings.TrimPrefix(line, "export ")
			eq := strings.IndexByte(line, '=')
			if eq <= 0 {
				continue
			}
			k := strings.TrimSpace(line[:eq])
			v := strings.TrimSpace(line[eq+1:])
			if n := len(v); n >= 2 {
				if (v[0] == '"' && v[n-1] == '"') || (v[0] == '\'' && v[n-1] == '\'') {
					v = v[1 : n-1]
				}
			}
			if _, present := os.LookupEnv(k); !present {
				_ = os.Setenv(k, v)
			}
		}
		_ = f.Close()
	}
}
