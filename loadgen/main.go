package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"os/signal"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	billing "github.com/unimeter/go-unimeter"
)

var jsonOut bool

func main() {
	var (
		addrs       string
		scenario    string
		duration    time.Duration
		workers     int
		batchSize   int
		accounts    int
		metricCount int
	)

	flag.StringVar(&addrs, "addrs", "localhost:7001", "comma-separated node addresses")
	flag.StringVar(&scenario, "scenario", "async-throughput", "scenario: async-throughput, sync-throughput, sync-latency, scaling")
	flag.DurationVar(&duration, "duration", 30*time.Second, "test duration")
	flag.IntVar(&workers, "workers", runtime.NumCPU()*4, "concurrent workers (0 = scenario default)")
	flag.IntVar(&batchSize, "batch", 500, "events per batch")
	flag.IntVar(&accounts, "accounts", 10000, "unique account IDs (spread across partitions)")
	flag.IntVar(&metricCount, "metrics", 5, "number of metric codes")
	flag.BoolVar(&jsonOut, "json", false, "output results as JSON")
	flag.Parse()

	seeds := strings.Split(addrs, ",")

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	switch scenario {
	case "async-throughput":
		runThroughput(ctx, seeds, billing.DeliveryAsync, workers, batchSize, accounts, metricCount, duration)
	case "sync-throughput":
		runThroughput(ctx, seeds, billing.DeliverySync, workers, batchSize, accounts, metricCount, duration)
	case "sync-latency":
		runLatency(ctx, seeds, accounts, metricCount, duration)
	case "scaling":
		runScaling(ctx, seeds, batchSize, accounts, metricCount, duration)
	default:
		fmt.Fprintf(os.Stderr, "unknown scenario: %s\n", scenario)
		os.Exit(1)
	}
}

// ---------------- metrics setup ----------------

var metricCodes []string

func setupMetrics(ctx context.Context, client *billing.Client, n int) {
	metricCodes = make([]string, n)
	for i := range n {
		metricCodes[i] = fmt.Sprintf("bench_metric_%d", i)
		_ = client.Metrics.Create(ctx, billing.MetricSchema{
			Code:    metricCodes[i],
			AggType: billing.AggSum,
		})
	}
}

// ---------------- event generation ----------------

func makeBatch(rng *rand.Rand, size int, accounts int, mode billing.DeliveryMode) []billing.Event {
	events := make([]billing.Event, size)
	for i := range size {
		events[i] = billing.Event{
			AccountID:    uint64(rng.IntN(accounts)),
			MetricCode:   metricCodes[rng.IntN(len(metricCodes))],
			Value:        billing.Scale(float64(rng.IntN(1000)) + 0.5),
			Timestamp:    time.Now(),
			DeliveryMode: mode,
		}
	}
	return events
}

// ---------------- throughput scenario ----------------

func runThroughput(ctx context.Context, seeds []string, mode billing.DeliveryMode, workers, batchSize, accounts, metricCount int, duration time.Duration) {
	modeName := "async"
	if mode == billing.DeliverySync {
		modeName = "sync"
	}

	if !jsonOut {
		fmt.Printf("benchmark: %s throughput\n", strings.ToUpper(modeName))
		fmt.Printf("  workers:    %d\n", workers)
		fmt.Printf("  batch_size: %d\n", batchSize)
		fmt.Printf("  accounts:   %d\n", accounts)
		fmt.Printf("  duration:   %s\n", duration)
		fmt.Println()
	}

	client, err := billing.New(seeds)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect failed: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	setupMetrics(ctx, client, metricCount)

	// Warmup
	if !jsonOut {
		fmt.Print("  warmup...")
	}
	warmCtx, warmCancel := context.WithTimeout(ctx, 5*time.Second)
	runWorkers(warmCtx, client, 4, batchSize, accounts, mode)
	warmCancel()
	if !jsonOut {
		fmt.Println(" done")
	}

	// Actual run
	ctx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()

	var totalEvents atomic.Int64
	var totalErrors atomic.Int64
	start := time.Now()

	// Collect time-series samples for JSON output
	type sample struct {
		ElapsedSec float64 `json:"elapsed_sec"`
		EventsPerS int64   `json:"events_per_sec"`
	}
	var samples []sample
	var samplesMu sync.Mutex

	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rng := rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64()))
			for {
				select {
				case <-ctx.Done():
					return
				default:
				}
				batch := makeBatch(rng, batchSize, accounts, mode)
				_, err := client.Ingest(ctx, batch)
				if err != nil {
					if ctx.Err() != nil {
						return
					}
					totalErrors.Add(1)
					continue
				}
				totalEvents.Add(int64(len(batch)))
			}
		}()
	}

	// Progress ticker
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				elapsed := time.Since(start).Seconds()
				evts := totalEvents.Load()
				eps := int64(float64(evts) / elapsed)
				samplesMu.Lock()
				samples = append(samples, sample{ElapsedSec: elapsed, EventsPerS: eps})
				samplesMu.Unlock()
				if !jsonOut {
					fmt.Printf("  ... %.0fs: %s events, %s events/sec\n",
						elapsed, fmtInt(evts), fmtInt(eps))
				}
			}
		}
	}()

	wg.Wait()

	elapsed := time.Since(start).Seconds()
	total := totalEvents.Load()
	errors := totalErrors.Load()
	throughput := int64(float64(total) / elapsed)

	if jsonOut {
		out := map[string]any{
			"scenario":     modeName + "-throughput",
			"workers":      workers,
			"batch_size":   batchSize,
			"accounts":     accounts,
			"duration_sec":  elapsed,
			"total_events":  total,
			"events_per_sec": throughput,
			"errors":        errors,
			"samples":       samples,
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(out)
	} else {
		fmt.Println()
		fmt.Printf("  total_events: %s\n", fmtInt(total))
		fmt.Printf("  throughput:   %s events/sec\n", fmtInt(throughput))
		fmt.Printf("  errors:       %d\n", errors)
		fmt.Printf("  elapsed:      %.1fs\n", elapsed)
	}
}

func runWorkers(ctx context.Context, client *billing.Client, workers, batchSize, accounts int, mode billing.DeliveryMode) {
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rng := rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64()))
			for {
				select {
				case <-ctx.Done():
					return
				default:
				}
				batch := makeBatch(rng, batchSize, accounts, mode)
				_, _ = client.Ingest(ctx, batch)
			}
		}()
	}
	wg.Wait()
}

// ---------------- latency scenario ----------------

func runLatency(ctx context.Context, seeds []string, accounts, metricCount int, duration time.Duration) {
	if !jsonOut {
		fmt.Println("benchmark: SYNC latency")
		fmt.Printf("  batch_size: 1 (single event per request)\n")
		fmt.Printf("  duration:   %s\n", duration)
		fmt.Println()
	}

	client, err := billing.New(seeds)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect failed: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	setupMetrics(ctx, client, metricCount)

	ctx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()

	// Single-threaded for clean latency measurement
	rng := rand.New(rand.NewPCG(42, 0))
	var latencies []time.Duration

	for {
		select {
		case <-ctx.Done():
			goto report
		default:
		}

		event := billing.Event{
			AccountID:    uint64(rng.IntN(accounts)),
			MetricCode:   metricCodes[rng.IntN(len(metricCodes))],
			Value:        billing.Scale(1.0),
			Timestamp:    time.Now(),
			DeliveryMode: billing.DeliverySync,
		}

		start := time.Now()
		_, err := client.Ingest(ctx, []billing.Event{event})
		elapsed := time.Since(start)

		if err != nil {
			if ctx.Err() != nil {
				break
			}
			continue
		}
		latencies = append(latencies, elapsed)
	}

report:
	if len(latencies) == 0 {
		if jsonOut {
			fmt.Println(`{"scenario":"sync-latency","samples":0}`)
		} else {
			fmt.Println("  no samples collected")
		}
		return
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	n := len(latencies)
	p50 := latencies[n*50/100]
	p90 := latencies[n*90/100]
	p99 := latencies[n*99/100]
	min := latencies[0]
	max := latencies[n-1]

	var sum time.Duration
	for _, l := range latencies {
		sum += l
	}
	mean := sum / time.Duration(n)

	if jsonOut {
		out := map[string]any{
			"scenario":    "sync-latency",
			"samples":     n,
			"p50_us":      p50.Microseconds(),
			"p90_us":      p90.Microseconds(),
			"p99_us":      p99.Microseconds(),
			"min_us":      min.Microseconds(),
			"max_us":      max.Microseconds(),
			"mean_us":     mean.Microseconds(),
		}
		if n >= 1000 {
			out["p999_us"] = latencies[n*999/1000].Microseconds()
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(out)
	} else {
		fmt.Printf("  samples:  %d\n", n)
		fmt.Printf("  p50:      %s\n", p50)
		fmt.Printf("  p90:      %s\n", p90)
		fmt.Printf("  p99:      %s\n", p99)
		if n >= 1000 {
			fmt.Printf("  p999:     %s\n", latencies[n*999/1000])
		}
		fmt.Printf("  max:      %s\n", max)
		fmt.Printf("  min:      %s\n", min)
		fmt.Printf("  mean:     %s\n", mean)
	}
}

// ---------------- scaling scenario ----------------

func runScaling(ctx context.Context, seeds []string, batchSize, accounts, metricCount int, duration time.Duration) {
	if !jsonOut {
		fmt.Println("benchmark: scaling (throughput vs worker count)")
		fmt.Println()
	}

	client, err := billing.New(seeds)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect failed: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	setupMetrics(ctx, client, metricCount)

	steps := []int{1, 2, 4, 8, 16, 32, 64}
	perStep := duration / time.Duration(len(steps))
	if perStep < 10*time.Second {
		perStep = 10 * time.Second
	}

	type scalingPoint struct {
		Workers    int   `json:"workers"`
		EventsPerS int64 `json:"events_per_sec"`
		PerWorker  int64 `json:"per_worker"`
	}
	var points []scalingPoint

	if !jsonOut {
		fmt.Printf("  %-10s %-15s %-15s\n", "workers", "events/sec", "per_worker")
		fmt.Printf("  %-10s %-15s %-15s\n", "-------", "----------", "----------")
	}

	for _, w := range steps {
		select {
		case <-ctx.Done():
			break
		default:
		}

		stepCtx, stepCancel := context.WithTimeout(ctx, perStep)

		var totalEvents atomic.Int64
		start := time.Now()

		var wg sync.WaitGroup
		for range w {
			wg.Add(1)
			go func() {
				defer wg.Done()
				rng := rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64()))
				for {
					select {
					case <-stepCtx.Done():
						return
					default:
					}
					batch := makeBatch(rng, batchSize, accounts, billing.DeliveryAsync)
					result, err := client.Ingest(stepCtx, batch)
					if err != nil {
						if stepCtx.Err() != nil {
							return
						}
						continue
					}
					totalEvents.Add(int64(result.NStored) + int64(result.NDuplicates))
				}
			}()
		}

		wg.Wait()
		stepCancel()

		elapsed := time.Since(start).Seconds()
		total := totalEvents.Load()
		eps := int64(float64(total) / elapsed)
		perW := eps / int64(w)

		points = append(points, scalingPoint{Workers: w, EventsPerS: eps, PerWorker: perW})

		if !jsonOut {
			fmt.Printf("  %-10d %-15s %-15s\n", w, fmtInt(eps), fmtInt(perW))
		}

		time.Sleep(2 * time.Second) // cooldown
	}

	if jsonOut {
		out := map[string]any{
			"scenario":   "scaling",
			"batch_size": batchSize,
			"accounts":   accounts,
			"steps":      points,
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(out)
	}
}

// ---------------- helpers ----------------

func fmtInt(n int64) string {
	if n < 0 {
		return "-" + fmtInt(-n)
	}
	s := fmt.Sprintf("%d", n)
	if len(s) <= 3 {
		return s
	}
	var result []byte
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			result = append(result, '_')
		}
		result = append(result, byte(c))
	}
	return string(result)
}
