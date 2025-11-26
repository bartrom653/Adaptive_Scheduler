#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Global configuration (HEAVY PROFILE)
# ============================================

# Directory containing the kernel module source and Makefile
KERNEL_MODULE_DIR="$HOME/Projects/adaptive_sched"

# Temporary file for IO stress
IO_TEST_FILE="/tmp/adaptive_io_heavy_test.bin"

# Number of iterations for different heavy scenarios (per one full run)
# These values define how many times each fixed-work scenario is executed.
ITER_KERNEL_BUILD_HEAVY=10      # kernel builds per run
ITER_CPU_PYTHON_HEAVY=10        # heavy CPU Python runs per run
ITER_IO_DD_HEAVY=8              # heavy IO writes per run
ITER_MIXED_HEAVY=6              # mixed heavy iterations per run

# Total number of full runs over all scenarios
# Increase this value to collect more ML training data.
TOTAL_RUNS=1

# Small pauses between iterations (do NOT change the amount of work,
# they only give the system a short breather).
SHORT_SLEEP=2
RUN_PAUSE=5

# ============================================
# Helper functions
# ============================================

# Run command if exists, otherwise print warning
run_if_exists() {
    local cmd="$1"
    shift || true
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$@"
    else
        echo "[WARN] Command '$cmd' not found, skipping"
    fi
}

# ============================================
# Heavy workload scenarios (fixed work, no timeouts)
# ============================================

# 1) Heavy kernel module build loop (CPU + IO)
#    Each iteration runs a full clean + build with -j$(nproc).
scenario_kernel_build_heavy() {
    echo "[SCENARIO] KERNEL_BUILD_HEAVY (iterations: $ITER_KERNEL_BUILD_HEAVY)"

    if [[ ! -d "$KERNEL_MODULE_DIR" ]]; then
        echo "[WARN] KERNEL_MODULE_DIR not found: $KERNEL_MODULE_DIR"
        return
    fi

    for ((i=1; i<=ITER_KERNEL_BUILD_HEAVY; i++)); do
        echo "  [BUILD] Heavy iteration $i / $ITER_KERNEL_BUILD_HEAVY"
        pushd "$KERNEL_MODULE_DIR" >/dev/null || return
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        popd >/dev/null || return
        sleep "$SHORT_SLEEP"
    done
}

# 2) Heavy CPU-bound Python loop (fixed number of operations)
#    Larger N means more CPU work per iteration.
scenario_cpu_python_heavy() {
    echo "[SCENARIO] CPU_PYTHON_HEAVY (iterations: $ITER_CPU_PYTHON_HEAVY)"

    for ((i=1; i<=ITER_CPU_PYTHON_HEAVY; i++)); do
        echo "  [PYTHON HEAVY] Iteration $i / $ITER_CPU_PYTHON_HEAVY"
        python3 - << 'EOF' >/dev/null 2>&1
import math, random

# Fixed heavy workload: N iterations of floating-point operations.
N = 40_000_000
s = 0.0
for _ in range(N):
    x = random.random()
    s += math.sqrt(x)
EOF
        sleep "$SHORT_SLEEP"
    done
}

# 3) Heavy IO workload using dd (fixed amount of data)
#    Each iteration writes a fixed number of bytes to disk.
scenario_io_dd_heavy() {
    echo "[SCENARIO] IO_DD_HEAVY (iterations: $ITER_IO_DD_HEAVY)"

    for ((i=1; i<=ITER_IO_DD_HEAVY; i++)); do
        echo "  [DD HEAVY] Iteration $i / $ITER_IO_DD_HEAVY"
        # Approx 4GB per iteration: 64 blocks * 64MB
        dd if=/dev/zero of="$IO_TEST_FILE" bs=64M count=64 oflag=direct \
            >/dev/null 2>&1 || true
        sync || true
        rm -f "$IO_TEST_FILE" || true
        sleep "$SHORT_SLEEP"
    done
}

# 4) Mixed heavy scenario: run CPU + IO + two kernel builds in parallel
#    Total duration depends only on how fast the system completes all work.
scenario_mixed_heavy() {
    echo "[SCENARIO] MIXED_HEAVY (iterations: $ITER_MIXED_HEAVY)"

    if [[ ! -d "$KERNEL_MODULE_DIR" ]]; then
        echo "[WARN] KERNEL_MODULE_DIR not found: $KERNEL_MODULE_DIR"
        return
    fi

    for ((i=1; i<=ITER_MIXED_HEAVY; i++)); do
        echo "  [MIXED HEAVY] Start iteration $i / $ITER_MIXED_HEAVY"

        # Start heavy CPU-bound Python in background
        python3 - << 'EOF' >/dev/null 2>&1 &
import math, random
N = 35_000_000
s = 0.0
for _ in range(N):
    x = random.random()
    s += math.sqrt(x)
EOF
        py_pid=$!

        # Start heavy IO workload in background (fixed size)
        dd if=/dev/zero of="$IO_TEST_FILE" bs=64M count=48 oflag=direct \
            >/dev/null 2>&1 || true &
        dd_pid=$!

        # In parallel, run TWO full kernel module builds in foreground
        pushd "$KERNEL_MODULE_DIR" >/dev/null || return
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        popd >/dev/null || return

        # Remove IO file (if still present)
        rm -f "$IO_TEST_FILE" || true

        # Wait for background CPU and IO tasks to finish
        wait "$py_pid" 2>/dev/null || true
        wait "$dd_pid" 2>/dev/null || true

        echo "  [MIXED HEAVY] Done iteration $i / $ITER_MIXED_HEAVY"
        sleep "$SHORT_SLEEP"
    done
}

# ============================================
# Scenario sequence
# ============================================

SCENARIO_SEQUENCE=(
    "scenario_kernel_build_heavy"
    "scenario_cpu_python_heavy"
    "scenario_io_dd_heavy"
    "scenario_mixed_heavy"
)

# ============================================
# Main loop over TOTAL_RUNS
# ============================================

echo "[INFO] heavy_scenario_runner.sh started (HEAVY profile)."
echo "[INFO] TOTAL_RUNS = $TOTAL_RUNS (full passes over all heavy scenarios)."
echo "[INFO] IMPORTANT: adaptive_daemon.py should be running under sudo in another terminal."

for ((run=1; run<=TOTAL_RUNS; run++)); do
    echo
    echo "=============================================="
    echo "      HEAVY SCENARIO RUN $run / $TOTAL_RUNS"
    echo "=============================================="

    for scen in "${SCENARIO_SEQUENCE[@]}"; do
        echo
        echo "---------- Running heavy scenario: $scen ----------"
        "$scen"
    done

    echo
    echo "[INFO] Finished heavy run $run / $TOTAL_RUNS."
    sleep "$RUN_PAUSE"
done

echo
echo "[INFO] All heavy runs completed. metrics_log.csv should now contain a large, high-load fixed-work dataset for ML training and performance comparison."
