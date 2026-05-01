INFRA := infra

.PHONY: help all up down provision setup start stop restart bench status plans ssh clean \
        bench-async bench-sync bench-latency bench-scaling \
        bench-async-single bench-sync-single bench-single bench-all

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Lifecycle:"
	@echo "  all              Provision → setup → start → bench (full run)"
	@echo "  up               Provision → setup → start (no bench)"
	@echo "  clean            Stop cluster + destroy servers (stops billing!)"
	@echo ""
	@echo "Servers:"
	@echo "  provision        Create bare-metal instances"
	@echo "  down             Destroy all instances"
	@echo "  status           Show server IPs and status"
	@echo "  plans            List available server plans"
	@echo ""
	@echo "Setup:"
	@echo "  setup            Install Zig/Go, build binaries on all servers"
	@echo "  setup-nodes      Build Unimeter on cluster nodes only"
	@echo "  setup-loadgen    Build Go loadgen only"
	@echo ""
	@echo "Cluster:"
	@echo "  start            Start cluster"
	@echo "  stop             Stop cluster"
	@echo "  restart          Restart cluster"
	@echo "  ssh              SSH into loadgen (or: make ssh TARGET=bench-node-0)"
	@echo ""
	@echo "Benchmarks (batch=500):"
	@echo "  bench            All 4 scenarios"
	@echo "  bench-async      Async throughput"
	@echo "  bench-sync       Sync throughput"
	@echo "  bench-latency    Sync latency (p50/p99/p999)"
	@echo "  bench-scaling    Throughput vs worker count"
	@echo ""
	@echo "Benchmarks (batch=1):"
	@echo "  bench-async-single  Async throughput, single event"
	@echo "  bench-sync-single   Sync throughput, single event"
	@echo "  bench-single        Both single-event scenarios"
	@echo ""
	@echo "Combined:"
	@echo "  bench-all        All scenarios (batched + single-event)"

all: provision setup start bench

# --- Servers ---

provision:
	$(INFRA)/provision.sh up

down:
	$(INFRA)/provision.sh down

status:
	$(INFRA)/provision.sh status

plans:
	$(INFRA)/provision.sh plans

# --- Setup ---

setup:
	$(INFRA)/setup.sh all

setup-nodes:
	$(INFRA)/setup.sh nodes

setup-loadgen:
	$(INFRA)/setup.sh loadgen

# --- Cluster ---

start:
	$(INFRA)/cluster.sh start

stop:
	$(INFRA)/cluster.sh stop

restart:
	$(INFRA)/cluster.sh restart

ssh:
	$(INFRA)/cluster.sh ssh $(TARGET)

# --- Benchmarks (batched, batch=500) ---

bench:
	$(INFRA)/bench.sh

bench-async:
	$(INFRA)/bench.sh async-throughput

bench-sync:
	$(INFRA)/bench.sh sync-throughput

bench-latency:
	$(INFRA)/bench.sh sync-latency

bench-scaling:
	$(INFRA)/bench.sh scaling

# --- Benchmarks (single event, batch=1) ---

bench-async-single:
	BENCH_EXTRA_FLAGS="-batch 1" $(INFRA)/bench.sh async-throughput

bench-sync-single:
	BENCH_EXTRA_FLAGS="-batch 1" $(INFRA)/bench.sh sync-throughput

bench-single: bench-async-single bench-sync-single

# --- Combined ---

bench-all: bench bench-single

# --- Shortcuts ---

up: provision setup start

clean: stop down
