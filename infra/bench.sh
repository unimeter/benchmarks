#!/usr/bin/env bash
# Run benchmark scenarios against the cluster.
# Usage: bench.sh [scenario]
#   No argument = run all scenarios.
#   Scenarios: async-throughput, sync-throughput, sync-latency, scaling

source "$(dirname "$0")/config.sh"

DURATION="${DURATION:-30s}"
BENCH_EXTRA_FLAGS="${BENCH_EXTRA_FLAGS:-}"

loadgen_ssh_ip=$(get_public_ip "$LOADGEN")

addrs=""
for name in "${NODES[@]}"; do
    ip=$(get_private_ip "$name")
    [[ -n "$addrs" ]] && addrs+=","
    addrs+="${ip}:${INGEST_PORT}"
done

timestamp=$(date +%Y%m%d-%H%M%S)
results_dir="$INFRA_DIR/../results/${timestamp}"
mkdir -p "$results_dir"

# Collect server specs
log "Collecting server specs"
remote "${NODES[0]}" bash <<'SPECS' > "$results_dir/specs.txt"
echo "=== CPU ==="
lscpu | grep -E "Model name|CPU\(s\)|Thread|Core|Socket|MHz"
echo ""
echo "=== Memory ==="
free -h
echo ""
echo "=== Disk ==="
lsblk -d -o NAME,SIZE,MODEL,ROTA
echo ""
echo "=== Kernel ==="
uname -r
echo ""
echo "=== io_uring ==="
cat /proc/version
SPECS

# Record git hash and config
cat > "$results_dir/meta.txt" <<META
date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)
plan:     $PLAN
region:   $REGION
nodes:    ${#NODES[@]}
duration: $DURATION
addrs:    $addrs
META

ALL_SCENARIOS="async-throughput sync-throughput sync-latency scaling"
scenarios="${1:-$ALL_SCENARIOS}"

for scenario in $scenarios; do
    log "Scenario: $scenario (duration=$DURATION)"
    remote_ip "$loadgen_ssh_ip" \
        "/opt/loadgen/loadgen -addrs '$addrs' -scenario $scenario -duration $DURATION $BENCH_EXTRA_FLAGS -json" \
        | tee "$results_dir/${scenario}.json"
    echo ""
    sleep 5
done

log "Results saved to $results_dir/"
