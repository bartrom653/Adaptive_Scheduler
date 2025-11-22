#!/usr/bin/env bash
set -euo pipefail

# ============================
#  CONFIG: ПІДЛАШТУЙ ПІД СЕБЕ
# ============================

# Каталог з твоїм kernel-модулем (де Makefile)
KERNEL_MODULE_DIR="$HOME/Projects/adaptive_sched/kernel_module"

# Тимчасовий файл для IO-навантаження
IO_TEST_FILE="/tmp/adaptive_io_test.bin"

# Команди для реальних програм (ЗМІНИ якщо інші)
BROWSER_CMD="firefox"            # або brave / chromium / google-chrome-stable
IDE_CMD="clion"                  # або pycharm / idea / code
TERMINAL_CMD="kitty"             # або alacritty / konsole / gnome-terminal
TELEGRAM_CMD="telegram-desktop"  # якщо нема — можеш залишити як є, сценарії просто попереджатимуть

# Скільки разів проганяти ВЕСЬ набір сценаріїв
# 1 раунд ≈ 40–60 хв, залежить від того, як активно ти клацаєш
ROUNDS=2

# ============================
#  ДОПОМІЖНІ ФУНКЦІЇ
# ============================

run_if_exists() {
    local cmd="$1"
    shift || true
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$@" &
    else
        echo "[WARN] Command '$cmd' not found, skipping"
    fi
}

kill_if_exists() {
    local pattern="$1"
    pkill -f "$pattern" 2>/dev/null || true
}

# ============================
#  БАЗОВІ СЦЕНАРІЇ
# ============================

scenario_idle_short() {
    echo "[SCENARIO] IDLE_SHORT: 60s повний простій"
    sleep 60
}

scenario_idle_long() {
    echo "[SCENARIO] IDLE_LONG: 180s простій (імітація читання/AFK)"
    sleep 180
}

scenario_browser_browsing() {
    echo "[SCENARIO] BROWSER_BROWSING: браузер, 3 хв ручної активності"
    run_if_exists "$BROWSER_CMD"
    echo "  > Поклікай сайти, YouTube, документацію (3 хв)..."
    sleep 180
    kill_if_exists "$BROWSER_CMD"
}

scenario_ide_open_project() {
    echo "[SCENARIO] IDE_OPEN_PROJECT: відкриття IDE (індексація проєкту, 2 хв)"
    run_if_exists "$IDE_CMD"
    echo "  > Відкрий свій проєкт, дай IDE проіндексувати, трохи попрацюй (2 хв)..."
    sleep 120
    kill_if_exists "$IDE_CMD"
}

scenario_kernel_build() {
    echo "[SCENARIO] KERNEL_BUILD: збірка kernel-модуля (CPU + IO)"
    if [ -d "$KERNEL_MODULE_DIR" ]; then
        pushd "$KERNEL_MODULE_DIR" >/dev/null || true
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" || true
        popd >/dev/null || true
    else
        echo "[WARN] KERNEL_MODULE_DIR не існує: $KERNEL_MODULE_DIR"
    fi
    sleep 30
}

scenario_cpu_stress() {
    echo "[SCENARIO] CPU_STRESS: stress-ng 90s (чисте CPU навантаження)"
    if command -v stress-ng >/dev/null 2>&1; then
        stress-ng --cpu 4 --timeout 90s --metrics-brief || true
    else
        echo "[WARN] stress-ng не встановлений, пропускаю CPU STRESS"
        sleep 90
    fi
}

scenario_io_stress() {
    echo "[SCENARIO] IO_STRESS: послідовний запис ~1ГБ на диск"
    dd if=/dev/zero of="$IO_TEST_FILE" bs=16M count=64 oflag=direct 2>/dev/null || true
    sync || true
    sleep 20
    rm -f "$IO_TEST_FILE" || true
}

scenario_python_mixed() {
    echo "[SCENARIO] PYTHON_MIXED: Python з CPU+RAM+паузи (2 хв)"
    python3 - << 'EOF'
import math
import time
import random

data = [random.random() for _ in range(500_000)]
start = time.time()
while time.time() - start < 120:
    s = 0.0
    for x in data:
        s += math.sqrt(x)
    time.sleep(0.05)
EOF
    sleep 10
}

scenario_terminal_activity() {
    echo "[SCENARIO] TERMINAL_ACTIVITY: термінал + легкі команди (2 хв)"
    run_if_exists "$TERMINAL_CMD"
    echo "  > Відкрий у терміналі кілька вікон/вкладок, зроби git status, ls, htop і т.п. (2 хв)..."
    sleep 120
    kill_if_exists "$TERMINAL_CMD"
}

scenario_telegram_chat() {
    echo "[SCENARIO] TELEGRAM_CHAT: запуск Telegram (фонова активність, 2 хв)"
    if [ -n "${TELEGRAM_CMD:-}" ]; then
        run_if_exists "$TELEGRAM_CMD"
        echo "  > Попиши трохи в Telegram / прочитай чати (2 хв)..."
        sleep 120
        kill_if_exists "$TELEGRAM_CMD"
    else
        echo "[INFO] TELEGRAM_CMD не заданий, пропускаю"
        sleep 60
    fi
}

scenario_browser_video() {
    echo "[SCENARIO] BROWSER_VIDEO: браузер + відео/YouTube (3 хв)"
    run_if_exists "$BROWSER_CMD"
    echo "  > Відкрий відео/стрім у браузері, подивись 3 хв..."
    sleep 180
    kill_if_exists "$BROWSER_CMD"
}

scenario_cooldown_idle() {
    echo "[SCENARIO] COOLDOWN_IDLE: 90s спокою після навантажень"
    sleep 90
}

# ============================
#  ПАРАЛЕЛЬНІ СЦЕНАРІЇ
# ============================

scenario_parallel_browsing_ide() {
    echo "[SCENARIO] PARALLEL_BROWSING_IDE: Browser + IDE (3 хв)"
    run_if_exists "$BROWSER_CMD"
    run_if_exists "$IDE_CMD"
    sleep 10
    echo "  > Паралельно працюй в IDE і браузері (3 хв)..."
    sleep 180
    kill_if_exists "$BROWSER_CMD"
    kill_if_exists "$IDE_CMD"
}

scenario_parallel_cpu_video() {
    echo "[SCENARIO] PARALLEL_CPU_VIDEO: CPU_STRESS + Video in Browser (2 хв)"
    run_if_exists "$BROWSER_CMD"
    sleep 8
    if command -v stress-ng >/dev/null 2>&1; then
        stress-ng --cpu 4 --timeout 120s --metrics-brief || true &
    else
        echo "[WARN] stress-ng не встановлений, пропускаю CPU STRESS частину"
    fi
    echo "  > Відкрий відео на YouTube і дивись 2 хв..."
    sleep 120
    kill_if_exists "$BROWSER_CMD"
}

scenario_parallel_build_telegram() {
    echo "[SCENARIO] PARALLEL_BUILD_TELEGRAM: Kernel build + Telegram + Terminal (2–3 хв)"
    run_if_exists "$TELEGRAM_CMD"
    run_if_exists "$TERMINAL_CMD"
    sleep 5

    if [ -d "$KERNEL_MODULE_DIR" ]; then
        pushd "$KERNEL_MODULE_DIR" >/dev/null || true
        make clean >/dev/null 2>&1 || true
        make -j"$(nproc)" || true &
        popd >/dev/null || true
    else
        echo "[WARN] KERNEL_MODULE_DIR не існує: $KERNEL_MODULE_DIR"
    fi

    echo "  > Поки йде збірка, користуйся Telegram/терміналом (2–3 хв)..."
    sleep 150
    kill_if_exists "$TELEGRAM_CMD"
    kill_if_exists "$TERMINAL_CMD"
}

scenario_parallel_io_python() {
    echo "[SCENARIO] PARALLEL_IO_PYTHON: IO + Python CPU-mix (90s)"
    dd if=/dev/zero of="$IO_TEST_FILE" bs=16M count=64 oflag=direct 2>/dev/null || true &
    python3 - << 'EOF' &
import time, math, random
data = [random.random() for _ in range(200_000)]
start = time.time()
while time.time() - start < 90:
    s = sum(math.sqrt(x) for x in data)
    time.sleep(0.03)
EOF
    sleep 100
    rm -f "$IO_TEST_FILE" || true
}

scenario_parallel_multitask_light() {
    echo "[SCENARIO] PARALLEL_MULTITASK_LIGHT: Browser + Terminal + легке навантаження (2 хв)"
    run_if_exists "$BROWSER_CMD"
    run_if_exists "$TERMINAL_CMD"
    sleep 10

    python3 - << 'EOF'
import time
for _ in range(1000000):
    pass
time.sleep(120)
EOF

    sleep 120
    kill_if_exists "$BROWSER_CMD"
    kill_if_exists "$TERMINAL_CMD"
}

scenario_parallel_full_chaos() {
    echo "[SCENARIO] PARALLEL_FULL_CHAOS: Browser + IDE + Terminal + Telegram (3 хв)"
    run_if_exists "$BROWSER_CMD"
    run_if_exists "$IDE_CMD"
    run_if_exists "$TERMINAL_CMD"
    run_if_exists "$TELEGRAM_CMD"
    echo "  > Повноцінний multitasking (поклацай усе підряд 3 хв)..."
    sleep 180
    kill_if_exists "$BROWSER_CMD"
    kill_if_exists "$IDE_CMD"
    kill_if_exists "$TERMINAL_CMD"
    kill_if_exists "$TELEGRAM_CMD"
}

# ============================
#  ПОСЛІДОВНІСТЬ СЦЕНАРІЇВ
# ============================

SCENARIO_SEQUENCE=(
    "scenario_idle_short"
    "scenario_browser_browsing"
    "scenario_ide_open_project"
    "scenario_kernel_build"
    "scenario_cpu_stress"
    "scenario_io_stress"
    "scenario_python_mixed"
    "scenario_terminal_activity"
    "scenario_telegram_chat"
    "scenario_browser_video"
    "scenario_idle_long"
    "scenario_cooldown_idle"
    "scenario_parallel_browsing_ide"
    "scenario_parallel_cpu_video"
    "scenario_parallel_build_telegram"
    "scenario_parallel_io_python"
    "scenario_parallel_multitask_light"
    "scenario_parallel_full_chaos"
)

# ============================
#  ГОЛОВНИЙ ЦИКЛ
# ============================

echo "[INFO] Старт сценарійного раннера."
echo "[INFO] Раундів повної послідовності: $ROUNDS"
echo "[INFO] Переконайся, що adaptive_daemon.py вже запущено з sudo."
echo "[INFO] Приблизний час одного раунду: ~40–60 хв (залежить від твоєї активності)."

for (( round=1; round<=ROUNDS; round++ )); do
    echo
    echo "======================================"
    echo "          ROUND $round / $ROUNDS"
    echo "======================================"
    for scen in "${SCENARIO_SEQUENCE[@]}"; do
        echo
        echo "---------- RUNNING: $scen ----------"
        date +"[TIME] %F %T"
        $scen
    done

    echo
    echo "[INFO] Кінець раунду $round. Пауза 60s перед наступним раундом..."
    sleep 60
done

echo "[INFO] Усі раунди сценаріїв завершені."
echo "[INFO] За цей час adaptive_daemon мав накопичити великий лог у logs/metrics_log.csv"
