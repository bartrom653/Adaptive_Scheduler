#!/usr/bin/env python3
"""
prepare_dataset.py — cleaning and validation for ML-ready dataset.
"""

import argparse
import sys
from pathlib import Path
import pandas as pd


def warn(msg):
    print(f"[WARN] {msg}")


def parse_args():
    parser = argparse.ArgumentParser(description="Prepare ML dataset")
    parser.add_argument("--input", type=str, default="metrics_log.csv")
    parser.add_argument("--output", type=str, default="metrics_clean.csv")
    return parser.parse_args()


def main():
    args = parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        print(f"[ERROR] File not found: {input_path}")
        sys.exit(1)

    print(f"[INFO] Loading: {input_path}")
    df = pd.read_csv(input_path)
    print("[INFO] Initial shape:", df.shape)

    # -----------------------------------------------------------
    # 1. DROP USELESS COLUMNS
    # -----------------------------------------------------------
    drop_cols = []

    if "timestamp" in df.columns:
        drop_cols.append("timestamp")

    if "target_pid" in df.columns:
        drop_cols.append("target_pid")

    if drop_cols:
        print(f"[INFO] Dropping columns: {drop_cols}")
        df = df.drop(columns=drop_cols)

    # -----------------------------------------------------------
    # 2. HANDLE NON-NUMERIC COLUMNS (fix percent signs, enforce numeric)
    # -----------------------------------------------------------
    for col in df.columns:
        if df[col].dtype == object:
            # якщо значення виглядає як "93.0%"
            df[col] = df[col].astype(str).str.replace("%", "", regex=False)
            # convert to numeric where possible
            df[col] = pd.to_numeric(df[col], errors="ignore")

    # -----------------------------------------------------------
    # 3. DETECT & FILL NaN BEFORE ANY astype()
    # -----------------------------------------------------------
    na_counts = df.isna().sum()
    if na_counts.sum() > 0:
        warn("Missing values detected — filling numeric with median.")
        for col in df.columns:
            if df[col].isna().any():
                if pd.api.types.is_numeric_dtype(df[col]):
                    df[col].fillna(df[col].median(), inplace=True)
                else:
                    df[col].fillna("UNKNOWN", inplace=True)

    # -----------------------------------------------------------
    # 4. boost_level → numeric → int
    # -----------------------------------------------------------
    if "boost_level" not in df.columns:
        print("[ERROR] boost_level not found in dataset!")
        sys.exit(1)

    # convert all possible to numeric
    df["boost_level"] = pd.to_numeric(df["boost_level"], errors="coerce")

    # still NaN? fill with mode or 0
    if df["boost_level"].isna().any():
        warn("boost_level had invalid values — filling with median()")
        df["boost_level"].fillna(df["boost_level"].median(), inplace=True)

    # FINALLY cast
    df["boost_level"] = df["boost_level"].astype(int)

    # -----------------------------------------------------------
    # 5. PSI METRICS WARNINGS
    # -----------------------------------------------------------
    if "psi_cpu_some" in df.columns and df["psi_cpu_some"].max() == 0:
        warn("psi_cpu_some is 0 for all rows — PSI stats unavailable or no pressure")

    if "psi_cpu_full" in df.columns and df["psi_cpu_full"].max() == 0:
        warn("psi_cpu_full is 0 for all rows")

    # -----------------------------------------------------------
    # 6. THREAD COUNT WARN
    # -----------------------------------------------------------
    if "proc_threads" in df.columns:
        thr_mode = df["proc_threads"].mode()[0]
        share_1 = (df["proc_threads"] == 1).mean()
        if share_1 > 0.90:
            warn(f"proc_threads = 1 for {share_1*100:.1f}% rows — target app mostly single-threaded")

    # -----------------------------------------------------------
    # 7. CHECK CLASS BALANCE
    # -----------------------------------------------------------
    print("\n[INFO] boost_level distribution:")
    print(df["boost_level"].value_counts().sort_index())

    class_counts = df["boost_level"].value_counts()
    if class_counts.max() / class_counts.min() > 3:
        warn("Class imbalance detected — may affect ML training")

    # -----------------------------------------------------------
    # 8. SAVE CLEAN DATASET
    # -----------------------------------------------------------
    print(f"\n[INFO] Saving cleaned dataset → {output_path}")
    df.to_csv(output_path, index=False)
    print("[INFO] Done. Final shape:", df.shape)


if __name__ == "__main__":
    main()
