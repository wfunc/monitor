package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/mem"
)

// thresholdConfig groups all alert thresholds.
type thresholdConfig struct {
	cpuUsage     float64
	memUsage     float64
	diskUsage    float64
	diskPath     string
	sampleEvery  time.Duration
	webhookURL   string
	serviceName  string
	alertType    string
	alertStatus  string
	accountID    string
	accountName  string
	platform     string
	httpClient   *http.Client
	hostname     string
	ioWaitUsage  float64
	prevCPUTimes *cpu.TimesStat
}

// metricsSnapshot contains the collected metrics for a single sample.
type metricsSnapshot struct {
	cpuPercent    float64
	memPercent    float64
	diskPercent   float64
	diskPath      string
	ioWaitPercent float64
}

func main() {
	cfg := parseFlags()
	cfg.httpClient = &http.Client{Timeout: 10 * time.Second}
	hostname, err := os.Hostname()
	if err != nil {
		cfg.hostname = "unknown"
	} else {
		cfg.hostname = hostname
	}

	if cfg.webhookURL == "" {
		log.Println("webhook URL not configured; alerts will not be sent to a remote endpoint")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle SIGINT/SIGTERM gracefully so we can exit cleanly.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-signals
		fmt.Println("\nReceived interrupt signal, shutting down...")
		cancel()
	}()

	if err := monitor(ctx, &cfg); err != nil {
		log.Fatalf("monitoring failed: %v", err)
	}
}

func parseFlags() thresholdConfig {
	cfg := thresholdConfig{}
	flag.Float64Var(&cfg.cpuUsage, "cpu", 80, "CPU usage alert threshold as a percentage")
	flag.Float64Var(&cfg.memUsage, "mem", 80, "Memory usage alert threshold as a percentage")
	flag.Float64Var(&cfg.diskUsage, "disk", 80, "Disk usage alert threshold as a percentage")
	flag.StringVar(&cfg.diskPath, "disk-path", "/", "Filesystem path to monitor for disk usage")
	flag.Float64Var(&cfg.ioWaitUsage, "io-wait", 30, "IO wait percentage alert threshold (set <=0 to disable)")
	interval := flag.Duration("interval", 10*time.Second, "Sampling interval (e.g. 10s, 1m)")
	flag.StringVar(&cfg.webhookURL, "webhook-url", "", "Webhook endpoint to post alerts (required for remote notifications)")
	flag.StringVar(&cfg.serviceName, "service-name", "system-monitor-service", "Value for the service field in the webhook payload")
	flag.StringVar(&cfg.alertType, "alert-type", "accountAnomaly", "Value for the type field in the webhook payload")
	flag.StringVar(&cfg.alertStatus, "alert-status", "warning", "Status string stored in payload data.status")
	flag.StringVar(&cfg.accountID, "account-id", "", "Optional account identifier added to payload data.accountId")
	flag.StringVar(&cfg.accountName, "account-name", "", "Optional account name added to payload data.accountName")
	flag.StringVar(&cfg.platform, "platform", "system", "Platform value stored in payload data.platform")
	flag.Parse()
	cfg.sampleEvery = *interval

	if cfg.cpuUsage <= 0 || cfg.cpuUsage > 100 ||
		cfg.memUsage <= 0 || cfg.memUsage > 100 ||
		cfg.diskUsage <= 0 || cfg.diskUsage > 100 {
		log.Fatal("thresholds must be within (0, 100]")
	}

	if cfg.ioWaitUsage > 100 {
		log.Fatal("io-wait threshold must be <= 100")
	}

	if cfg.sampleEvery <= 0 {
		log.Fatal("interval must be greater than zero")
	}

	return cfg
}

func monitor(ctx context.Context, cfg *thresholdConfig) error {
	ticker := time.NewTicker(cfg.sampleEvery)
	defer ticker.Stop()

	fmt.Printf("Monitoring started: CPU>%0.1f%%, Mem>%0.1f%%, Disk(%s)>%0.1f%%, interval=%s\n",
		cfg.cpuUsage, cfg.memUsage, cfg.diskPath, cfg.diskUsage, cfg.sampleEvery)

	// Prime CPU percent calculation; the first call with interval=0 returns 0.
	if _, err := cpu.PercentWithContext(ctx, 0, false); err != nil {
		return fmt.Errorf("priming CPU metrics: %w", err)
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			snapshot, err := collectMetrics(ctx, cfg)
			if err != nil {
				log.Printf("collecting metrics failed: %v", err)
				continue
			}
			report(ctx, snapshot, cfg)
		}
	}
}

func collectMetrics(ctx context.Context, cfg *thresholdConfig) (metricsSnapshot, error) {
	cpuPercent, err := currentCPUPercent(ctx)
	if err != nil {
		return metricsSnapshot{}, err
	}

	memStats, err := mem.VirtualMemoryWithContext(ctx)
	if err != nil {
		return metricsSnapshot{}, fmt.Errorf("fetching memory: %w", err)
	}

	diskStats, err := disk.UsageWithContext(ctx, cfg.diskPath)
	if err != nil {
		return metricsSnapshot{}, fmt.Errorf("fetching disk usage for %s: %w", cfg.diskPath, err)
	}

	ioWaitPercent, err := currentIOWaitPercent(ctx, cfg)
	if err != nil {
		log.Printf("fetching io wait percent failed: %v", err)
		ioWaitPercent = 0
	}

	return metricsSnapshot{
		cpuPercent:    round(cpuPercent, 1),
		memPercent:    round(memStats.UsedPercent, 1),
		diskPercent:   round(diskStats.UsedPercent, 1),
		diskPath:      cfg.diskPath,
		ioWaitPercent: round(ioWaitPercent, 1),
	}, nil
}

func currentCPUPercent(ctx context.Context) (float64, error) {
	values, err := cpu.PercentWithContext(ctx, 0, false)
	if err != nil {
		return 0, fmt.Errorf("fetching CPU percent: %w", err)
	}
	if len(values) == 0 {
		return 0, fmt.Errorf("no CPU percentage data returned")
	}
	return values[0], nil
}

func currentIOWaitPercent(ctx context.Context, cfg *thresholdConfig) (float64, error) {
	stats, err := cpu.TimesWithContext(ctx, false)
	if err != nil {
		return 0, fmt.Errorf("fetching CPU times: %w", err)
	}
	if len(stats) == 0 {
		return 0, fmt.Errorf("no CPU times returned")
	}

	current := stats[0]
	if cfg.prevCPUTimes == nil {
		cfg.prevCPUTimes = &cpu.TimesStat{}
		*cfg.prevCPUTimes = current
		return 0, nil
	}

	prev := *cfg.prevCPUTimes
	totalDelta := current.Total() - prev.Total()
	if totalDelta <= 0 {
		*cfg.prevCPUTimes = current
		return 0, nil
	}

	ioWaitDelta := current.Iowait - prev.Iowait
	*cfg.prevCPUTimes = current
	if ioWaitDelta <= 0 {
		return 0, nil
	}

	percent := (ioWaitDelta / totalDelta) * 100
	if percent < 0 {
		return 0, nil
	}
	if percent > 100 {
		percent = 100
	}
	return percent, nil
}

func report(ctx context.Context, snapshot metricsSnapshot, cfg *thresholdConfig) {
	timestamp := time.Now().Format(time.RFC3339)

	fmt.Printf("[%s] CPU: %5.1f%% | MEM: %5.1f%% | DISK(%s): %5.1f%% | IOWAIT: %5.1f%%\n",
		timestamp, snapshot.cpuPercent, snapshot.memPercent, snapshot.diskPath, snapshot.diskPercent, snapshot.ioWaitPercent)

	if snapshot.cpuPercent > cfg.cpuUsage {
		triggerAlert(ctx, cfg, "CPU", snapshot.cpuPercent, cfg.cpuUsage)
	}
	if snapshot.memPercent > cfg.memUsage {
		triggerAlert(ctx, cfg, "Memory", snapshot.memPercent, cfg.memUsage)
	}
	if snapshot.diskPercent > cfg.diskUsage {
		triggerAlert(ctx, cfg, fmt.Sprintf("Disk %s", snapshot.diskPath), snapshot.diskPercent, cfg.diskUsage)
	}
	if cfg.ioWaitUsage > 0 && snapshot.ioWaitPercent > cfg.ioWaitUsage {
		triggerAlert(ctx, cfg, "IO Wait", snapshot.ioWaitPercent, cfg.ioWaitUsage)
	}
}

func triggerAlert(ctx context.Context, cfg *thresholdConfig, resource string, actual, threshold float64) {
	reason := fmt.Sprintf("%s usage %.1f%% exceeds threshold %.1f%%", resource, actual, threshold)
	fmt.Printf("ALERT: %s\n", reason)
	sendWebhook(ctx, cfg, resource, actual, threshold, reason)
}

func round(value float64, precision int) float64 {
	factor := math.Pow(10, float64(precision))
	return math.Round(value*factor) / factor
}

func sendWebhook(ctx context.Context, cfg *thresholdConfig, resource string, actual, threshold float64, reason string) {
	if cfg.webhookURL == "" || cfg.httpClient == nil {
		return
	}

	timestamp := time.Now().Format(time.RFC3339)
	data := map[string]any{
		"resource":  resource,
		"actual":    round(actual, 2),
		"threshold": round(threshold, 2),
		"status":    cfg.alertStatus,
		"reason":    reason,
		"platform":  cfg.platform,
		"host":      cfg.hostname,
		"timestamp": timestamp,
	}
	if cfg.accountID != "" {
		data["accountId"] = cfg.accountID
	}
	if cfg.accountName != "" {
		data["accountName"] = cfg.accountName
	}

	payload := map[string]any{
		"type":      cfg.alertType,
		"service":   cfg.serviceName,
		"timestamp": timestamp,
		"data":      data,
	}

	reqBody, err := json.Marshal(payload)
	if err != nil {
		log.Printf("failed to marshal webhook payload: %v", err)
		return
	}

	fmt.Printf("Webhook Payload: %+v\n", payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.webhookURL, bytes.NewReader(reqBody))
	if err != nil {
		log.Printf("failed to build webhook request: %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := cfg.httpClient.Do(req)
	if err != nil {
		log.Printf("webhook request failed: %v", err)
		return
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		log.Printf("webhook responded with status %s", resp.Status)
	}
}
