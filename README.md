# Unimeter Benchmarks

Reproducible bare-metal benchmarks on Cherry Servers (AMD Ryzen 7700X, hourly billing).

## Results

Hardware: **AMD Ryzen 7700X** (8C/16T, 5.6 GHz boost), 64 GB DDR5, 2× Micron 7450 NVMe, kernel 6.8.
3-node cluster + 1 Go load generator on a private VLAN in US-Chicago.

### Throughput (3-node cluster)

| Scenario | batch=500 | batch=1 |
|----------|-----------|---------|
| Async (no fsync) | **4.01M** evt/s | **266K** evt/s |
| Sync (durable) | **1.70M** evt/s | **24.1K** evt/s |

### Sync latency (1 event, durable write, round-trip)

| Percentile | Latency |
|------------|---------|
| p50 | **171 µs** |
| p90 | 198 µs |
| p99 | 224 µs |
| p999 | 250 µs |

### Scaling (async, batch=500, throughput vs worker count)

| Workers | Events/sec |
|---------|-----------|
| 1 | 1,442K |
| 2 | 2,554K |
| 8 | **4,011K** |
| 16 | 4,034K |
| 64 | 3,942K |

Cluster saturates at 8 workers (~4.0M evt/s).

## Architecture

4 bare-metal servers on a private VLAN: 3 Unimeter nodes + 1 Go load generator.

```
                    private VLAN
  ┌──────────┐    ┌──────────┐    ┌──────────┐
  │  node-0  │────│  node-1  │────│  node-2  │
  └──────────┘    └──────────┘    └──────────┘
        │               │               │
        └───────────────┼───────────────┘
                        │
                  ┌──────────┐
                  │ loadgen  │
                  └──────────┘
```

For single-node runs, only `node-0` + `loadgen` are provisioned (`CLUSTER_SIZE=1`).

## Scenarios

### `async-throughput`
Maximum events/sec with async delivery (no fsync, no replication ack before response).
64 workers, batch=500, 30s duration (configurable via `DURATION`).

### `sync-throughput`
Maximum events/sec with sync delivery (fsync + replica ack before response).
64 workers, batch=500, 30s duration.

### `sync-latency`
Round-trip latency percentiles for durable single-event writes.
1 worker, batch=1, 30s duration. Each request = 1 event with fsync.

### `scaling`
Throughput vs worker count (1, 2, 4, 8, 16, 32, 64 workers).
Async delivery, batch=500. Finds the saturation point.

All scenarios use 10,000 unique account IDs spread across partitions and 5 metric codes.

## Quick start

### Prerequisites

- Cherry Servers account with API token
- SSH key uploaded to Cherry Servers (label: `bench`)
- `curl`, `jq` installed locally

```bash
cp .env.example .env
# edit .env with your Cherry Servers credentials
```

### Full run (provision → build → bench → teardown)

```bash
make all        # provision, setup, start, run all benchmarks
make clean      # stop cluster, destroy servers (stops billing!)
```

### Step by step

```bash
# 1. Provision servers (takes 5-15 min for bare-metal deploy)
make provision                    # 3-node cluster (default)
CLUSTER_SIZE=1 make provision     # single-node

# 2. Install Zig, Go, build binaries
make setup

# 3. Start cluster
make start

# 4. Run benchmarks
make bench              # all 4 scenarios
make bench-async        # async throughput only
make bench-sync         # sync throughput only
make bench-latency      # sync latency only
make bench-scaling      # scaling curve

# 5. Run with batch=1 (single-event)
make bench-async-single
make bench-sync-single

# Utilities
make status             # show server IPs
make ssh                # SSH into loadgen
make ssh TARGET=bench-node-0
make restart            # restart cluster without reprovisioning
make stop               # stop cluster (servers still running)
make down               # destroy servers
```

### Results

Results are saved to `results/<timestamp>/` with:
- `meta.txt` — date, region, node count, addresses
- `specs.txt` — CPU, RAM, disk, kernel version
- `<scenario>.json` — raw benchmark output with per-5s samples

## Loadgen flags

The Go load generator (`loadgen/main.go`) accepts:

| Flag | Default | Description |
|------|---------|-------------|
| `-addrs` | `localhost:7001` | Comma-separated node addresses (seeds) |
| `-scenario` | `async-throughput` | Scenario name |
| `-duration` | `30s` | Test duration |
| `-workers` | `NumCPU×4` | Concurrent workers |
| `-batch` | `500` | Events per batch |
| `-accounts` | `10000` | Unique account IDs |
| `-metrics` | `5` | Number of metric codes |
| `-json` | `false` | JSON output |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_SIZE` | `3` | Number of cluster nodes |
| `DURATION` | `30s` | Per-scenario duration |
| `PLAN` | `amd-ryzen-7700x` | Cherry Servers plan slug |
| `REGION` | `US-Chicago` | Datacenter region |
| `UNIMETER_BRANCH` | `main` | Git branch to build on servers |

## Scripts

| File | Purpose |
|------|---------|
| `infra/config.sh` | Shared config, env vars, Cherry API helpers |
| `infra/provision.sh` | Create/destroy bare-metal instances |
| `infra/setup.sh` | Install Zig/Go, build binaries on servers |
| `infra/cluster.sh` | Start/stop/restart Unimeter cluster |
| `infra/bench.sh` | Run benchmark scenarios, collect results |
| `loadgen/main.go` | Go load generator using go-unimeter SDK |

## Cost

Cherry Servers `amd-ryzen-7700x`: ~$0.14/hr per server.
Full 3-node + loadgen run: ~$0.56/hr. A typical bench session (provision + 4 scenarios) takes ~25 min.

**Always `make clean` when done to stop billing.**
