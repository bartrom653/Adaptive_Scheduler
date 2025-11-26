#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Global configuration
# ============================================

# Directory with your kernel module (must contain Makefile)
KERNEL_MODULE_DIR="$HOME/Projects/adaptive_sched/"

# Temporary file for IO stress
IO_TEST_FILE="/tmp/adaptive_io_test.bin"

# Number of iterations for different scenarios (per one full run)
ITER_KERNEL_BUILD=6          # how many times to build the kernel module
ITER_CPU_PYTHON=8            # how many times to run CPU-bound Python
ITER_IO_DD=6                 # how many times to write ~1GB to disk
ITER_APP_OPEN_CLOSE=6        # how many open/close cycles per GUI app
ITER_MIXED_PARALLEL=6        # how many mixed parallel iterations

# Number of full runs of the entire SCENARIO_SEQUENCE
# Increase this value to collect a larger ML dataset.
TOTAL_RUNS=1

# Timing parameters
APP_START_SLEEP=4            # time to let a GUI app start
APP_CLOSE_SLEEP=2            # time after closing an app
SHORT_SLEEP=1                # small pause between iterations

# Commands for real applications (adjust if needed)
CMD_BROWSER="google-chrome-stable"
CMD_TELEGRAM="Telegram"
CMD_PYCHARM="pycharm"
CMD_CLION="clion"
CMD_EASYEFFECTS="easyeffects"
CMD_VOLUME_CTRL="pavucontrol"
CMD_ONLYOFFICE="onlyoffice-desktopeditors"
CMD_THUNAR="thunar"
CMD_VLC="vlc"
CMD_OBS="obs"                       # or obs-studio

# ============================================
# Helper functions
# ============================================

# Run command in background if it exists in PATH
run_if_exists_bg() {
    local cmd="$1"
    shift || true
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$@" >/dev/null 2>&1 &
    else
        echo "[WARN] Command '$cmd' not found, skipping"
    fi
}

# Kill processes matching a pattern (with special handling for Chrome)
kill_if_exists() {
    local pattern="$1"
    pkill -f "$pattern" 2>/dev/null || true

    # Special case for Chrome: processes are often named simply "chrome"
    if [[ "$pattern" == *"chrome"* ]]; then
        pkill -f "chrome" 2>/dev/null || true
    fi
}

# ============================================
# Workload scenarios
# ============================================

# 1) Repeated kernel module builds (CPU + some IO)
scenario_kernel_build_loop() {
    echo "[SCENARIO] KERNEL_BUILD_LOOP (iterations: $ITER_KERNEL_BUILD)"

    if [[ ! -d "$KERNEL_MODULE_DIR" ]]; then
        echo "[WARN] KERNEL_MODULE_DIR not found: $KERNEL_MODULE_DIR"
        return
    fi

    for ((i=1; i<=ITER_KERNEL_BUILD; i++)); do
        echo "  [BUILD] Iteration $i / $ITER_KERNEL_BUILD"
        pushd "$KERNEL_MODULE_DIR" >/dev/null || return
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        popd >/dev/null || return
        sleep "$SHORT_SLEEP"
    done
}

# 2) CPU-bound Python workload with fixed amount of work
scenario_cpu_python_loop() {
    echo "[SCENARIO] CPU_PYTHON_LOOP (iterations: $ITER_CPU_PYTHON)"

    for ((i=1; i<=ITER_CPU_PYTHON; i++)); do
        echo "  [PYTHON] Iteration $i / $ITER_CPU_PYTHON"
        python3 - << 'EOF' >/dev/null 2>&1
import math, random

N = 5_000_000
s = 0.0
for _ in range(N):
    x = random.random()
    s += math.sqrt(x)
EOF
        sleep "$SHORT_SLEEP"
    done
}

# 3) IO stress using dd: fixed amount of data per iteration
scenario_io_dd_loop() {
    echo "[SCENARIO] IO_DD_LOOP (iterations: $ITER_IO_DD)"

    for ((i=1; i<=ITER_IO_DD; i++)); do
        echo "  [DD] Iteration $i / $ITER_IO_DD"
        dd if=/dev/zero of="$IO_TEST_FILE" bs=16M count=64 oflag=direct \
            >/dev/null 2>&1 || true
        sync || true
        rm -f "$IO_TEST_FILE" || true
        sleep "$SHORT_SLEEP"
    done
}

# 4) Generic open/close loop for a GUI application
#    - starts app, waits a bit, then kills it by PID and by pattern
open_close_app_loop() {
    local cmd="$1"
    local iters="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[WARN] Application '$cmd' not found, skipping its loop"
        return
    fi

    echo "[SCENARIO] APP_LOOP: $cmd x $iters"

    for ((i=1; i<=iters; i++)); do
        echo "  [$cmd] Start ($i / $iters)"
        "$cmd" >/dev/null 2>&1 &
        local pid=$!

        # Give the application time to start
        sleep "$APP_START_SLEEP"

        echo "  [$cmd] Stop ($i / $iters)"

        # First try to kill the specific PID
        kill "$pid" 2>/dev/null || true
        sleep 1

        # As a fallback, kill by command name/pattern
        pkill -f "$cmd" 2>/dev/null || true
        pkill -f "chrome" 2>/dev/null || true

        sleep "$APP_CLOSE_SLEEP"
    done
}

# 5) Open/close all selected GUI applications in sequence
scenario_all_apps_open_close() {
    echo "[SCENARIO] ALL_APPS_OPEN_CLOSE: each app x $ITER_APP_OPEN_CLOSE"

    open_close_app_loop "$CMD_BROWSER"      "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_TELEGRAM"     "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_PYCHARM"      "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_CLION"        "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_EASYEFFECTS"  "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_VOLUME_CTRL"  "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_ONLYOFFICE"   "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_THUNAR"       "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_VLC"          "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_OBS"          "$ITER_APP_OPEN_CLOSE"
}

# 6) Mixed parallel workload: several GUI apps + CPU + IO in one iteration
scenario_mixed_parallel_loop() {
    echo "[SCENARIO] MIXED_PARALLEL_LOOP (iterations: $ITER_MIXED_PARALLEL)"

    for ((i=1; i<=ITER_MIXED_PARALLEL; i++)); do
        echo "  [MIXED] Start ($i / $ITER_MIXED_PARALLEL)"

        # Start several GUI apps in background (if available)
        run_if_exists_bg "$CMD_BROWSER"
        run_if_exists_bg "$CMD_TELEGRAM"
        run_if_exists_bg "$CMD_PYCHARM"
        run_if_exists_bg "$CMD_CLION"

        # CPU-bound Python in background
        python3 - << 'EOF' >/dev/null 2>&1 &
import math, random
N = 3_000_000
s = 0.0
for _ in range(N):
    s += math.sqrt(random.random())
EOF

        # IO workload in background
        dd if=/dev/zero of="$IO_TEST_FILE" bs=8M count=32 oflag=direct \
            >/dev/null 2>&1 || true &

        # Give everything some time to run; the amount of work is fixed
        sleep 10
        rm -f "$IO_TEST_FILE" || true

        # Close all GUI apps started above
        kill_if_exists "$CMD_BROWSER"
        kill_if_exists "$CMD_TELEGRAM"
        kill_if_exists "$CMD_PYCHARM"
        kill_if_exists "$CMD_CLION"

        echo "  [MIXED] Done ($i / $ITER_MIXED_PARALLEL)"
        sleep "$SHORT_SLEEP"
    done
}

# ============================================
# Scenario sequence definition
# ============================================

SCENARIO_SEQUENCE=(
    "scenario_kernel_build_loop"
    "scenario_cpu_python_loop"
    "scenario_io_dd_loop"
    "scenario_all_apps_open_close"
    "scenario_mixed_parallel_loop"
)

# ============================================
# Main loop
# ============================================

echo "[INFO] scenario_runner.sh started."
echo "[INFO] TOTAL_RUNS = $TOTAL_RUNS (full passes over all scenarios)."
echo "[INFO] IMPORTANT: adaptive_daemon.py must be running under sudo in another terminal."

for ((run=1; run<=TOTAL_RUNS; run++)); do
    echo
    echo "=============================================="
    echo "      SCENARIO RUN $run / $TOTAL_RUNS"
    echo "=============================================="

    for scen in "${SCENARIO_SEQUENCE[@]}"; do
        echo
        echo "---------- Running scenario: $scen ----------"
        "$scen"
    done

    echo
    echo "[INFO] Finished run $run / $TOTAL_RUNS."
    # Optional pause between full runs (can be set to 0 if not needed)
    sleep 5
done

echo
echo "[INFO] All runs completed. metrics_log.csv should now contain a large dataset for ML training."
