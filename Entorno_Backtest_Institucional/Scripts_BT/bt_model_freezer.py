import pandas as pd
import numpy as np
import xgboost as xgb
from sklearn.preprocessing import StandardScaler
import argparse
import os
import joblib

def parse_args():
    parser = argparse.ArgumentParser(description="Trainer & Freezer for T_B Validation")
    parser.add_argument("--data", type=str, required=True, help="Ruta al archivo CSV de telemetria generado en Ventana T_B")
    return parser.parse_args()

def run_freezer():
    args = parse_args()
    path = args.data
    
    if not os.path.exists(path):
        print(f"[ERROR] Archivo no encontrado: {path}")
        return

    df = pd.read_csv(path)
    print("======================================================================")
    print("   XGBOOST MODEL FREEZER (FASE 2 - VENTANA T_B)")
    print("======================================================================")
    print(f"[INFO] Dataset T_B cargado: {len(df)} trades.")

    features = ["strength", "prob", "sig_proj", "health", "valscore", "spread_ratio", "hour_sin", "hour_cos", "day_sin", "day_cos"]
    target = "result"
    
    available_features = [f for f in features if f in df.columns]
    if len(available_features) < len(features):
        print("[ERROR] Faltan features en el archivo CSV de telemetria.")
        return

    X = df[features]
    y = df[target]

    print("[INFO] Entrenando modelo estocastico sobre la totalidad de T_B...")
    
    # Escalamiento Maestro (El Scaler también se congela)
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)
    
    dtrain = xgb.DMatrix(X_scaled, label=y)
    
    params = {
        'max_depth': 4,
        'eta': 0.05,
        'objective': 'binary:logistic',
        'eval_metric': 'auc',
        'subsample': 0.7,
        'colsample_bytree': 0.7
    }
    
    # Entrenar el modelo final (Phi_Star)
    model = xgb.train(params, dtrain, num_boost_round=75)
    
    # Rutas de exportación
    export_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Modelos_Congelados")
    if not os.path.exists(export_dir):
        os.makedirs(export_dir)
        
    model_path = os.path.join(export_dir, "meta_model_frozen.json")
    scaler_path = os.path.join(export_dir, "scaler_frozen.pkl")
    
    model.save_model(model_path)
    joblib.dump(scaler, scaler_path)
    
    print("\n" + "="*70)
    print(" [SUCCESS] MODELO Y ESCALADOR CONGELADOS CORRECTAMENTE (Phi*)")
    print("="*70)
    print(f" Modelo:   {model_path}")
    print(f" Scaler:   {scaler_path}")
    print("\n -> Instrucción: Configura 'quant_server.py' para cargar estos archivos")
    print("    y ejecuta la Prueba del Ácido en MT5 sobre la Ventana T_C.")

if __name__ == "__main__":
    run_freezer()
