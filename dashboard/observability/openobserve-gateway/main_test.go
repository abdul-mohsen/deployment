package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
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

func TestHealthUsesDedicatedNativeMetricsIngress(t *testing.T) {
	health, ok := signalByPath("/v1/health")
	if !ok {
		t.Fatal("health signal must be registered")
	}
	if health.stream != "" {
		t.Fatalf("health signal must not set a stream-name override, got %q", health.stream)
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

func TestDiskQueuePeekEmptyIsNotCorrupt(t *testing.T) {
	queue, err := newDiskQueue(t.TempDir(), 1024)
	if err != nil {
		t.Fatalf("newDiskQueue: %v", err)
	}
	if file, ok := queue.peek(); ok || file.path != "" {
		t.Fatalf("empty queue peek = %#v, %v", file, ok)
	}
}

func TestSignalQueuesHaveIndependentCapacity(t *testing.T) {
	t.Setenv("QUEUE_DIR", t.TempDir())
	t.Setenv("QUEUE_MAX_BYTES", "4")

	gateway, err := newGateway()
	if err != nil {
		t.Fatalf("newGateway: %v", err)
	}
	logs := gateway.queues["logs"]
	health := gateway.queues["health"]
	if logs == nil || health == nil {
		t.Fatal("expected logs and health queues")
	}
	if ok, err := logs.enqueue([]byte("logs")); err != nil || !ok {
		t.Fatalf("logs enqueue = %v, %v", ok, err)
	}
	if ok, err := health.enqueue([]byte("heal")); err != nil || !ok {
		t.Fatalf("health enqueue = %v, %v", ok, err)
	}
}

func TestWorkerEmptyQueueDoesNotEmitCorruptDrop(t *testing.T) {
	queue, err := newDiskQueue(t.TempDir(), 1024)
	if err != nil {
		t.Fatalf("newDiskQueue: %v", err)
	}
	gateway := &gateway{
		maxBody: 1024,
		metrics: newGatewayMetrics(),
		queues:  map[string]*diskQueue{"logs": queue},
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		gateway.runWorker(ctx, signalConfig{name: "logs", path: "/v1/logs", stream: "ifritah_logs_v1"})
		close(done)
	}()
	time.Sleep(25 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("empty worker did not stop after cancellation")
	}

	gateway.metrics.mu.RLock()
	defer gateway.metrics.mu.RUnlock()
	if got := gateway.metrics.dropped["logs"]["queue_corrupt"]; got != 0 {
		t.Fatalf("empty queue recorded queue_corrupt=%d", got)
	}
}
