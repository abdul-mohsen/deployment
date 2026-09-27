package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSignalByPath(t *testing.T) {
	tests := []struct {
		path string
		name string
		ok   bool
	}{
		{path: "/v1/logs", name: "logs", ok: true},
		{path: "/v1/metrics", name: "metrics", ok: true},
		{path: "/v1/traces", name: "traces", ok: true},
		{path: "/v1/health", name: "health", ok: true},
		{path: "/v1/unknown", ok: false},
	}
	for _, test := range tests {
		signal, ok := signalByPath(test.path)
		if ok != test.ok || (ok && signal.name != test.name) {
			t.Fatalf("signalByPath(%q) = %#v, %v; want %q, %v", test.path, signal, ok, test.name, test.ok)
		}
	}
}

func TestForwardPathMapsHealthToMetricsEndpoint(t *testing.T) {
	health, ok := signalByPath("/v1/health")
	if !ok {
		t.Fatal("health signal must be registered")
	}
	if got := forwardPath(health); got != "/v1/metrics" {
		t.Fatalf("forwardPath(health) = %q, want /v1/metrics", got)
	}

	metrics, ok := signalByPath("/v1/metrics")
	if !ok {
		t.Fatal("metrics signal must be registered")
	}
	if got := forwardPath(metrics); got != "/v1/metrics" {
		t.Fatalf("forwardPath(metrics) = %q, want /v1/metrics", got)
	}
}

func TestDiskQueueIsBoundedAndDurable(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "queue")
	queue, err := newDiskQueue(dir, 5)
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := queue.enqueue([]byte("1234"))
	if err != nil || !accepted {
		t.Fatalf("enqueue accepted=%v err=%v", accepted, err)
	}
	accepted, err = queue.enqueue([]byte("56"))
	if err != nil || accepted {
		t.Fatalf("queue should reject a full record, accepted=%v err=%v", accepted, err)
	}
	file, ok := queue.peek()
	if !ok {
		t.Fatal("expected a queued record")
	}
	payload, err := queue.read(file, 5)
	if err != nil || string(payload) != "1234" {
		t.Fatalf("read payload=%q err=%v", payload, err)
	}
	if err := queue.remove(file); err != nil {
		t.Fatal(err)
	}
	if _, ok := queue.peek(); ok {
		t.Fatal("queue should be empty after remove")
	}

	if err := os.WriteFile(filepath.Join(dir, "ignored.tmp"), []byte("not a record"), 0o600); err != nil {
		t.Fatal(err)
	}
	reloaded, err := newDiskQueue(dir, 5)
	if err != nil {
		t.Fatal(err)
	}
	if bytes, files := reloaded.snapshot(); bytes != 0 || files != 0 {
		t.Fatalf("temporary files must not count, bytes=%d files=%d", bytes, files)
	}
}
