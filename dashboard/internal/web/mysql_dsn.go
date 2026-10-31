package web

import (
	"time"

	"github.com/go-sql-driver/mysql"
)

// mysqlDSN builds a go-sql-driver DSN using mysql.Config.FormatDSN so
// passwords containing @, :, /, ? survive intact. The previous
// fmt.Sprintf pattern would silently corrupt DSNs when the password
// contained any of those characters.
func mysqlDSN(user, password, host, port, dbName string, timeout time.Duration, parseTime bool) string {
	cfg := mysql.NewConfig()
	cfg.User = user
	cfg.Passwd = password
	cfg.Net = "tcp"
	cfg.Addr = host + ":" + port
	cfg.DBName = dbName
	cfg.Timeout = timeout
	cfg.ParseTime = parseTime
	cfg.AllowNativePasswords = true
	return cfg.FormatDSN()
}
