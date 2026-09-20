package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	defaultListenAddr  = ":4318"
	defaultHealthAddr  = ":8080"
	defaultQueueBytes  = int64(64 * 1024 * 1024)
	defaultMaxBodySize = int64(4 * 1024 * 1024)
)

type signalConfig struct {
	name   string
	path   string
	stream string
}

var signals = []signalConfig{
	{name: "logs", path: "/v1/logs", stream: "ifritah_logs_v1"},
	{name: "metrics", path: "/v1/metrics"},
	{name: "traces", path: "/v1/traces", stream: "ifritah_traces_v1"},
	{name: "health", path: "/v1/health"},
}

func signalByPath(path string) (signalConfig, bool) {
	for _, signal := range signals {
		if signal.path == path {
			return signal, true
		}
	}
	return signalConfig{}, false
}

func forwardPath(signal signalConfig) string {
	// Health is an isolated OTLP-metrics ingress and queue, but OpenObserve
	// stores native metrics by metric family. It therefore shares the native
	// metrics endpoint without a stream-name override.
	if signal.name == "health" {
		return "/v1/metrics"
	}
	return signal.path
}

type queuedFile struct {
	path string
	size int64
	mod  time.Time
}

type diskQueue struct {
	dir      string
	maxBytes int64

	mu    sync.Mutex
	bytes int64
	next  uint64
}

func newDiskQueue(dir string, maxBytes int64) (*diskQueue, error) {
	if maxBytes <= 0 {
		return nil, fmt.Errorf("queue max bytes must be positive")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create queue directory: %w", err)
	}

	queue := &diskQueue{dir: dir, maxBytes: maxBytes, next: uint64(time.Now().UnixNano())}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read queue directory: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".bin") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, fmt.Errorf("stat queued file: %w", err)
		}
		queue.bytes += info.Size()
	}
	return queue, nil
}

func (q *diskQueue) enqueue(payload []byte) (bool, error) {
	if int64(len(payload)) > q.maxBytes {
		return false, nil
	}

	q.mu.Lock()
	defer q.mu.Unlock()

	if q.bytes+int64(len(payload)) > q.maxBytes {
		return false, nil
	}

	sequence := atomic.AddUint64(&q.next, 1)
	name := fmt.Sprintf("%020d-%020d.bin", time.Now().UnixNano(), sequence)
	tmpPath := filepath.Join(q.dir, name+".tmp")
	finalPath := filepath.Join(q.dir, name)

	file, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false, fmt.Errorf("create queue record: %w", err)
	}
	_, writeErr := file.Write(payload)
	if writeErr == nil {
		writeErr = file.Sync()
	}
	closeErr := file.Close()
	if writeErr != nil {
		_ = os.Remove(tmpPath)
		return false, fmt.Errorf("write queue record: %w", writeErr)
	}
	if closeErr != nil {
		_ = os.Remove(tmpPath)
		return false, fmt.Errorf("close queue record: %w", closeErr)
	}
	if err := os.Rename(tmpPath, finalPath); err != nil {
		_ = os.Remove(tmpPath)
		return false, fmt.Errorf("publish queue record: %w", err)
	}

	q.bytes += int64(len(payload))
	return true, nil
}

func (q *diskQueue) peek() (queuedFile, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()

	entries, err := os.ReadDir(q.dir)
	if err != nil {
		return queuedFile{}, false
	}
	files := make([]queuedFile, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".bin") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, queuedFile{
			path: filepath.Join(q.dir, entry.Name()),
			size: info.Size(),
			mod:  info.ModTime(),
		})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].path < files[j].path })
	if len(files) == 0 {
		return queuedFile{}, false
	}
	return files[0], true
}

func (q *diskQueue) read(file queuedFile, maxBytes int64) ([]byte, error) {
	if file.size > maxBytes {
		return nil, fmt.Errorf("queued record exceeds read limit")
	}
	return os.ReadFile(file.path)
}

func (q *diskQueue) remove(file queuedFile) error {
	q.mu.Lock()
	defer q.mu.Unlock()

	if err := os.Remove(file.path); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	q.bytes -= file.size
	if q.bytes < 0 {
		q.bytes = 0
	}
	return nil
}

func (q *diskQueue) snapshot() (bytes int64, files int) {
	q.mu.Lock()
	defer q.mu.Unlock()

	entries, err := os.ReadDir(q.dir)
	if err != nil {
		return q.bytes, 0
	}
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".bin") {
			files++
		}
	}
	return q.bytes, files
}

type gatewayMetrics struct {
	mu sync.RWMutex

	enqueued       map[string]uint64
	dropped        map[string]map[string]uint64
	forwarded      map[string]map[string]uint64
	forwardFails   map[string]uint64
	lastSuccess    map[string]time.Time
	authBlocked    map[string]bool
	receivedBytes  map[string]uint64
	oversized      map[string]uint64
	queueWriteErrs map[string]uint64
}

func newGatewayMetrics() *gatewayMetrics {
	return &gatewayMetrics{
		enqueued:       make(map[string]uint64),
		dropped:        make(map[string]map[string]uint64),
		forwarded:      make(map[string]map[string]uint64),
		forwardFails:   make(map[string]uint64),
		lastSuccess:    make(map[string]time.Time),
		authBlocked:    make(map[string]bool),
		receivedBytes:  make(map[string]uint64),
		oversized:      make(map[string]uint64),
		queueWriteErrs: make(map[string]uint64),
	}
}

func increment(mapValue map[string]uint64, key string) {
	mapValue[key]++
}

func (m *gatewayMetrics) addEnqueued(signal string, bytes uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.enqueued[signal]++
	m.receivedBytes[signal] += bytes
}

func (m *gatewayMetrics) addDropped(signal, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.dropped[signal] == nil {
		m.dropped[signal] = make(map[string]uint64)
	}
	increment(m.dropped[signal], reason)
}

func (m *gatewayMetrics) addForwarded(signal, statusClass string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.forwarded[signal] == nil {
		m.forwarded[signal] = make(map[string]uint64)
	}
	increment(m.forwarded[signal], statusClass)
	if statusClass == "2xx" {
		m.lastSuccess[signal] = time.Now().UTC()
		m.authBlocked[signal] = false
	}
}

func (m *gatewayMetrics) addForwardFailure(signal string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.forwardFails[signal]++
}

func (m *gatewayMetrics) setAuthBlocked(signal string, blocked bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.authBlocked[signal] = blocked
}

func (m *gatewayMetrics) addOversized(signal string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.oversized[signal]++
}

func (m *gatewayMetrics) addQueueWriteError(signal string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.queueWriteErrs[signal]++
}

type gateway struct {
	queueRoot  string
	maxBytes   int64
	maxBody    int64
	listenAddr string
	healthAddr string
	baseURL    string
	username   string
	password   string

	client  *http.Client
	metrics *gatewayMetrics
	queues  map[string]*diskQueue
}

func newGateway() (*gateway, error) {
	queueRoot := envOrDefault("QUEUE_DIR", "/var/lib/openobserve-gateway")
	maxBytes, err := envInt64("QUEUE_MAX_BYTES", defaultQueueBytes)
	if err != nil {
		return nil, err
	}
	maxBody, err := envInt64("MAX_BODY_BYTES", defaultMaxBodySize)
	if err != nil {
		return nil, err
	}

	gateway := &gateway{
		queueRoot:  queueRoot,
		maxBytes:   maxBytes,
		maxBody:    maxBody,
		listenAddr: envOrDefault("LISTEN_ADDR", defaultListenAddr),
		healthAddr: envOrDefault("HEALTH_ADDR", defaultHealthAddr),
		baseURL:    strings.TrimRight(envOrDefault("OPENOBSERVE_BASE_URL", "http://openobserve:5080/api/default"), "/"),
		username:   envOrDefault("OPENOBSERVE_USERNAME", os.Getenv("ZO_ROOT_USER_EMAIL")),
		password:   envOrDefault("OPENOBSERVE_PASSWORD", os.Getenv("ZO_ROOT_USER_PASSWORD")),
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
		metrics: newGatewayMetrics(),
		queues:  make(map[string]*diskQueue, len(signals)),
	}

	for _, signal := range signals {
		queue, err := newDiskQueue(filepath.Join(queueRoot, signal.name), maxBytes)
		if err != nil {
			return nil, fmt.Errorf("initialize %s queue: %w", signal.name, err)
		}
		gateway.queues[signal.name] = queue
	}
	return gateway, nil
}

func (g *gateway) ingest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	signal, ok := signalByPath(r.URL.Path)
	if !ok {
		http.NotFound(w, r)
		return
	}

	if r.ContentLength > g.maxBody {
		g.metrics.addOversized(signal.name)
		g.metrics.addDropped(signal.name, "oversized")
		http.Error(w, "payload too large", http.StatusRequestEntityTooLarge)
		return
	}
	reader := io.LimitReader(r.Body, g.maxBody+1)
	payload, err := io.ReadAll(reader)
	if err != nil {
		http.Error(w, "payload read failed", http.StatusBadRequest)
		return
	}
	if int64(len(payload)) > g.maxBody {
		g.metrics.addOversized(signal.name)
		g.metrics.addDropped(signal.name, "oversized")
		http.Error(w, "payload too large", http.StatusRequestEntityTooLarge)
		return
	}
	if len(payload) == 0 {
		http.Error(w, "empty payload", http.StatusBadRequest)
		return
	}

	queued, err := g.queues[signal.name].enqueue(payload)
	if err != nil {
		g.metrics.addQueueWriteError(signal.name)
		http.Error(w, "queue unavailable", http.StatusServiceUnavailable)
		return
	}
	if queued {
		g.metrics.addEnqueued(signal.name, uint64(len(payload)))
		w.Header().Set("X-Ifritah-Queue", "accepted")
	} else {
		g.metrics.addDropped(signal.name, "queue_full")
		w.Header().Set("X-Ifritah-Queue", "dropped")
	}
	w.WriteHeader(http.StatusAccepted)
}

func (g *gateway) forward(ctx context.Context, signal signalConfig, payload []byte) (int, error) {
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		g.baseURL+forwardPath(signal),
		bytes.NewReader(payload),
	)
	if err != nil {
		return 0, err
	}
	request.Header.Set("Content-Type", "application/x-protobuf")
	request.Header.Set("Accept", "application/json")
	if signal.stream != "" {
		request.Header.Set("stream-name", signal.stream)
	}
	request.Header.Set("organization", "default")
	if g.username != "" {
		request.SetBasicAuth(g.username, g.password)
	}

	response, err := g.client.Do(request)
	if err != nil {
		return 0, err
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
	_ = response.Body.Close()
	return response.StatusCode, nil
}

func (g *gateway) runWorker(ctx context.Context, signal signalConfig) {
	queue := g.queues[signal.name]
	backoff := time.Second
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		file, ok := queue.peek()
		if !ok {
			select {
			case <-ctx.Done():
				return
			case <-time.After(500 * time.Millisecond):
			}
			continue
		}

		payload, err := queue.read(file, g.maxBody)
		if err != nil {
			g.metrics.addDropped(signal.name, "queue_corrupt")
			_ = queue.remove(file)
			continue
		}

		requestCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		status, forwardErr := g.forward(requestCtx, signal, payload)
		cancel()
		switch {
		case forwardErr == nil && status >= 200 && status < 300:
			g.metrics.addForwarded(signal.name, "2xx")
			g.metrics.setAuthBlocked(signal.name, false)
			_ = queue.remove(file)
			backoff = time.Second
		case forwardErr == nil && status == http.StatusBadRequest:
			g.metrics.addForwarded(signal.name, "4xx")
			g.metrics.addDropped(signal.name, "schema_4xx")
			_ = queue.remove(file)
			backoff = time.Second
		case forwardErr == nil && (status == http.StatusUnauthorized || status == http.StatusForbidden):
			g.metrics.addForwarded(signal.name, "4xx")
			g.metrics.setAuthBlocked(signal.name, true)
			g.metrics.addForwardFailure(signal.name)
			sleepContext(ctx, 30*time.Second)
		case forwardErr == nil && status >= 400 && status < 500:
			g.metrics.addForwarded(signal.name, "4xx")
			g.metrics.addDropped(signal.name, "non_retryable_4xx")
			_ = queue.remove(file)
			backoff = time.Second
		default:
			g.metrics.addForwardFailure(signal.name)
			sleepContext(ctx, backoff)
			if backoff < 30*time.Second {
				backoff *= 2
				if backoff > 30*time.Second {
					backoff = 30 * time.Second
				}
			}
		}
	}
}

func sleepContext(ctx context.Context, duration time.Duration) {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}

func (g *gateway) metricsHandler(w http.ResponseWriter, _ *http.Request) {
	var builder strings.Builder
	builder.WriteString("# HELP ifritah_gateway_up Whether the OpenObserve gateway process is running.\n")
	builder.WriteString("# TYPE ifritah_gateway_up gauge\nifritah_gateway_up 1\n")
	builder.WriteString("# HELP ifritah_gateway_queue_bytes Bytes currently waiting in the durable queue.\n")
	builder.WriteString("# TYPE ifritah_gateway_queue_bytes gauge\n")
	builder.WriteString("# HELP ifritah_gateway_queue_files Durable queue records currently waiting.\n")
	builder.WriteString("# TYPE ifritah_gateway_queue_files gauge\n")
	for _, signal := range signals {
		bytes, files := g.queues[signal.name].snapshot()
		fmt.Fprintf(&builder, "ifritah_gateway_queue_bytes{signal=%q} %d\n", signal.name, bytes)
		fmt.Fprintf(&builder, "ifritah_gateway_queue_files{signal=%q} %d\n", signal.name, files)
	}

	g.metrics.mu.RLock()
	defer g.metrics.mu.RUnlock()
	builder.WriteString("# HELP ifritah_gateway_enqueued_records_total Records accepted into the durable queue.\n")
	builder.WriteString("# TYPE ifritah_gateway_enqueued_records_total counter\n")
	builder.WriteString("# HELP ifritah_gateway_received_bytes_total Bytes accepted into the durable queue.\n")
	builder.WriteString("# TYPE ifritah_gateway_received_bytes_total counter\n")
	builder.WriteString("# HELP ifritah_gateway_dropped_records_total Records dropped by bounded queue or schema policy.\n")
	builder.WriteString("# TYPE ifritah_gateway_dropped_records_total counter\n")
	builder.WriteString("# HELP ifritah_gateway_forwarded_records_total Forward attempts by bounded HTTP status class.\n")
	builder.WriteString("# TYPE ifritah_gateway_forwarded_records_total counter\n")
	builder.WriteString("# HELP ifritah_gateway_forward_failures_total Forward failures requiring retry.\n")
	builder.WriteString("# TYPE ifritah_gateway_forward_failures_total counter\n")
	builder.WriteString("# HELP ifritah_gateway_auth_blocked Whether OpenObserve rejected credentials for a signal.\n")
	builder.WriteString("# TYPE ifritah_gateway_auth_blocked gauge\n")
	builder.WriteString("# HELP ifritah_gateway_last_success_timestamp_seconds Last successful export time.\n")
	builder.WriteString("# TYPE ifritah_gateway_last_success_timestamp_seconds gauge\n")
	builder.WriteString("# HELP ifritah_gateway_oversized_payloads_total Payloads rejected for exceeding the input limit.\n")
	builder.WriteString("# TYPE ifritah_gateway_oversized_payloads_total counter\n")
	builder.WriteString("# HELP ifritah_gateway_queue_write_errors_total Durable queue write errors.\n")
	builder.WriteString("# TYPE ifritah_gateway_queue_write_errors_total counter\n")
	for _, signal := range signals {
		name := signal.name
		fmt.Fprintf(&builder, "ifritah_gateway_enqueued_records_total{signal=%q} %d\n", name, g.metrics.enqueued[name])
		fmt.Fprintf(&builder, "ifritah_gateway_received_bytes_total{signal=%q} %d\n", name, g.metrics.receivedBytes[name])
		fmt.Fprintf(&builder, "ifritah_gateway_forward_failures_total{signal=%q} %d\n", name, g.metrics.forwardFails[name])
		fmt.Fprintf(&builder, "ifritah_gateway_auth_blocked{signal=%q} %d\n", name, boolFloat(g.metrics.authBlocked[name]))
		fmt.Fprintf(&builder, "ifritah_gateway_oversized_payloads_total{signal=%q} %d\n", name, g.metrics.oversized[name])
		fmt.Fprintf(&builder, "ifritah_gateway_queue_write_errors_total{signal=%q} %d\n", name, g.metrics.queueWriteErrs[name])
		if timestamp := g.metrics.lastSuccess[name]; !timestamp.IsZero() {
			fmt.Fprintf(&builder, "ifritah_gateway_last_success_timestamp_seconds{signal=%q} %d\n", name, timestamp.Unix())
		}
		for reason, value := range g.metrics.dropped[name] {
			fmt.Fprintf(&builder, "ifritah_gateway_dropped_records_total{signal=%q,reason=%q} %d\n", name, reason, value)
		}
		for statusClass, value := range g.metrics.forwarded[name] {
			fmt.Fprintf(&builder, "ifritah_gateway_forwarded_records_total{signal=%q,status_class=%q} %d\n", name, statusClass, value)
		}
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte(builder.String()))
}

func boolFloat(value bool) int {
	if value {
		return 1
	}
	return 0
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

func (g *gateway) run(ctx context.Context) error {
	ingestMux := http.NewServeMux()
	ingestMux.HandleFunc("/v1/logs", g.ingest)
	ingestMux.HandleFunc("/v1/metrics", g.ingest)
	ingestMux.HandleFunc("/v1/traces", g.ingest)
	ingestMux.HandleFunc("/v1/health", g.ingest)

	healthMux := http.NewServeMux()
	healthMux.HandleFunc("/healthz", healthHandler)
	healthMux.HandleFunc("/readyz", healthHandler)
	healthMux.HandleFunc("/metrics", g.metricsHandler)

	ingestServer := &http.Server{
		Addr:              g.listenAddr,
		Handler:           limitRequestBody(ingestMux, g.maxBody),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	healthServer := &http.Server{
		Addr:              g.healthAddr,
		Handler:           healthMux,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	for _, signal := range signals {
		go g.runWorker(ctx, signal)
	}

	errCh := make(chan error, 2)
	go func() { errCh <- ingestServer.ListenAndServe() }()
	go func() { errCh <- healthServer.ListenAndServe() }()

	select {
	case <-ctx.Done():
	case err := <-errCh:
		if err != nil && err != http.ErrServerClosed {
			return err
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = ingestServer.Shutdown(shutdownCtx)
	_ = healthServer.Shutdown(shutdownCtx)
	return nil
}

func limitRequestBody(next http.Handler, maxBytes int64) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBytes+1)
		next.ServeHTTP(w, r)
	})
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envInt64(name string, fallback int64) (int64, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return parsed, nil
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		response, err := http.Get("http://127.0.0.1:8080/healthz")
		if err != nil || response.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		_ = response.Body.Close()
		return
	}

	gateway, err := newGateway()
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := gateway.run(ctx); err != nil {
		log.Fatal(err)
	}
}

// Keep the binary self-contained while making the queue format explicit in
// tests and future migrations. It is intentionally unused by the HTTP path.
func encodeLength(length int64) []byte {
	header := make([]byte, 8)
	binary.BigEndian.PutUint64(header, uint64(length))
	return header
}
