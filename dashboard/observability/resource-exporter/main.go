package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultDockerAPIURL = "http://docker-api-filter-openobserve:2375"
	defaultListenAddr   = ":8080"
	defaultPollInterval = 15 * time.Second
	maxResponseBytes    = 4 * 1024 * 1024
)

var tenantContainerPattern = regexp.MustCompile(`^/?[a-z0-9][a-z0-9-]{0,61}-(backend|frontend)(?:\.[A-Za-z0-9_.-]+)?$`)

type containerSummary struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	State  string            `json:"State"`
	Labels map[string]string `json:"Labels"`
}

type containerInspect struct {
	RestartCount int `json:"RestartCount"`
	State        struct {
		Running bool `json:"Running"`
	} `json:"State"`
}

type cpuUsage struct {
	TotalUsage uint64 `json:"total_usage"`
}

type cpuStats struct {
	CPUUsage       cpuUsage `json:"cpu_usage"`
	SystemCPUUsage uint64   `json:"system_cpu_usage"`
	OnlineCPUs     uint32   `json:"online_cpus"`
}

type memoryStats struct {
	Usage uint64            `json:"usage"`
	Stats map[string]uint64 `json:"stats"`
}

type networkStats struct {
	RxBytes uint64 `json:"rx_bytes"`
	TxBytes uint64 `json:"tx_bytes"`
}

type containerStats struct {
	CPUStats    cpuStats                `json:"cpu_stats"`
	PreCPUStats cpuStats                `json:"precpu_stats"`
	MemoryStats memoryStats             `json:"memory_stats"`
	Networks    map[string]networkStats `json:"networks"`
}

type roleMetrics struct {
	cpuRatio       float64
	memoryBytes    uint64
	restarts       uint64
	networkRxBytes uint64
	networkTxBytes uint64
	running        uint64
	containers     uint64
}

type snapshot struct {
	roles            map[string]roleMetrics
	allowlisted      uint64
	scrapeErrors     uint64
	lastSuccess      time.Time
	lastErrorUnix    int64
	lastErrorMessage string
}

type dockerClient struct {
	baseURL string
	client  *http.Client
}

func newDockerClient(rawURL string) (*dockerClient, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return nil, fmt.Errorf("invalid Docker API URL")
	}
	return &dockerClient{
		baseURL: strings.TrimRight(parsed.String(), "/"),
		client:  &http.Client{Timeout: 5 * time.Second},
	}, nil
}

func (c *dockerClient) get(ctx context.Context, path string, target any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return err
	}
	response, err := c.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 512))
		return fmt.Errorf("Docker API returned status %d", response.StatusCode)
	}
	body := io.LimitReader(response.Body, maxResponseBytes)
	if err := json.NewDecoder(body).Decode(target); err != nil {
		return fmt.Errorf("decode Docker API response: %w", err)
	}
	return nil
}

func (c *dockerClient) list(ctx context.Context) ([]containerSummary, error) {
	var containers []containerSummary
	if err := c.get(ctx, "/containers/json?all=1", &containers); err != nil {
		return nil, err
	}
	return containers, nil
}

func (c *dockerClient) inspect(ctx context.Context, id string) (containerInspect, error) {
	var inspect containerInspect
	err := c.get(ctx, "/containers/"+id+"/json", &inspect)
	return inspect, err
}

func (c *dockerClient) stats(ctx context.Context, id string) (containerStats, error) {
	var stats containerStats
	err := c.get(ctx, "/containers/"+id+"/stats?stream=false", &stats)
	return stats, err
}

func roleForContainer(container containerSummary) (string, bool) {
	if container.Labels != nil && container.Labels["com.ifritah.observability"] == "dashboard" {
		return "dashboard", true
	}
	for _, rawName := range container.Names {
		name := strings.TrimPrefix(rawName, "/")
		matches := tenantContainerPattern.FindStringSubmatch(name)
		if len(matches) == 2 {
			return matches[1], true
		}
	}
	return "", false
}

type exporter struct {
	client       *dockerClient
	listenAddr   string
	pollInterval time.Duration

	mu       sync.RWMutex
	snapshot snapshot
}

func newExporter() (*exporter, error) {
	client, err := newDockerClient(envOrDefault("DOCKER_API_URL", defaultDockerAPIURL))
	if err != nil {
		return nil, err
	}
	pollInterval, err := time.ParseDuration(envOrDefault("POLL_INTERVAL", defaultPollInterval.String()))
	if err != nil || pollInterval < time.Second {
		return nil, fmt.Errorf("POLL_INTERVAL must be at least 1s")
	}
	return &exporter{
		client:       client,
		listenAddr:   envOrDefault("LISTEN_ADDR", defaultListenAddr),
		pollInterval: pollInterval,
		snapshot: snapshot{
			roles: map[string]roleMetrics{
				"backend":   {},
				"frontend":  {},
				"dashboard": {},
			},
		},
	}, nil
}

func (e *exporter) collect(ctx context.Context) snapshot {
	roles := map[string]roleMetrics{
		"backend":   {},
		"frontend":  {},
		"dashboard": {},
	}
	containers, err := e.client.list(ctx)
	if err != nil {
		e.mu.Lock()
		e.snapshot.scrapeErrors++
		e.snapshot.lastErrorUnix = time.Now().Unix()
		e.snapshot.lastErrorMessage = "docker_list_failed"
		current := e.snapshot
		e.mu.Unlock()
		return current
	}

	var allowlisted uint64
	var pollErrors uint64
	for _, container := range containers {
		role, ok := roleForContainer(container)
		if !ok {
			continue
		}
		allowlisted++
		current := roles[role]
		current.containers++

		inspect, inspectErr := e.client.inspect(ctx, container.ID)
		if inspectErr == nil {
			current.restarts += uint64(maxInt(inspect.RestartCount, 0))
			if inspect.State.Running {
				current.running++
			}
		} else {
			pollErrors++
			if strings.EqualFold(container.State, "running") {
				current.running++
			}
		}

		if !strings.EqualFold(container.State, "running") {
			roles[role] = current
			continue
		}
		stats, statsErr := e.client.stats(ctx, container.ID)
		if statsErr != nil {
			pollErrors++
			roles[role] = current
			continue
		}
		current.cpuRatio += cpuRatio(stats)
		current.memoryBytes += workingSetBytes(stats.MemoryStats)
		for _, network := range stats.Networks {
			current.networkRxBytes += network.RxBytes
			current.networkTxBytes += network.TxBytes
		}
		roles[role] = current
	}

	current := snapshot{
		roles:       roles,
		allowlisted: allowlisted,
		lastSuccess: time.Now().UTC(),
	}
	e.mu.Lock()
	current.scrapeErrors = e.snapshot.scrapeErrors
	current.lastErrorUnix = e.snapshot.lastErrorUnix
	current.lastErrorMessage = e.snapshot.lastErrorMessage
	if pollErrors > 0 {
		current.scrapeErrors += pollErrors
		current.lastErrorUnix = time.Now().Unix()
		current.lastErrorMessage = "docker_container_collection_failed"
	}
	e.snapshot = current
	e.mu.Unlock()
	return current
}

func cpuRatio(stats containerStats) float64 {
	if stats.CPUStats.CPUUsage.TotalUsage < stats.PreCPUStats.CPUUsage.TotalUsage ||
		stats.CPUStats.SystemCPUUsage < stats.PreCPUStats.SystemCPUUsage {
		return 0
	}
	cpuDelta := float64(stats.CPUStats.CPUUsage.TotalUsage - stats.PreCPUStats.CPUUsage.TotalUsage)
	systemDelta := float64(stats.CPUStats.SystemCPUUsage - stats.PreCPUStats.SystemCPUUsage)
	if cpuDelta <= 0 || systemDelta <= 0 {
		return 0
	}
	cpus := stats.CPUStats.OnlineCPUs
	if cpus == 0 {
		cpus = 1
	}
	return (cpuDelta / systemDelta) * float64(cpus)
}

func workingSetBytes(stats memoryStats) uint64 {
	cache := stats.Stats["cache"]
	if cache >= stats.Usage {
		return 0
	}
	return stats.Usage - cache
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}

func (e *exporter) poll(ctx context.Context) {
	e.collect(ctx)
	ticker := time.NewTicker(e.pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pollCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			e.collect(pollCtx)
			cancel()
		}
	}
}

func (e *exporter) metricsHandler(w http.ResponseWriter, _ *http.Request) {
	e.mu.RLock()
	current := e.snapshot
	e.mu.RUnlock()

	var builder strings.Builder
	builder.WriteString("# HELP ifritah_resource_exporter_up Whether the resource exporter is running.\n")
	builder.WriteString("# TYPE ifritah_resource_exporter_up gauge\nifritah_resource_exporter_up 1\n")
	builder.WriteString("# HELP ifritah_resource_exporter_allowlisted_containers Number of explicitly allow-listed containers seen in the last poll.\n")
	builder.WriteString("# TYPE ifritah_resource_exporter_allowlisted_containers gauge\n")
	fmt.Fprintf(&builder, "ifritah_resource_exporter_allowlisted_containers %d\n", current.allowlisted)
	builder.WriteString("# HELP ifritah_resource_exporter_scrape_errors_total Docker API collection failures.\n")
	builder.WriteString("# TYPE ifritah_resource_exporter_scrape_errors_total counter\n")
	fmt.Fprintf(&builder, "ifritah_resource_exporter_scrape_errors_total %d\n", current.scrapeErrors)
	builder.WriteString("# HELP ifritah_resource_exporter_last_success_timestamp_seconds Last successful Docker API collection time.\n")
	builder.WriteString("# TYPE ifritah_resource_exporter_last_success_timestamp_seconds gauge\n")
	if !current.lastSuccess.IsZero() {
		fmt.Fprintf(&builder, "ifritah_resource_exporter_last_success_timestamp_seconds %d\n", current.lastSuccess.Unix())
	}
	builder.WriteString("# HELP ifritah_container_cpu_usage_ratio Aggregate Docker CPU usage ratio by approved container role.\n")
	builder.WriteString("# TYPE ifritah_container_cpu_usage_ratio gauge\n")
	builder.WriteString("# HELP ifritah_container_memory_working_set_bytes Aggregate Docker working set by approved container role.\n")
	builder.WriteString("# TYPE ifritah_container_memory_working_set_bytes gauge\n")
	builder.WriteString("# HELP ifritah_container_restarts_total Aggregate Docker restart count by approved container role.\n")
	builder.WriteString("# TYPE ifritah_container_restarts_total counter\n")
	builder.WriteString("# HELP ifritah_container_network_receive_bytes_total Aggregate Docker received bytes by approved container role.\n")
	builder.WriteString("# TYPE ifritah_container_network_receive_bytes_total counter\n")
	builder.WriteString("# HELP ifritah_container_network_transmit_bytes_total Aggregate Docker transmitted bytes by approved container role.\n")
	builder.WriteString("# TYPE ifritah_container_network_transmit_bytes_total counter\n")
	builder.WriteString("# HELP ifritah_container_running Number of running allow-listed containers by approved role.\n")
	builder.WriteString("# TYPE ifritah_container_running gauge\n")
	builder.WriteString("# HELP ifritah_container_count Number of allow-listed containers by approved role.\n")
	builder.WriteString("# TYPE ifritah_container_count gauge\n")
	for _, role := range []string{"backend", "frontend", "dashboard"} {
		values := current.roles[role]
		label := fmt.Sprintf(`{container_role=%q}`, role)
		fmt.Fprintf(&builder, "ifritah_container_cpu_usage_ratio%s %.6f\n", label, values.cpuRatio)
		fmt.Fprintf(&builder, "ifritah_container_memory_working_set_bytes%s %d\n", label, values.memoryBytes)
		fmt.Fprintf(&builder, "ifritah_container_restarts_total%s %d\n", label, values.restarts)
		fmt.Fprintf(&builder, "ifritah_container_network_receive_bytes_total%s %d\n", label, values.networkRxBytes)
		fmt.Fprintf(&builder, "ifritah_container_network_transmit_bytes_total%s %d\n", label, values.networkTxBytes)
		fmt.Fprintf(&builder, "ifritah_container_running%s %d\n", label, values.running)
		fmt.Fprintf(&builder, "ifritah_container_count%s %d\n", label, values.containers)
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte(builder.String()))
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

func (e *exporter) run(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", e.metricsHandler)
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/readyz", healthHandler)
	server := &http.Server{
		Addr:              e.listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	go e.poll(ctx)
	errCh := make(chan error, 1)
	go func() { errCh <- server.ListenAndServe() }()

	select {
	case <-ctx.Done():
	case err := <-errCh:
		if err != nil && err != http.ErrServerClosed {
			return err
		}
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return server.Shutdown(shutdownCtx)
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
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

	exporter, err := newExporter()
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := exporter.run(ctx); err != nil {
		log.Fatal(err)
	}
}
