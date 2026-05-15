import pandas as pd
import numpy as np
import xgboost as xgb
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import classification_report, roc_auc_score
import joblib
import os

def train_meta_model(data_path="C:/Users/NuevoAdmin/AppData/Roaming/MetaQuotes/Terminal/Common/Files/Black_Knight_Telemetry.csv", model_output="ml_engine/meta_model.json", scaler_output="ml_engine/scaler.pkl"):
    if not os.path.exists(data_path):
        print(f"Error: No data found at {data_path}. Asegúrate de copiar el CSV desde la carpeta MQL5/Files.")
        return

    # 1. Load Data
    try:
        df = pd.read_csv(data_path)
    except Exception as e:
        print(f"Error reading CSV: {e}")
        return
    
    if len(df) < 50:
        print(f"Insufficient data for training: {len(df)} samples. Need at least 50.")
        return

    # 2. Features and Target
    features = [
        "strength", "prob", "sig_proj", "health", "valscore", 
        "spread_ratio", "hour_sin", "hour_cos", "day_sin", "day_cos"
    ]
    X = df[features]
    y = df['result'].astype(int)

    # 3. Preprocessing
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    # 4. Split
    X_train, X_test, y_train, y_test = train_test_split(X_scaled, y, test_size=0.2, random_state=42)

    # 5. Train XGBoost
    dtrain = xgb.DMatrix(X_train, label=y_train)
    dtest = xgb.DMatrix(X_test, label=y_test)

    params = {
        'max_depth': 4,
        'eta': 0.1,
        'objective': 'binary:logistic',
        'eval_metric': 'auc',
        'subsample': 0.8,
        'colsample_bytree': 0.8
    }

    print("Training XGBoost Meta-Model...")
    model = xgb.train(
        params,
        dtrain,
        num_boost_round=100,
        evals=[(dtest, "Test")],
        early_stopping_rounds=10,
        verbose_eval=True
    )

    # 6. Evaluation
    y_pred = model.predict(dtest)
    auc = roc_auc_score(y_test, y_pred)
    print(f"\nTraining Complete. ROC-AUC: {auc:.4f}")

    # 7. Save
    model.save_model(model_output)
    joblib.dump(scaler, scaler_output)
    print(f"Model saved to {model_output}")
    print(f"Scaler saved to {scaler_output}")

if __name__ == "__main__":
    # Create ml_engine dir if it doesn't exist
    os.makedirs("ml_engine", exist_ok=True)
    train_meta_model()
