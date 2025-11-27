#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Benchmark workloads (NO artificial sleeps)
# ============================================

# This script runs a fixed set of CPU / IO / build workloads
# and prints a summary with per-scenario and total timings.
#
# You can:
#   - load the kernel module before running:
#       sudo insmod adaptive_sched.ko
#   - run adaptive_controller.py in another terminal with:
#       sudo ADAPTIVE_MODE=base   ./adaptive_controller.py
#       sudo ADAPTIVE_MODE=ml     ./adaptive_controller.py
#       sudo ADAPTIVE_MODE=hybrid ./adaptive_controller.py
#
# Then start this benchmark and compare total times between modes.

# ============================================
# Global configuration
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_MODULE_DIR="$SCRIPT_DIR"

IO_TEST_FILE="/tmp/adaptive_bench_io.bin"

# Fixed-work iteration counts (tune if потрібно)
ITER_KERNEL_BUILD=30          # how many times to build the module
ITER_CPU_PYTHON=50         # heavy CPU loops
ITER_IO_DD=30                 # how many IO writes
ITER_MIXED=20                 # mixed CPU+IO+build iterations

TOTAL_RUNS=1                 # full passes over all scenarios

# Detect mode label (for nice output; реальний режим задаєш adaptive_controller'ом)
MODE_LABEL="${ADAPTIVE_MODE:-unknown_mode}"

# ============================================
# Helpers: time measurement & system info
# ============================================

now_sec() {
    date +%s
}

BENCH_START_TS=$(now_sec)
BENCH_START_READABLE=$(date)

CPU_MODEL=$(lscpu | grep -m1 "Model name" | sed 's/Model name:[ ]*//')
CPU_CORES=$(nproc)
MEM_TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')

# Per-scenario timings (seconds)
TIME_KERNEL_BUILD=0
TIME_CPU_PYTHON=0
TIME_IO_DD=0
TIME_MIXED=0

# Counters
TOTAL_KERNEL_BUILDS=0
TOTAL_CPU_LOOPS=0
TOTAL_IO_OPS=0
TOTAL_MIXED_ITERS=0

# ============================================
# Workload scenarios (NO sleeps)
# ============================================

scenario_kernel_build() {
    echo "[SCENARIO] KERNEL_BUILD x${ITER_KERNEL_BUILD}"
    if [[ ! -d "$KERNEL_MODULE_DIR" ]]; then
        echo "[WARN] KERNEL_MODULE_DIR not found: $KERNEL_MODULE_DIR"
        return
    fi

    local start end
    start=$(now_sec)

    for ((i=1; i<=ITER_KERNEL_BUILD; i++)); do
        echo "  [BUILD] Iteration $i / $ITER_KERNEL_BUILD"
        pushd "$KERNEL_MODULE_DIR" >/dev/null || return
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        popd >/dev/null || return
    done

    end=$(now_sec)
    local dt=$((end - start))
    TIME_KERNEL_BUILD=$((TIME_KERNEL_BUILD + dt))
    TOTAL_KERNEL_BUILDS=$((TOTAL_KERNEL_BUILDS + ITER_KERNEL_BUILD))

    echo "  [BUILD] Done in ${dt} s"
}

scenario_cpu_python() {
    echo "[SCENARIO] CPU_PYTHON x${ITER_CPU_PYTHON}"

    local start end
    start=$(now_sec)

    for ((i=1; i<=ITER_CPU_PYTHON; i++)); do
        echo "  [CPU] Iteration $i / $ITER_CPU_PYTHON"
        python3 - << 'EOF' >/dev/null 2>&1
import math, random

# Heavy CPU workload: fixed number of floating-point operations
N = 40_000_000
s = 0.0
for _ in range(N):
    x = random.random()
    s += math.sqrt(x)
EOF
    done

    end=$(now_sec)
    local dt=$((end - start))
    TIME_CPU_PYTHON=$((TIME_CPU_PYTHON + dt))
    TOTAL_CPU_LOOPS=$((TOTAL_CPU_LOOPS + ITER_CPU_PYTHON))

    echo "  [CPU] Done in ${dt} s"
}

scenario_io_dd() {
    echo "[SCENARIO] IO_DD x${ITER_IO_DD}"

    local start end
    start=$(now_sec)

    for ((i=1; i<=ITER_IO_DD; i++)); do
        echo "  [IO] Iteration $i / $ITER_IO_DD"
        # ~4 GiB per iteration: 64 * 64MiB
        dd if=/dev/zero of="$IO_TEST_FILE" bs=64M count=64 oflag=direct \
            >/dev/null 2>&1 || true
        sync || true
        rm -f "$IO_TEST_FILE" || true
    done

    end=$(now_sec)
    local dt=$((end - start))
    TIME_IO_DD=$((TIME_IO_DD + dt))
    TOTAL_IO_OPS=$((TOTAL_IO_OPS + ITER_IO_DD))

    echo "  [IO] Done in ${dt} s"
}

scenario_mixed() {
    echo "[SCENARIO] MIXED (CPU+IO+BUILD) x${ITER_MIXED}"

    if [[ ! -d "$KERNEL_MODULE_DIR" ]]; then
        echo "[WARN] KERNEL_MODULE_DIR not found: $KERNEL_MODULE_DIR"
        return
    fi

    local start end
    start=$(now_sec)

    for ((i=1; i<=ITER_MIXED; i++)); do
        echo "  [MIXED] Iteration $i / $ITER_MIXED"

        # CPU-heavy in background
        python3 - << 'EOF' >/dev/null 2>&1 &
import math, random
N = 35_000_000
s = 0.0
for _ in range(N):
    x = random.random()
    s += math.sqrt(x)
EOF
        local py_pid=$!

        # IO-heavy in background
        dd if=/dev/zero of="$IO_TEST_FILE" bs=64M count=48 oflag=direct \
            >/dev/null 2>&1 || true &
        local dd_pid=$!

        # TWO kernel builds in foreground
        pushd "$KERNEL_MODULE_DIR" >/dev/null || return
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        popd >/dev/null || return

        rm -f "$IO_TEST_FILE" || true

        # Wait for background jobs
        wait "$py_pid" 2>/dev/null || true
        wait "$dd_pid" 2>/dev/null || true
    done

    end=$(now_sec)
    local dt=$((end - start))
    TIME_MIXED=$((TIME_MIXED + dt))
    TOTAL_MIXED_ITERS=$((TOTAL_MIXED_ITERS + ITER_MIXED))

    echo "  [MIXED] Done in ${dt} s"
}

# ============================================
# Scenario sequence
# ============================================

SCENARIO_SEQUENCE=(
    "scenario_kernel_build"
    "scenario_cpu_python"
    "scenario_io_dd"
    "scenario_mixed"
)

# ============================================
# Main loop
# ============================================

echo "===================================================="
echo "[INFO] benchmark_workloads.sh started"
echo "[INFO] Mode label (for your reference): $MODE_LABEL"
echo "[INFO] TOTAL_RUNS = $TOTAL_RUNS"
echo "CPU    : ${CPU_MODEL:-unknown}"
echo "Cores  : ${CPU_CORES:-unknown}"
echo "Memory : ${MEM_TOTAL_MB:-unknown} MB"
echo "===================================================="

for ((run=1; run<=TOTAL_RUNS; run++)); do
    echo
    echo "================= BENCH RUN $run / $TOTAL_RUNS ================="

    for scen in "${SCENARIO_SEQUENCE[@]}"; do
        echo
        echo "----- Running: $scen -----"
        "$scen"
    done
done

BENCH_END_TS=$(now_sec)
BENCH_END_READABLE=$(date)
BENCH_ELAPSED=$((BENCH_END_TS - BENCH_START_TS))

# ============================================
# Summary
# ============================================

echo
echo "======================================================"
echo "                 ✅ BENCHMARK SUMMARY"
echo "======================================================"
echo "Mode label     : $MODE_LABEL"
echo "Start time     : $BENCH_START_READABLE"
echo "End time       : $BENCH_END_READABLE"
echo "Total duration : ${BENCH_ELAPSED} s"
echo
echo "CPU model      : ${CPU_MODEL:-unknown}"
echo "CPU cores      : ${CPU_CORES:-unknown}"
echo "Total RAM      : ${MEM_TOTAL_MB:-unknown} MB"
echo
echo "Workload stats (per all runs):"
echo "  Kernel builds total   : $TOTAL_KERNEL_BUILDS"
echo "    Time on builds      : ${TIME_KERNEL_BUILD} s"
echo
echo "  CPU Python loops      : $TOTAL_CPU_LOOPS"
echo "    Time on CPU loops   : ${TIME_CPU_PYTHON} s"
echo
echo "  IO dd operations      : $TOTAL_IO_OPS"
echo "    Time on IO          : ${TIME_IO_DD} s"
echo
echo "  Mixed iterations      : $TOTAL_MIXED_ITERS"
echo "    Time on MIXED       : ${TIME_MIXED} s"
echo "======================================================"
echo "[INFO] Benchmark finished."
