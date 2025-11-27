#!/usr/bin/env python3
import os
import time
import subprocess
from pathlib import Path
from typing import Optional, Tuple, Dict, Any

import pandas as pd
from joblib import load

# ----------------------------
# Mode selection
# ----------------------------
# Possible values: "base", "ml", "hybrid"
MODE = os.environ.get("ADAPTIVE_MODE", "hybrid").lower()

# ----------------------------
# Paths to kernel module sysfs interface
# ----------------------------

SYSFS_BASE = Path("/sys/kernel/adaptive_sched")
PATH_CURRENT_LOAD = SYSFS_BASE / "current_load"
PATH_MAX_LOAD = SYSFS_BASE / "max_load"
PATH_BOOST_LEVEL = SYSFS_BASE / "boost_level"
PATH_TARGET_PID = SYSFS_BASE / "target_pid"

# ----------------------------
# Paths to /proc and pressure information
# ----------------------------

PROC_STAT = Path("/proc/stat")
PROC_MEMINFO = Path("/proc/meminfo")
PROC_LOADAVG = Path("/proc/loadavg")
PROC_PSI_CPU = Path("/proc/pressure/cpu")

# ----------------------------
# Paths for ML model
# ----------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
MODEL_PATH = SCRIPT_DIR / "logs" / "model.pkl"

# ----------------------------
# Generic helpers
# ----------------------------

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


# ----------------------------
# Kernel metrics (from our module)
# ----------------------------

def get_kernel_metrics() -> Tuple[Optional[int], Optional[int]]:
    """Read current_load and max_load from kernel module."""
    avg_load = read_int(PATH_CURRENT_LOAD)
    max_load = read_int(PATH_MAX_LOAD)
    return avg_load, max_load


# ----------------------------
# System-level features from /proc
# ----------------------------

def parse_meminfo() -> Dict[str, Any]:
    """Return memory usage features: mem_used_pct."""
    total = None
    available = None
    try:
        with PROC_MEMINFO.open("r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1])  # kB
                elif line.startswith("MemAvailable:"):
                    available = int(line.split()[1])  # kB
                if total is not None and available is not None:
                    break
    except FileNotFoundError:
        return {}

    if total is None or available is None or total == 0:
        return {}

    used_pct = (1.0 - (available / total)) * 100.0
    return {"mem_used_pct": used_pct}


def parse_proc_stat() -> Dict[str, Any]:
    """Return procs_running and procs_blocked from /proc/stat."""
    features: Dict[str, Any] = {}
    try:
        with PROC_STAT.open("r") as f:
            for line in f:
                if line.startswith("procs_running"):
                    parts = line.split()
                    if len(parts) >= 2:
                        features["procs_running"] = int(parts[1])
                elif line.startswith("procs_blocked"):
                    parts = line.split()
                    if len(parts) >= 2:
                        features["procs_blocked"] = int(parts[1])
                if "procs_running" in features and "procs_blocked" in features:
                    break
    except FileNotFoundError:
        pass
    return features


def parse_loadavg() -> Dict[str, Any]:
    """Return loadavg1, loadavg5, loadavg15 from /proc/loadavg."""
    try:
        with PROC_LOADAVG.open("r") as f:
            parts = f.read().strip().split()
        if len(parts) >= 3:
            return {
                "loadavg1": float(parts[0]),
                "loadavg5": float(parts[1]),
                "loadavg15": float(parts[2]),
            }
    except (FileNotFoundError, ValueError):
        pass
    return {}


def parse_cpu_psi() -> Dict[str, Any]:
    """
    Parse CPU pressure from /proc/pressure/cpu.

    We take avg10 for "some" and "full" if available:
      psi_cpu_some, psi_cpu_full
    """
    features: Dict[str, Any] = {}
    try:
        with PROC_PSI_CPU.open("r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("some "):
                    parts = line.split()
                    for p in parts:
                        if p.startswith("avg10="):
                            features["psi_cpu_some"] = float(
                                p.split("=", 1)[1].replace(",", ".")
                            )
                elif line.startswith("full "):
                    for p in line.split():
                        if p.startswith("avg10="):
                            features["psi_cpu_full"] = float(
                                p.split("=", 1)[1].replace(",", ".")
                            )
    except FileNotFoundError:
        pass
    return features


def get_system_features() -> Dict[str, Any]:
    """Collect all system-level features into one dict."""
    features: Dict[str, Any] = {}
    features.update(parse_meminfo())
    features.update(parse_proc_stat())
    features.update(parse_loadavg())
    features.update(parse_cpu_psi())
    return features


# ----------------------------
# Process-level features
# ----------------------------

def pick_target_pid(min_cpu: float = 5.0) -> Optional[int]:
    """
    Pick a target PID based on CPU usage.

    Strategy:
    - Use 'ps' to list processes sorted by CPU usage.
    - Ignore system processes and this daemon itself.
    - Return the first process with CPU >= min_cpu.
    """
    try:
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
        if not header_skipped:
            header_skipped = True
            continue

        parts = line.split(None, 3)  # pid, comm, pcpu
        if len(parts) < 3:
            continue

        pid_str, comm, cpu_str = parts[:3]
        try:
            pid = int(pid_str)
            cpu = float(cpu_str.replace(",", "."))
        except ValueError:
            continue

        if cpu < min_cpu:
            continue

        blacklist_prefixes = (
            "systemd", "kthreadd", "rcu_", "migration", "idle",
            "adaptive_daemon", "adaptive_controller", "gnome-shell", "Xorg"
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
        return None
    except ValueError:
        return None


def parse_proc_status(pid: int) -> Dict[str, Any]:
    """Parse /proc/<pid>/status for memory and threads."""
    status_path = Path(f"/proc/{pid}/status")
    features: Dict[str, Any] = {}
    try:
        with status_path.open("r") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        features["proc_rss_kb"] = int(parts[1])
                elif line.startswith("VmSize:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        features["proc_vms_kb"] = int(parts[1])
                elif line.startswith("Threads:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        features["proc_threads"] = int(parts[1])
    except FileNotFoundError:
        pass
    return features


def parse_proc_io(pid: int) -> Dict[str, Any]:
    """Parse /proc/<pid>/io for IO bytes."""
    io_path = Path(f"/proc/{pid}/io")
    features: Dict[str, Any] = {}
    try:
        with io_path.open("r") as f:
            for line in f:
                if line.startswith("read_bytes:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        features["proc_read_bytes"] = int(parts[1])
                elif line.startswith("write_bytes:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        features["proc_write_bytes"] = int(parts[1])
    except FileNotFoundError:
        pass
    return features


def get_process_features(pid: int) -> Dict[str, Any]:
    """Collect per-process features."""
    features: Dict[str, Any] = {}
    features.update(parse_proc_status(pid))
    features.update(parse_proc_io(pid))
    return features


# ----------------------------
# Rule-based decision logic
# ----------------------------

def decide_boost_level(avg_load: int,
                       max_load: int,
                       proc_cpu: Optional[float],
                       features: Dict[str, Any]) -> int:
    """
    Rule-based controller using system + process features.
    This is the same base logic as in adaptive_daemon (for compatibility).
    """
    if avg_load is None or max_load is None:
        return 0

    mem_used = features.get("mem_used_pct", 0.0)
    procs_running = features.get("procs_running", 0)

    if max_load >= 90 or \
       (proc_cpu is not None and proc_cpu >= 80) or \
       (mem_used >= 90 and procs_running >= 8):
        return 3

    if avg_load >= 70 or \
       (proc_cpu is not None and proc_cpu >= 60) or \
       (mem_used >= 80 and procs_running >= 6):
        return 2

    if avg_load >= 40 or \
       (proc_cpu is not None and proc_cpu >= 30) or \
       (mem_used >= 70 and procs_running >= 4):
        return 1

    return 0


# ----------------------------
# ML model loading and prediction
# ----------------------------

ML_MODEL = None
if MODE in ("ml", "hybrid"):
    if MODEL_PATH.exists():
        print(f"[INFO] Loading ML model from {MODEL_PATH} ...")
        ML_MODEL = load(MODEL_PATH)
        print("[INFO] Model loaded!")
    else:
        print(f"[WARN] MODE={MODE}, but model file not found at {MODEL_PATH}")
        MODE = "base"
        print("[WARN] Falling back to MODE=base")


def predict_boost_ml(features: Dict[str, Any]) -> int:
    """Predict boost using trained ML model."""
    if ML_MODEL is None:
        return 0

    # Use exactly the features the model was trained on
    row = {name: features.get(name, 0) for name in ML_MODEL.feature_names_in_}
    df = pd.DataFrame([row])
    boost = int(ML_MODEL.predict(df)[0])
    return boost


def combine_hybrid(ml_boost: int, rule_boost: int) -> int:
    """
    Hybrid combination:
    - If ML and rules are close (difference <= 1), trust ML.
    - If ML strongly disagrees, keep rule-based decision as a safety net.
    """
    if abs(ml_boost - rule_boost) <= 1:
        return ml_boost
    return rule_boost


# ----------------------------
# Main control loop
# ----------------------------

def main_loop(interval: float = 0.5):
    print("[INFO] Adaptive controller started")
    print(f"[INFO] Mode: {MODE}")
    print(f"[INFO] Using sysfs base: {SYSFS_BASE}")

    last_target_pid: Optional[int] = None
    last_boost_level: Optional[int] = None
    hold_start: Optional[float] = None
    low_cpu_counter: int = 0

    HOLD_TIME_SEC = 10.0        # minimum time to keep the same PID
    LOW_CPU_THRESHOLD = 2.0     # below 2% we consider the process "sleepy"
    LOW_CPU_COUNT_TRIGGER = 4   # number of consecutive low-CPU cycles

    while True:
        avg_load, max_load = get_kernel_metrics()
        sys_features = get_system_features()

        # 1) Choose or validate target PID
        if last_target_pid is None:
            pid = pick_target_pid(min_cpu=5.0)
            if pid is not None:
                if write_int(PATH_TARGET_PID, pid):
                    last_target_pid = pid
                    hold_start = time.time()
                    low_cpu_counter = 0
                    print(f"[INFO] target_pid set to {pid}")
            else:
                print("[INFO] No suitable target PID found (CPU too low)")
                time.sleep(interval)
                continue

        proc_cpu = estimate_process_cpu(last_target_pid)
        if proc_cpu is None:
            print(f"[INFO] Previous target PID {last_target_pid} is gone, resetting")
            last_target_pid = None
            write_int(PATH_BOOST_LEVEL, 0)
            last_boost_level = 0
            hold_start = None
            low_cpu_counter = 0
            time.sleep(interval)
            continue

        now = time.time()
        if hold_start is None:
            hold_start = now

        # -------------------------
        # Hybrid auto-switching logic (same as in adaptive_daemon)
        # -------------------------

        # 1) Low CPU detection
        if proc_cpu < LOW_CPU_THRESHOLD:
            low_cpu_counter += 1
        else:
            low_cpu_counter = 0

        low_cpu_triggered = (low_cpu_counter >= LOW_CPU_COUNT_TRIGGER)

        # 2) High competition detection
        high_competition = False
        competing_pid = pick_target_pid(min_cpu=10.0)  # only heavier tasks
        if competing_pid is not None and competing_pid != last_target_pid:
            comp_cpu = estimate_process_cpu(competing_pid)
            if comp_cpu is not None and comp_cpu > proc_cpu + 30.0:
                high_competition = True

        # 3) Time-based condition:
        #    if we hold the process long, but it is weak, we can switch as well
        time_based_switch = (now - hold_start > HOLD_TIME_SEC and proc_cpu < 5.0)

        should_switch = low_cpu_triggered or high_competition or time_based_switch

        if should_switch:
            print(
                f"[INFO] Auto-switching target pid {last_target_pid} "
                f"(proc_cpu={proc_cpu:.1f}%, "
                f"low_cpu={low_cpu_triggered}, high_comp={high_competition}, "
                f"time_based={time_based_switch})"
            )
            last_target_pid = None
            write_int(PATH_BOOST_LEVEL, 0)
            last_boost_level = 0
            hold_start = None
            low_cpu_counter = 0
            time.sleep(interval)
            continue

        # -------------------------
        # Collect process features
        # -------------------------

        proc_features = get_process_features(last_target_pid)

        # Merge all features into a single dict
        all_features: Dict[str, Any] = {
            "avg_load": avg_load if avg_load is not None else 0,
            "max_load": max_load if max_load is not None else 0,
            "proc_cpu": proc_cpu,
            "target_pid": last_target_pid,
        }
        all_features.update(sys_features)
        all_features.update(proc_features)

        # -------------------------
        # Decide boost level (base / ml / hybrid)
        # -------------------------
        if MODE == "ml":
            boost = predict_boost_ml(all_features)
        elif MODE == "hybrid":
            rule_boost = decide_boost_level(
                all_features["avg_load"],
                all_features["max_load"],
                proc_cpu,
                all_features,
            )
            ml_boost = predict_boost_ml(all_features)
            boost = combine_hybrid(ml_boost, rule_boost)
        else:  # MODE == "base"
            boost = decide_boost_level(
                all_features["avg_load"],
                all_features["max_load"],
                proc_cpu,
                all_features,
            )

        # -------------------------
        # Apply boost if changed + verbose terminal output
        # -------------------------
        if last_boost_level is None or boost != last_boost_level:
            if write_int(PATH_BOOST_LEVEL, boost):
                last_boost_level = boost
                print(
                    f"[INFO] boost_level={boost} "
                    f"(mode={MODE}, "
                    f"avg={all_features['avg_load']}%, "
                    f"max={all_features['max_load']}%, "
                    f"proc_cpu={proc_cpu:.1f}%, "
                    f"mem_used={all_features.get('mem_used_pct', 0):.1f}%, "
                    f"procs_running={all_features.get('procs_running', 0)}, "
                    f"pid={last_target_pid})"
                )
        else:
            print(
                f"[DEBUG] No change: boost={boost}, mode={MODE}, "
                f"avg={all_features['avg_load']}%, "
                f"max={all_features['max_load']}%, "
                f"proc_cpu={proc_cpu:.1f}%, "
                f"mem_used={all_features.get('mem_used_pct', 0):.1f}%, "
                f"procs_running={all_features.get('procs_running', 0)}, "
                f"pid={last_target_pid}"
            )

        time.sleep(interval)


if __name__ == "__main__":
    try:
        main_loop(interval=0.5)
    except KeyboardInterrupt:
        print("\n[INFO] Controller stopped by user")