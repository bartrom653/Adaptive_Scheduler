#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Noisy neighbors (CPU + IO) with auto-stop
# ============================================

DURATION_SEC="${1:-180}"   # скільки секунд шуміти (за замовчуванням 180)
echo "[NOISE] Will run noisy neighbors for ${DURATION_SEC} seconds."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_DIR="/tmp/noise_io"
mkdir -p "$IO_DIR"

CPU_JOBS=6    # кількість CPU-шумів
IO_JOBS=2     # кількість IO-шумів

# Якщо натиснеш Ctrl+C — вбити ВСІ дочірні процеси
trap 'echo "[NOISE] Stopping..."; kill 0 2>/dev/null || true' INT TERM

# CPU noise: нескінченні Python-петлі (але їх приб’є kill 0 або по таймеру)
for ((i=1; i<=CPU_JOBS; i++)); do
  python3 - << 'PYEOF' >/dev/null 2>&1 &
import math, random
while True:
    x = random.random()
    math.sqrt(x)
PYEOF
done

# IO noise: постійні запис/видалення файлів
for ((i=1; i<=IO_JOBS; i++)); do
  (
    while true; do
      dd if=/dev/zero of="'$IO_DIR'/noise_$i.bin" bs=64M count=32 oflag=direct \
        >/dev/null 2>&1 || True
      sync || True
      rm -f "'$IO_DIR'/noise_$i.bin" || True
    done
  ) &
done

echo "[NOISE] All noise jobs started. Running for ${DURATION_SEC} seconds..."
sleep "${DURATION_SEC}"

echo "[NOISE] Time is up, stopping all noise jobs..."
kill 0 2>/dev/null || true
wait || true

echo "[NOISE] Noisy neighbors stopped."
