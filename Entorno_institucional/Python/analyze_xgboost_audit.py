"""
╔══════════════════════════════════════════════════════════════╗
║  Black Knight Aut System — XGBoost Scientific Audit Analyzer  ║
║  Analiza Precision, Recall, y Edge Improvement del filtro IA  ║
╚══════════════════════════════════════════════════════════════╝

USO:
    python analyze_xgboost_audit.py

ARCHIVOS DE ENTRADA (generados por el EA durante backtesting):
    1. XGBoost_Scientific_Audit.csv  → Registro de TODOS los intentos de señal
    2. Black_Knight_Telemetry.csv    → Resultado real (Win/Loss) de trades ejecutados

RUTA DE LOS ARCHIVOS:
    MT5 guarda los CSVs en:
    C:\\Users\\<USER>\\AppData\\Roaming\\MetaQuotes\\Terminal\\<ID>\\Tester\\Agent-127.0.0.1-3000\\MQL5\\Files\\
    o en:
    C:\\Users\\<USER>\\AppData\\Roaming\\MetaQuotes\\Terminal\\<ID>\\MQL5\\Files\\
"""

import pandas as pd
import numpy as np
import os
import xgboost as xgb
import joblib
from pathlib import Path
from sklearn.model_selection import KFold
from sklearn.preprocessing import StandardScaler
import sys

# --- CONFIGURACIÓN DE RUTAS ---
TERMINAL_ID = "6FBEE76C719DC78AB2AE839B5A0C7442"
BASE_PATH = Path(f"C:/Users/NuevoAdmin/AppData/Roaming/MetaQuotes/Terminal/{TERMINAL_ID}")

# Buscar los CSVs en multiples ubicaciones posibles
SEARCH_PATHS = [
    Path(f"C:/Users/NuevoAdmin/AppData/Roaming/MetaQuotes/Terminal/Common/Files"),
]

def find_csv(filename):
    """Busca un CSV en las rutas posibles de MT5."""
    for path in SEARCH_PATHS:
        full = path / filename
        if full.exists():
            print(f"  [OK] Encontrado: {full}")
            return full
    print(f"  [FAIL] No encontrado: {filename}")
    print(f"     Buscado en: {[str(p) for p in SEARCH_PATHS]}")
    return None


def analyze_audit():
    """Análisis principal del CSV de auditoría científica."""
    print("\n" + "="*70)
    print("   BLACK KNIGHT — ANÁLISIS CIENTÍFICO DEL XGBoost ORACLE")
    print("="*70)
    
    # 1. Cargar Audit CSV
    print("\n[INFO] Buscando archivos...")
    audit_path = find_csv("XGBoost_Scientific_Audit.csv")
    telemetry_path = find_csv("Black_Knight_Telemetry.csv")
    
    if audit_path is None:
        print("\n[WARNING] El archivo XGBoost_Scientific_Audit.csv no existe todavia.")
        print("   Debes correr un backtest con el EA actualizado primero.")
        print("   Pasos:")
        print("   1. Compila el EA en MetaEditor (F7)")
        print("   2. Corre un backtest (Sept 2025 - Feb 2026)")
        print("   3. Ejecuta este script de nuevo")
        return
    
    df_audit = pd.read_csv(audit_path)
    print(f"\n[DATA] Audit CSV: {len(df_audit)} senales registradas")
    
    # 2. Estadísticas Generales
    print("\n" + "-"*70)
    print("   1. RESUMEN GENERAL DE SEÑALES")
    print("-"*70)
    
    total = len(df_audit)
    allowed = df_audit[df_audit['xg_decision'] == 'ALLOWED']
    blocked = df_audit[df_audit['xg_decision'] == 'BLOCKED']
    exec_blocked = df_audit[df_audit['xg_decision'] == 'EXEC_BLOCKED']
    
    print(f"   Total senales generadas:     {total}")
    print(f"   [OK] ALLOWED (ejecutadas):      {len(allowed)} ({len(allowed)/total*100:.1f}%)")
    print(f"   [BLOCK] BLOCKED por XGBoost:       {len(blocked)} ({len(blocked)/total*100:.1f}%)")
    print(f"   [PAUSE] EXEC_BLOCKED (meta-exec): {len(exec_blocked)} ({len(exec_blocked)/total*100:.1f}%)")
    
    # 3. Distribución por dirección
    print(f"\n   Senales BUY:  {len(df_audit[df_audit['direction'] == 'BUY'])}")
    print(f"   Senales SELL: {len(df_audit[df_audit['direction'] == 'SELL'])}")
    
    # 4. Si tenemos telemetría de resultados, hacer análisis de precisión
    if telemetry_path is not None:
        df_tel = pd.read_csv(telemetry_path)
        print(f"\n[DATA] Telemetry CSV: {len(df_tel)} trades con resultado")
        
        wins = df_tel[df_tel['result'] == 1.0]
        losses = df_tel[df_tel['result'] == 0.0]
        
        print("\n" + "-"*70)
        print("   2. PRECISIÓN DEL SISTEMA (Trades Ejecutados)")
        print("-"*70)
        
        total_trades = len(df_tel)
        win_rate = len(wins) / total_trades * 100 if total_trades > 0 else 0
        
        print(f"   Total trades cerrados:  {total_trades}")
        print(f"   [WIN] Ganadores:            {len(wins)} ({win_rate:.1f}%)")
        print(f"   [LOSS] Perdedores:           {len(losses)} ({100-win_rate:.1f}%)")
        
        # 5. Análisis de features de ganadores vs perdedores
        print("\n" + "-"*70)
        print("   3. PERFIL DE TRADES GANADORES vs PERDEDORES")
        print("-"*70)
        
        features = ['strength', 'prob', 'sig_proj', 'health', 'valscore', 'spread_ratio']
        available_features = [f for f in features if f in df_tel.columns]
        
        if available_features:
            print("   Feature               Ganadores   Perdedores      Delta")
            print(f"   {'-'*18} {'-'*12} {'-'*12} {'-'*10}")
            for feat in available_features:
                win_mean = wins[feat].mean()
                loss_mean = losses[feat].mean()
                delta = win_mean - loss_mean
                indicator = "[+]" if delta > 0 else "[-]"
                print(f"   {feat:<18} {win_mean:>12.4f} {loss_mean:>12.4f} {delta:>+10.4f} {indicator}")
    
    # 6. Análisis del XGBoost (si hay datos de confianza)
    if 'xg_confidence' in df_audit.columns:
        xg_data = df_audit[df_audit['xg_confidence'] != 1.0]  # Excluir default (1.0 = no XGBoost)
        if len(xg_data) > 0:
            print("\n" + "-"*70)
            print("   4. RENDIMIENTO DEL XGBOOST ORACLE")
            print("-"*70)
            
            print(f"   Confianza promedio (ALLOWED):  {xg_data[xg_data['xg_decision']=='ALLOWED']['xg_confidence'].mean():.4f}")
            print(f"   Confianza promedio (BLOCKED):  {xg_data[xg_data['xg_decision']=='BLOCKED']['xg_confidence'].mean():.4f}")
            print(f"   Threshold configurado:         {0.55}")
        else:
            print("\n   [INFO] XGBoost no estaba activo (confianza = 1.0 para todas las senales)")
            print("      Esto es normal si InpUseXGBoostGate = false")
    
    # 7. Análisis temporal
    if 'time' in df_audit.columns:
        print("\n" + "-"*70)
        print("   5. DISTRIBUCIÓN TEMPORAL")
        print("-"*70)
        
        df_audit['time_parsed'] = pd.to_datetime(df_audit['time'], errors='coerce')
        if df_audit['time_parsed'].notna().any():
            df_audit['hour'] = df_audit['time_parsed'].dt.hour
            hourly = df_audit.groupby('hour').size()
            peak_hour = hourly.idxmax()
            print(f"   Hora con mas senales: {peak_hour}:00 ({hourly[peak_hour]} senales)")
            print(f"   Hora con menos senales: {hourly.idxmin()}:00 ({hourly.min()} senales)")
    
    # 8. Simulación: ¿Qué pasaría si activamos XGBoost?
    print("\n----------------------------------------------------------------------")
    print("   6. SIMULACION: IMPACTO ESTIMADO DEL XGBoost (OFFLINE)")
    print("----------------------------------------------------------------------")
    
    features = ["strength", "prob", "sig_proj", "health", "valscore", "spread_ratio", "hour_sin", "hour_cos", "day_sin", "day_cos"]
    available_features = [f for f in features if f in df_tel.columns]
    
    if len(available_features) == 10:
        try:
            X = df_tel[features]
            y = df_tel['result']
            
            # K-Fold Cross Validation (Out-of-sample)
            kf = KFold(n_splits=5, shuffle=False) # Secuencial para respetar el tiempo
            oos_preds = np.zeros(len(df_tel))
            
            for train_idx, test_idx in kf.split(X):
                X_tr, y_tr = X.iloc[train_idx], y.iloc[train_idx]
                X_te = X.iloc[test_idx]
                
                scaler = StandardScaler()
                X_tr_sc = scaler.fit_transform(X_tr)
                X_te_sc = scaler.transform(X_te)
                
                dtr = xgb.DMatrix(X_tr_sc, label=y_tr)
                dte = xgb.DMatrix(X_te_sc)
                
                params = {'max_depth': 4, 'eta': 0.1, 'objective': 'binary:logistic', 'eval_metric': 'auc', 'subsample': 0.8}
                cv_model = xgb.train(params, dtr, num_boost_round=50)
                oos_preds[test_idx] = cv_model.predict(dte)
            
            df_tel['xg_oos_pred'] = oos_preds
            
            thresholds = [0.45, 0.48, 0.50, 0.52]
            print(f"   Simulacion Out-Of-Sample (5-Fold CV) del filtro XGBoost:")
            print(f"   {'Umbral':<10} | {'Trades':<8} | {'Win Rate':<10} | {'Mejora WR':<10}")
            print(f"   {'-'*10} | {'-'*8} | {'-'*10} | {'-'*10}")
            
            base_wr = (df_tel['result'] == 1).mean()
            
            for t in thresholds:
                df_filtered = df_tel[df_tel['xg_oos_pred'] >= t]
                if len(df_filtered) > 0:
                    wr = (df_filtered['result'] == 1).mean()
                    print(f"   >= {t:<8.2f} | {len(df_filtered):<8} | {wr*100:>8.2f}% | {(wr - base_wr)*100:>+8.2f}%")
                else:
                    print(f"   >= {t:<8.2f} | {0:<8} | {'N/A':>9} | {'N/A':>9}")
                    
        except Exception as e:
            print(f"   [ERROR] Fallo al simular CV: {e}")
    else:
        print("   [ERROR] Faltan columnas para validacion CV.")
    
    # 9. Veredicto Final
    print("\n" + "="*70)
    print("   VEREDICTO FINAL")
    print("="*70)
    
    if telemetry_path is not None and total_trades > 0:
        if win_rate >= 55:
            print("   [SUCCESS] El sistema base es RENTABLE. El XGBoost puede amplificar la ventaja.")
        elif win_rate >= 45:
            print("   [WARNING] El sistema es BREAKEVEN. El XGBoost es NECESARIO para ser rentable.")
        else:
            print("   [FAIL] El sistema base PIERDE. Requiere recalibracion de parametros del indicador.")
    
    print("\n" + "="*70)


if __name__ == "__main__":
    analyze_audit()
