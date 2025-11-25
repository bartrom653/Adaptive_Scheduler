#!/usr/bin/env python3
import pandas as pd
from pathlib import Path

from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report
import joblib


def main():
    data_path = Path("metrics_clean.csv")

    if not data_path.exists():
        raise FileNotFoundError(f"{data_path} not found")

    print(f"[INFO] Loading dataset from {data_path}")
    df = pd.read_csv(data_path)
    print("[INFO] Dataset shape:", df.shape)

    # -----------------------------
    # 1. Divide into X (features) and y (goal)
    # -----------------------------
    if "boost_level" not in df.columns:
        raise ValueError("Column 'boost_level' not found in dataset")

    X = df.drop(columns=["boost_level"])
    y = df["boost_level"]

    # -----------------------------
    # 2. Train / test split
    # -----------------------------
    X_train, X_test, y_train, y_test = train_test_split(
        X,
        y,
        test_size=0.2,        # 20% per test
        random_state=42,      # for reproducibility
        stratify=y            # so that the proportions of the classes are preserved
    )

    print("[INFO] Train size:", X_train.shape[0])
    print("[INFO] Test size:", X_test.shape[0])

    # -----------------------------
    # 3. We create and train RandomForest
    # The parameters are the same as I used in mine
    # -----------------------------
    model = RandomForestClassifier(
        n_estimators=120,
        max_depth=6,
        class_weight="balanced",
        random_state=42,
        n_jobs=-1,  #use all cores
    )

    print("[INFO] Training RandomForest...")
    model.fit(X_train, y_train)

    # -----------------------------
    # 4. Evaluation of the model
    # -----------------------------
    y_pred = model.predict(X_test)

    acc = accuracy_score(y_test, y_pred)
    print(f"\n[RESULT] Accuracy: {acc:.4f}\n")

    print("[RESULT] Classification report:")
    print(classification_report(y_test, y_pred, digits=3))

    # -----------------------------
    # 5. Save the model
    # -----------------------------
    out_path = Path("model.pkl")
    joblib.dump(model, out_path)
    print(f"\n[INFO] Model saved to: {out_path.resolve()}")


if __name__ == "__main__":
    main()
