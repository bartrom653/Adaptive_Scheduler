#!/usr/bin/env python3
import time
import subprocess
from pathlib import Path
from typing import Optional, Tuple

# Paths to kernel module sysfs interface
SYSFS_BASE = Path("/sys/kernel/adaptive_sched")
PATH_CURRENT_LOAD = SYSFS_BASE / "current_load"
PATH_MAX_LOAD = SYSFS_BASE / "max_load"
PATH_BOOST_LEVEL = SYSFS_BASE / "boost_level"
PATH_TARGET_PID = SYSFS_BASE / "target_pid"


def read_int(path: Path) -> Optional[int]:
    """Read integer value from a sysfs/proc file. Returns None on error."""
    try:
        with path.open("r") as f:
            text = f.read().strip()
        return int(text)
    except (FileNotFoundError, ValueError, PermissionError) as e:
        print(f"[WARN] Failed to read int from {path}: {e}")
        return None


def write_int(path: Path, value: int) -> bool:
    """Write integer value to a sysfs file. Returns True on success."""
    try:
        with path.open("w") as f:
            f.write(str(value))
        return True
    except (FileNotFoundError, PermissionError, OSError) as e:
        print(f"[ERROR] Failed to write {value} to {path}: {e}")
        return False


def get_kernel_metrics() -> Tuple[Optional[int], Optional[int]]:
    """Read current_load and max_load from kernel module."""
    avg_load = read_int(PATH_CURRENT_LOAD)
    max_load = read_int(PATH_MAX_LOAD)
    return avg_load, max_load


def pick_target_pid(min_cpu: float = 5.0) -> Optional[int]:
    """
    Pick a target PID based on CPU usage.

    Strategy:
    - Use 'ps' to list processes sorted by CPU usage.
    - Ignore system processes and this daemon itself.
    - Return the first process with CPU >= min_cpu.
    """
    try:
        # -e: all processes, -o: output format, --sort=-pcpu: sort by CPU desc
        result = subprocess.run(
            ["ps", "-eo", "pid,comm,pcpu", "--sort=-pcpu"],
            text=True,
            capture_output=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"[WARN] ps command failed: {e}")
        return None

    lines = result.stdout.strip().splitlines()
    if not lines:
        return None

    header_skipped = False
    for line in lines:
        # Skip header line
        if not header_skipped:
            header_skipped = True
            continue

        parts = line.split(None, 2)  # pid, comm, pcpu
        if len(parts) != 3:
            continue

        pid_str, comm, cpu_str = parts
        try:
            pid = int(pid_str)
            cpu = float(cpu_str.replace(",", "."))
        except ValueError:
            continue

        # Ignore very low CPU usage
        if cpu < min_cpu:
            continue

        # Ignore some known system/daemon processes by name
        blacklist_prefixes = (
            "systemd", "kthreadd", "rcu_", "migration", "idle",
            "adaptive_daemon", "gnome-shell", "Xorg"
        )
        if any(comm.startswith(p) for p in blacklist_prefixes):
            continue

        print(f"[INFO] Selected target pid={pid} (comm={comm}, cpu={cpu:.1f}%)")
        return pid

    return None


def estimate_process_cpu(pid: int) -> Optional[float]:
    """Get CPU usage for a specific PID using ps."""
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "pcpu="],
            text=True,
            capture_output=True,
            check=True,
        )
        text = result.stdout.strip()
        if not text:
            return None
        return float(text.replace(",", "."))
    except subprocess.CalledProcessError:
        # process may have exited
        return None
    except ValueError:
        return None


def decide_boost_level(avg_load: int,
                       max_load: int,
                       proc_cpu: Optional[float]) -> int:
    """
    Very simple rule-based controller.

    This is a placeholder for a future ML model.
    Input features:
      - avg_load: average system CPU load (%)
      - max_load: max per-CPU load (%)
      - proc_cpu: CPU usage of target process (%)
    """
    # Default to no boost if metrics are invalid
    if avg_load is None or max_load is None:
        return 0

    # Strong boost if system or process is heavily loaded
    if max_load >= 90 or (proc_cpu is not None and proc_cpu >= 80):
        return 3
    if avg_load >= 70 or (proc_cpu is not None and proc_cpu >= 60):
        return 2
    if avg_load >= 40 or (proc_cpu is not None and proc_cpu >= 30):
        return 1

    return 0


def main_loop(interval: float = 0.5):
    print("[INFO] Adaptive ML daemon started")
    print(f"[INFO] Using sysfs base: {SYSFS_BASE}")
    last_target_pid: Optional[int] = None
    last_boost_level: Optional[int] = None

    while True:
        # 1) Read kernel metrics
        avg_load, max_load = get_kernel_metrics()

        # 2) Decide or update target PID
        if last_target_pid is None:
            pid = pick_target_pid(min_cpu=5.0)
            if pid is not None:
                if write_int(PATH_TARGET_PID, pid):
                    last_target_pid = pid
                    print(f"[INFO] target_pid set to {pid}")
            else:
                print("[INFO] No suitable target PID found (CPU too low)")
        else:
            # Check if process is still alive
            proc_cpu = estimate_process_cpu(last_target_pid)
            if proc_cpu is None:
                print(f"[INFO] Previous target PID {last_target_pid} is gone, "
                      f"resetting target")
                last_target_pid = None
                proc_cpu = None
            else:
                # 3) Decide boost level based on system and process load
                boost = decide_boost_level(
                    avg_load if avg_load is not None else 0,
                    max_load if max_load is not None else 0,
                    proc_cpu,
                )

                # 4) Apply boost_level if changed
                if last_boost_level is None or boost != last_boost_level:
                    if write_int(PATH_BOOST_LEVEL, boost):
                        last_boost_level = boost
                        print(
                            f"[INFO] boost_level={boost} "
                            f"(avg={avg_load}%, max={max_load}%, "
                            f"proc_cpu={proc_cpu:.1f}%, pid={last_target_pid})"
                        )
                else:
                    # Optional: debug spam minimized
                    print(
                        f"[DEBUG] No change: boost={boost}, "
                        f"avg={avg_load}%, max={max_load}%, "
                        f"proc_cpu={proc_cpu:.1f}%, pid={last_target_pid}"
                    )

        time.sleep(interval)


if __name__ == "__main__":
    try:
        main_loop(interval=0.5)
    except KeyboardInterrupt:
        print("\n[INFO] Daemon stopped by user")
