#!/usr/bin/env bash
set -euo pipefail

# ============================================
# CONFIG: adjust as needed
# ============================================

KERNEL_MODULE_DIR="$HOME/Projects/adaptive_sched/kernel_module"
IO_TEST_FILE="/tmp/adaptive_io_test.bin"

ITER_KERNEL_BUILD=6
ITER_CPU_PYTHON=8
ITER_IO_DD=6
ITER_APP_OPEN_CLOSE=6
ITER_MIXED_PARALLEL=6

APP_START_SLEEP=4
APP_CLOSE_SLEEP=2
SHORT_SLEEP=1

CMD_BROWSER="google-chrome-stable"
CMD_TELEGRAM="Telegram"
CMD_PYCHARM="pycharm"
CMD_CLION="clion"
CMD_EASYEFFECTS="easyeffects"
CMD_VOLUME_CTRL="pavucontrol"
CMD_ONLYOFFICE="onlyoffice-desktopeditors"
CMD_THUNAR="thunar"
CMD_VLC="vlc"
CMD_OBS="obs"

# ============================================
# Helpers
# ============================================

run_if_exists_bg() {
    local cmd="$1"
    shift || true
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$@" >/dev/null 2>&1 &
    else
        echo "[WARN] '$cmd' not found"
    fi
}

kill_if_exists() {
    local pattern="$1"
    pkill -f "$pattern" 2>/dev/null || true

    # Chrome-specific fallback
    if [[ "$pattern" == *"chrome"* ]]; then
        pkill -f "chrome" 2>/dev/null || true
    fi
}

# ============================================
# Scenarios
# ============================================

scenario_kernel_build_loop() {
    echo "[SCENARIO] KERNEL_BUILD_LOOP ($ITER_KERNEL_BUILD)"
    [[ -d "$KERNEL_MODULE_DIR" ]] || { echo "[WARN] Kernel dir missing"; return; }

    for ((i=1; i<=ITER_KERNEL_BUILD; i++)); do
        echo "  [BUILD] $i / $ITER_KERNEL_BUILD"
        pushd "$KERNEL_MODULE_DIR" >/dev/null || return
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" >/dev/null 2>&1 || true
        popd >/dev/null || return
        sleep "$SHORT_SLEEP"
    done
}

scenario_cpu_python_loop() {
    echo "[SCENARIO] CPU_PYTHON_LOOP ($ITER_CPU_PYTHON)"
    for ((i=1; i<=ITER_CPU_PYTHON; i++)); do
        echo "  [PYTHON] $i / $ITER_CPU_PYTHON"
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

scenario_io_dd_loop() {
    echo "[SCENARIO] IO_DD_LOOP ($ITER_IO_DD)"
    for ((i=1; i<=ITER_IO_DD; i++)); do
        echo "  [DD] $i / $ITER_IO_DD"
        dd if=/dev/zero of="$IO_TEST_FILE" bs=16M count=64 oflag=direct >/dev/null 2>&1 || true
        sync || true
        rm -f "$IO_TEST_FILE" || true
        sleep "$SHORT_SLEEP"
    done
}

open_close_app_loop() {
    local cmd="$1"
    local iters="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[WARN] App '$cmd' missing"
        return
    fi

    echo "[SCENARIO] APP_LOOP: $cmd x $iters"

    for ((i=1; i<=iters; i++)); do
        echo "  [$cmd] start ($i/$iters)"
        "$cmd" >/dev/null 2>&1 &
        local pid=$!

        sleep "$APP_START_SLEEP"

        echo "  [$cmd] stop ($i/$iters)"
        kill "$pid" 2>/dev/null || true
        sleep 1

        pkill -f "$cmd" 2>/dev/null || true
        pkill -f "chrome" 2>/dev/null || true

        sleep "$APP_CLOSE_SLEEP"
    done
}

scenario_all_apps_open_close() {
    echo "[SCENARIO] ALL_APPS_OPEN_CLOSE"

    open_close_app_loop "$CMD_BROWSER" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_TELEGRAM" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_PYCHARM" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_CLION" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_EASYEFFECTS" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_VOLUME_CTRL" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_ONLYOFFICE" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_THUNAR" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_VLC" "$ITER_APP_OPEN_CLOSE"
    open_close_app_loop "$CMD_OBS" "$ITER_APP_OPEN_CLOSE"
}

scenario_mixed_parallel_loop() {
    echo "[SCENARIO] MIXED_PARALLEL ($ITER_MIXED_PARALLEL)"
    for ((i=1; i<=ITER_MIXED_PARALLEL; i++)); do
        echo "  [MIXED] start ($i/$ITER_MIXED_PARALLEL)"

        run_if_exists_bg "$CMD_BROWSER"
        run_if_exists_bg "$CMD_TELEGRAM"
        run_if_exists_bg "$CMD_PYCHARM"
        run_if_exists_bg "$CMD_CLION"

        python3 - << 'EOF' >/dev/null 2>&1 &
import math, random
N = 3_000_000
s = 0.0
for _ in range(N):
    s += math.sqrt(random.random())
EOF

        dd if=/dev/zero of="$IO_TEST_FILE" bs=8M count=32 oflag=direct >/dev/null 2>&1 || true &

        sleep 10
        rm -f "$IO_TEST_FILE" || true

        kill_if_exists "$CMD_BROWSER"
        kill_if_exists "$CMD_TELEGRAM"
        kill_if_exists "$CMD_PYCHARM"
        kill_if_exists "$CMD_CLION"

        echo "  [MIXED] done ($i/$ITER_MIXED_PARALLEL)"
        sleep "$SHORT_SLEEP"
    done
}

# ============================================
# Scenario sequence
# ============================================

SCENARIO_SEQUENCE=(
    "scenario_kernel_build_loop"
    "scenario_cpu_python_loop"
    "scenario_io_dd_loop"
    "scenario_all_apps_open_close"
    "scenario_mixed_parallel_loop"
)

echo "[INFO] scenario_runner.sh started."
echo "[INFO] adaptive_daemon.py має бути запущений окремо під sudo."

for scen in "${SCENARIO_SEQUENCE[@]}"; do
    echo
    echo "========== Running: $scen =========="
    "$scen"
done

echo "[INFO] All scenarios complete. Dataset готовий."
