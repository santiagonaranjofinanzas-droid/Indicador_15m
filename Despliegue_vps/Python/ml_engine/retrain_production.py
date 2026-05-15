"""
Black Knight Aut System — XGBoost Meta-Model Production Retraining
==================================================================
Uses Walk-Forward (Purged K-Fold) to avoid look-ahead bias.
Trains on the FULL dataset after validation to maximise information
for the production model.
"""

import pandas as pd
import numpy as np
import xgboost as xgb
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import classification_report, roc_auc_score, brier_score_loss
import joblib
import os
import sys
import json
from datetime import datetime

# ── Paths ────────────────────────────────────────────────────────────────
DATA_PATH = r"C:\Users\NuevoAdmin\AppData\Roaming\MetaQuotes\Terminal\Common\Files\Black_Knight_Telemetry.csv"
MODEL_OUT = os.path.join(os.path.dirname(__file__), "meta_model.json")
SCALER_OUT = os.path.join(os.path.dirname(__file__), "scaler.pkl")
REPORT_OUT = os.path.join(os.path.dirname(__file__), "training_report.json")

FEATURES = [
    "strength", "prob", "sig_proj", "health", "valscore",
    "spread_ratio", "hour_sin", "hour_cos", "day_sin", "day_cos"
]

XGB_PARAMS = {
    "max_depth": 4,
    "eta": 0.05,
    "objective": "binary:logistic",
    "eval_metric": "auc",
    "subsample": 0.8,
    "colsample_bytree": 0.8,
    "min_child_weight": 5,
    "gamma": 0.1,
    "reg_alpha": 0.1,
    "reg_lambda": 1.0,
    "seed": 42,
}
NUM_ROUNDS = 300
EARLY_STOP = 20
N_FOLDS = 5
PURGE_GAP = 500  # bars to purge between train/test to avoid leakage


def purged_kfold_indices(n, n_folds, purge_gap):
    """Generate Walk-Forward Purged K-Fold indices."""
    fold_size = n // n_folds
    for k in range(1, n_folds):
        train_end = k * fold_size
        test_start = train_end + purge_gap
        test_end = min(test_start + fold_size, n)
        if test_start >= n:
            break
        train_idx = np.arange(0, train_end)
        test_idx = np.arange(test_start, test_end)
        yield train_idx, test_idx


def main():
    print("=" * 70)
    print("  BLACK KNIGHT — XGBoost Production Retraining")
    print("=" * 70)

    # ── 1. Load data ─────────────────────────────────────────────────────
    if not os.path.exists(DATA_PATH):
        print(f"[FATAL] CSV not found: {DATA_PATH}")
        sys.exit(1)

    df = pd.read_csv(DATA_PATH)
    print(f"[INFO] Dataset loaded: {len(df):,} trades")

    # Validate columns
    missing = [c for c in FEATURES + ["result"] if c not in df.columns]
    if missing:
        print(f"[FATAL] Missing columns: {missing}")
        sys.exit(1)

    # Drop any rows with NaN/Inf
    df = df.replace([np.inf, -np.inf], np.nan).dropna(subset=FEATURES + ["result"])
    print(f"[INFO] Valid samples after cleaning: {len(df):,}")

    X = df[FEATURES].values.astype(np.float64)
    y = df["result"].values.astype(int)

    win_rate_base = y.mean() * 100
    print(f"[INFO] Base Win Rate: {win_rate_base:.2f}% ({y.sum():,} wins / {len(y):,} total)")

    # ── 2. Walk-Forward Purged K-Fold Validation ─────────────────────────
    print(f"\n[INFO] Walk-Forward Purged K-Fold (K={N_FOLDS}, purge={PURGE_GAP})...")

    oos_preds = np.full(len(y), np.nan)
    fold_aucs = []

    for fold_i, (train_idx, test_idx) in enumerate(purged_kfold_indices(len(X), N_FOLDS, PURGE_GAP), 1):
        scaler_fold = StandardScaler()
        X_train = scaler_fold.fit_transform(X[train_idx])
        X_test = scaler_fold.transform(X[test_idx])

        dtrain = xgb.DMatrix(X_train, label=y[train_idx])
        dtest = xgb.DMatrix(X_test, label=y[test_idx])

        model_fold = xgb.train(
            XGB_PARAMS, dtrain,
            num_boost_round=NUM_ROUNDS,
            evals=[(dtest, "OOS")],
            early_stopping_rounds=EARLY_STOP,
            verbose_eval=False,
        )

        preds = model_fold.predict(dtest)
        oos_preds[test_idx] = preds

        auc = roc_auc_score(y[test_idx], preds)
        fold_aucs.append(auc)
        print(f"  Fold {fold_i}: AUC = {auc:.4f}  (train={len(train_idx):,}, test={len(test_idx):,})")

    # Aggregate OOS metrics
    valid_mask = ~np.isnan(oos_preds)
    y_oos = y[valid_mask]
    p_oos = oos_preds[valid_mask]

    auc_oos = roc_auc_score(y_oos, p_oos)
    brier_oos = brier_score_loss(y_oos, p_oos)

    print(f"\n  Aggregated OOS AUC:   {auc_oos:.4f}")
    print(f"  Aggregated OOS Brier: {brier_oos:.4f}")
    print(f"  Mean Fold AUC:        {np.mean(fold_aucs):.4f} ± {np.std(fold_aucs):.4f}")

    # ── 3. Threshold Analysis ────────────────────────────────────────────
    print("\n" + "-" * 70)
    print("  THRESHOLD ANALYSIS (OOS)")
    print("-" * 70)
    print(f"  {'Threshold':<12} {'Trades':<10} {'Win Rate':<12} {'PF (R=1.5)':<12} {'Retention':<12}")

    for thresh in [0.50, 0.55, 0.60, 0.65, 0.70]:
        mask_t = p_oos >= thresh
        if mask_t.sum() == 0:
            continue
        wr = y_oos[mask_t].mean()
        n_t = mask_t.sum()
        pf = (wr * 1.5) / max((1 - wr) * 1.0, 1e-10)
        ret_pct = n_t / len(p_oos) * 100
        print(f"  {thresh:<12.2f} {n_t:<10,} {wr*100:<12.2f} {pf:<12.4f} {ret_pct:<12.2f}%")

    # ── 4. Train PRODUCTION model on FULL dataset ────────────────────────
    print("\n" + "=" * 70)
    print("  TRAINING PRODUCTION MODEL (Full Dataset)")
    print("=" * 70)

    scaler_prod = StandardScaler()
    X_scaled = scaler_prod.fit_transform(X)

    dtrain_full = xgb.DMatrix(X_scaled, label=y)

    # Use 80/20 split only for early stopping reference
    split_idx = int(len(X_scaled) * 0.8)
    dtrain_es = xgb.DMatrix(X_scaled[:split_idx], label=y[:split_idx])
    dval_es = xgb.DMatrix(X_scaled[split_idx:], label=y[split_idx:])

    model_prod = xgb.train(
        XGB_PARAMS, dtrain_es,
        num_boost_round=NUM_ROUNDS,
        evals=[(dval_es, "Val")],
        early_stopping_rounds=EARLY_STOP,
        verbose_eval=10,
    )

    best_rounds = model_prod.best_iteration + 1
    print(f"\n[INFO] Best iteration: {best_rounds}")

    # Retrain on FULL data with the optimal number of rounds
    model_final = xgb.train(
        XGB_PARAMS, dtrain_full,
        num_boost_round=best_rounds,
        verbose_eval=False,
    )

    # ── 5. Save artifacts ────────────────────────────────────────────────
    model_final.save_model(MODEL_OUT)
    joblib.dump(scaler_prod, SCALER_OUT)

    report = {
        "trained_at": datetime.now().isoformat(),
        "dataset_size": int(len(df)),
        "base_win_rate": round(win_rate_base, 4),
        "oos_auc": round(auc_oos, 4),
        "oos_brier": round(brier_oos, 4),
        "n_folds": N_FOLDS,
        "purge_gap": PURGE_GAP,
        "best_rounds": best_rounds,
        "xgb_params": XGB_PARAMS,
        "features": FEATURES,
    }
    with open(REPORT_OUT, "w") as f:
        json.dump(report, f, indent=2)

    print(f"\n[OK] Model saved:  {MODEL_OUT}")
    print(f"[OK] Scaler saved: {SCALER_OUT}")
    print(f"[OK] Report saved: {REPORT_OUT}")
    print("=" * 70)
    print("  PRODUCTION MODEL READY FOR DEPLOYMENT")
    print("=" * 70)


if __name__ == "__main__":
    main()
