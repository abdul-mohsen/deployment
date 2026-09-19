package main

import "testing"

func TestRoleForContainerUsesOnlyApprovedSources(t *testing.T) {
	tests := []struct {
		name   string
		labels map[string]string
		want   string
		ok     bool
	}{
		{name: "/acme-backend.web.1", want: "backend", ok: true},
		{name: "/acme-frontend.web.1", want: "frontend", ok: true},
		{name: "/dashboard-1", labels: map[string]string{"com.ifritah.observability": "dashboard"}, want: "dashboard", ok: true},
		{name: "/random-container", want: "", ok: false},
		{name: "/acme-backend.web.1", labels: map[string]string{"com.ifritah.observability": "other"}, want: "backend", ok: true},
	}
	for _, test := range tests {
		role, ok := roleForContainer(containerSummary{Names: []string{test.name}, Labels: test.labels})
		if role != test.want || ok != test.ok {
			t.Fatalf("roleForContainer(%q) = %q, %v; want %q, %v", test.name, role, ok, test.want, test.ok)
		}
	}
}

func TestWorkingSetAndCPURatio(t *testing.T) {
	if got := workingSetBytes(memoryStats{Usage: 100, Stats: map[string]uint64{"cache": 40}}); got != 60 {
		t.Fatalf("workingSetBytes = %d, want 60", got)
	}
	if got := cpuRatio(containerStats{
		CPUStats:    cpuStats{CPUUsage: cpuUsage{TotalUsage: 300}, SystemCPUUsage: 1200, OnlineCPUs: 4},
		PreCPUStats: cpuStats{CPUUsage: cpuUsage{TotalUsage: 100}, SystemCPUUsage: 800},
	}); got != 2 {
		t.Fatalf("cpuRatio = %v, want 2", got)
	}
}
