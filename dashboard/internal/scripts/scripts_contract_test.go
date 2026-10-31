package scripts

import "testing"

func TestZATCARuntimeScriptsAreCatalogued(t *testing.T) {
	tests := []struct {
		name    string
		control string
	}{
		{name: "setup-zatca-daemon.sh", control: "setup zatca-daemon"},
		{name: "health-zatca-daemon.sh", control: "setup zatca-health"},
		{name: "reload-zatca-daemon.sh", control: "setup zatca-reload"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			script := Find(tt.name)
			if script == nil {
				t.Fatalf("%s is not in the dashboard catalog", tt.name)
			}
			if got := script.ControlCommand(); got != tt.control {
				t.Fatalf("ControlCommand() = %q, want %q", got, tt.control)
			}
		})
	}
}

func TestZATCARuntimeHealthScriptIsNotDangerous(t *testing.T) {
	script := Find("health-zatca-daemon.sh")
	if script == nil {
		t.Fatal("health-zatca-daemon.sh is not in the dashboard catalog")
	}
	if script.Danger {
		t.Fatal("health checks must not require destructive-action confirmation")
	}
}
