package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

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

func TestCollectCountsContainerCollectionErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/containers/json":
			_, _ = writer.Write([]byte(`[{"Id":"container-1","Names":["/acme-backend.1"],"State":"running"}]`))
		case "/containers/container-1/json", "/containers/container-1/stats":
			http.Error(writer, "collection failed", http.StatusBadGateway)
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	client, err := newDockerClient(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	exporter := &exporter{client: client}
	current := exporter.collect(context.Background())
	if current.scrapeErrors != 2 {
		t.Fatalf("scrapeErrors = %d, want 2", current.scrapeErrors)
	}
	if current.lastErrorMessage != "docker_container_collection_failed" {
		t.Fatalf("lastErrorMessage = %q, want container collection failure", current.lastErrorMessage)
	}
}
