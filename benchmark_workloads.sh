#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Noisy neighbors (CPU + IO) with auto-stop
# ============================================

# How long to run the noise in seconds (default: 180 seconds)
DURATION_SEC="${1:-180}"
echo "[NOISE] Will run noisy neighbors for ${DURATION_SEC} seconds."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_DIR="/tmp/noise_io"
mkdir -p "$IO_DIR"

# Number of CPU and IO background noise jobs
CPU_JOBS=6    # number of CPU stress workers
IO_JOBS=2     # number of IO stress workers

# Trap Ctrl+C and termination signals to kill all child processes
trap 'echo "[NOISE] Stopping..."; kill 0 2>/dev/null || true' INT TERM

# --------------------------------------------
# CPU noise: infinite Python loops
# --------------------------------------------
for ((i=1; i<=CPU_JOBS; i++)); do
  python3 - << 'PYEOF' >/dev/null 2>&1 &
import math, random
while True:
    x = random.random()
    math.sqrt(x)
PYEOF
done

# --------------------------------------------
# IO noise: continuous write/remove loops
# --------------------------------------------
for ((i=1; i<=IO_JOBS; i++)); do
  (
    while true; do
      dd if=/dev/zero of="$IO_DIR/noise_$i.bin" bs=64M count=32 oflag=direct \
        >/dev/null 2>&1 || true
      sync || true
      rm -f "$IO_DIR/noise_$i.bin" || true
    done
  ) &
done

echo "[NOISE] All noise jobs started. Running for ${DURATION_SEC} seconds..."
sleep "${DURATION_SEC}"

echo "[NOISE] Time is up, stopping all noise jobs..."
kill 0 2>/dev/null || true
wait || true

echo "[NOISE] Noisy neighbors stopped."
