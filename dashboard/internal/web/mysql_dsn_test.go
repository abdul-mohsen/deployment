package web

import (
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

// mysqlDSN passwords with special chars must round-trip through the DSN
// parser. Modern go-sql-driver/mysql (v1.10+) is fairly permissive with the
// naive `user:pw@tcp(...)/db` format, but tenant DB passwords are
// auto-generated openssl base64 — one day a driver update could change
// parsing rules. Building the DSN via mysql.Config.FormatDSN is the
// documented + guaranteed-stable path.
func TestMysqlDSN_PasswordWithSpecialChars(t *testing.T) {
	tests := []struct {
		name     string
		password string
	}{
		{"contains @", "sec@ret"},
		{"contains :", "with:colon"},
		{"contains /", "sla/sh"},
		{"contains ?", "que?ry"},
		{"contains #", "ha#sh"},
		{"contains &", "am&persand"},
		{"contains =", "eq=uals"},
		{"contains all", "@:/?#&="},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dsn := mysqlDSN("user", tc.password, "localhost", "3306", "db", 10*time.Second, false)
			cfg, err := mysql.ParseDSN(dsn)
			if err != nil {
				t.Fatalf("ParseDSN failed on %q: %v (dsn=%q)", tc.password, err, dsn)
			}
			if cfg.Passwd != tc.password {
				t.Errorf("password round-trip: got %q, want %q (dsn=%q)", cfg.Passwd, tc.password, dsn)
			}
			if cfg.User != "user" {
				t.Errorf("user got %q, want %q", cfg.User, "user")
			}
			if cfg.DBName != "db" {
				t.Errorf("dbname got %q, want %q", cfg.DBName, "db")
			}
			if cfg.Addr != "localhost:3306" {
				t.Errorf("addr got %q, want %q", cfg.Addr, "localhost:3306")
			}
		})
	}
}

func TestMysqlDSN_ParseTime(t *testing.T) {
	dsn := mysqlDSN("u", "p", "h", "3306", "d", 15*time.Second, true)
	if !strings.Contains(dsn, "parseTime=true") {
		t.Errorf("parseTime=true missing from DSN: %s", dsn)
	}
	dsn2 := mysqlDSN("u", "p", "h", "3306", "d", 15*time.Second, false)
	if strings.Contains(dsn2, "parseTime=true") {
		t.Errorf("parseTime=true unexpectedly present in DSN: %s", dsn2)
	}
}

func TestMysqlDSN_Timeout(t *testing.T) {
	dsn := mysqlDSN("u", "p", "h", "3306", "d", 30*time.Second, false)
	if !strings.Contains(dsn, "timeout=30s") {
		t.Errorf("timeout=30s missing from DSN: %s", dsn)
	}
}
