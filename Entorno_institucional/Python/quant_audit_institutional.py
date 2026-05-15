import pandas as pd
import numpy as np
import xgboost as xgb
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import brier_score_loss, log_loss, confusion_matrix, precision_score, recall_score, f1_score
import os

def institutional_audit():
    print("======================================================================")
    print("   AUDITORIA CUANTITATIVA INSTITUCIONAL (ANTI-LEAKAGE & RECALL CHECK)")
    print("======================================================================")

    path = r"C:\Users\NuevoAdmin\AppData\Roaming\MetaQuotes\Terminal\Common\Files\Black_Knight_Telemetry.csv"
    if not os.path.exists(path):
        print("[ERROR] Archivo de telemetría no encontrado.")
        return

    df = pd.read_csv(path)
    print(f"[INFO] Dataset cargado: {len(df)} trades.")

    features = ["strength", "prob", "sig_proj", "health", "valscore", "spread_ratio", "hour_sin", "hour_cos", "day_sin", "day_cos"]
    target = "result"

    n_folds = 6
    fold_size = len(df) // n_folds
    
    # Métricas agregadas
    all_y_true = []
    all_y_prob = []
    all_y_pred = []
    
    # Parámetros financieros
    RR = 1.5
    
    print("\n[INFO] Ejecutando Walk-Forward Purged K-Fold...")
    
    for i in range(1, n_folds):
        split_point = i * fold_size
        
        # Purga de 50 trades
        train_df = df.iloc[:split_point - 50]
        test_df = df.iloc[split_point : split_point + fold_size]
        
        if len(train_df) < 500 or len(test_df) < 100:
            continue
            
        X_train, y_train = train_df[features], train_df[target]
        X_test, y_test = test_df[features], test_df[target]
        
        # Escalamiento ESTRICTO sin Leakage
        scaler = StandardScaler()
        X_train_scaled = scaler.fit_transform(X_train)
        X_test_scaled = scaler.transform(X_test)
        
        dtrain = xgb.DMatrix(X_train_scaled, label=y_train)
        dtest = xgb.DMatrix(X_test_scaled)
        
        params = {
            'max_depth': 4,
            'eta': 0.05,
            'objective': 'binary:logistic',
            'eval_metric': 'auc',
            'subsample': 0.7,
            'colsample_bytree': 0.7
        }
        
        model = xgb.train(params, dtrain, num_boost_round=60)
        
        preds_prob = model.predict(dtest)
        preds_bin = (preds_prob >= 0.50).astype(int)
        
        all_y_true.extend(y_test.values)
        all_y_prob.extend(preds_prob)
        all_y_pred.extend(preds_bin)

    all_y_true = np.array(all_y_true)
    all_y_prob = np.array(all_y_prob)
    all_y_pred = np.array(all_y_pred)

    print("\n" + "-"*70)
    print("   1. CALIBRACION PROBABILISTICA Y CLASIFICACION (OOS Agregado)")
    print("-" * 70)
    
    # Brier Score & Log-Loss
    brier = brier_score_loss(all_y_true, all_y_prob)
    lloss = log_loss(all_y_true, all_y_prob)
    
    print(f" Brier Score: {brier:.4f} (Menor es mejor. Rango 0-1)")
    print(f" Log-Loss:    {lloss:.4f}")
    
    print("\n" + "-"*70)
    print("   2. EL COLAPSO DEL RECALL (MATRIZ DE CONFUSION)")
    print("-" * 70)
    
    cm = confusion_matrix(all_y_true, all_y_pred)
    tn, fp, fn, tp = cm.ravel()
    
    precision = precision_score(all_y_true, all_y_pred, zero_division=0)
    recall = recall_score(all_y_true, all_y_pred, zero_division=0)
    f1 = f1_score(all_y_true, all_y_pred, zero_division=0)
    
    total_trades_base = len(all_y_true)
    filtered_trades = tp + fp
    retention_rate = filtered_trades / total_trades_base
    
    print(f" Total Trades Base Evaluados: {total_trades_base}")
    print(f" Trades Permitidos por XGB:   {filtered_trades} (Retencion: {retention_rate*100:.2f}%)")
    print(f" Trades Bloqueados por XGB:   {tn + fn} (Filtro: {(1-retention_rate)*100:.2f}%)")
    print(f"\n Matriz de Confusion:")
    print(f"   TN (Falsos Pos. Evitados): {tn:<5} | FP (Errores Permitidos):   {fp:<5}")
    print(f"   FN (Aciertos Bloqueados):  {fn:<5} | TP (Aciertos Permitidos):  {tp:<5}")
    
    print(f"\n Métrica 'Win Rate' (Precision): {precision*100:.2f}%")
    print(f" Métrica 'Sensibilidad' (Recall): {recall*100:.2f}%")
    print(f" F1-Score (Equilibrio P/R):       {f1:.4f}")
    
    print("\n" + "-"*70)
    print("   3. LA PARADOJA DE RENTABILIDAD (FINANCIAL METRICS OOS)")
    print("-" * 70)
    
    base_wins = np.sum(all_y_true == 1)
    base_losses = np.sum(all_y_true == 0)
    
    base_gross_profit = base_wins * RR
    base_gross_loss = base_losses * 1.0
    base_profit_factor = base_gross_profit / base_gross_loss if base_gross_loss > 0 else 0
    base_ev = (base_gross_profit - base_gross_loss) / total_trades_base
    
    xgb_gross_profit = tp * RR
    xgb_gross_loss = fp * 1.0
    xgb_profit_factor = xgb_gross_profit / xgb_gross_loss if xgb_gross_loss > 0 else 0
    xgb_ev = (xgb_gross_profit - xgb_gross_loss) / filtered_trades if filtered_trades > 0 else 0
    
    print(" COMPARATIVA BASE vs XGBOOST (Asumiendo R/R = 1.5)")
    print(f" {'Metrica':<20} | {'Base System':<15} | {'XGBoost Filtered':<15}")
    print(f" {'-'*20}-+-{'-'*15}-+-{'-'*15}")
    print(f" {'Total Trades':<20} | {total_trades_base:<15} | {filtered_trades:<15}")
    print(f" {'Win Rate':<20} | {(base_wins/total_trades_base)*100:>14.2f}% | {precision*100:>14.2f}%")
    print(f" {'Profit Factor':<20} | {base_profit_factor:>15.4f} | {xgb_profit_factor:>15.4f}")
    print(f" {'Expected Value (R)':<20} | {base_ev:>15.4f} | {xgb_ev:>15.4f}")
    
    net_profit_base = base_gross_profit - base_gross_loss
    net_profit_xgb = xgb_gross_profit - xgb_gross_loss
    
    print(f"\n Rentabilidad Neta Acumulada (En Multiplos de 'R'):")
    print(f" Base System: {net_profit_base:+.2f} R")
    print(f" XGBoost:     {net_profit_xgb:+.2f} R")
    
    print("\n" + "="*70)
    if net_profit_xgb > net_profit_base and xgb_profit_factor > 1.0:
        print(" VEREDICTO INSTITUCIONAL: APROBADO")
        print(" El modelo no solo mejora la precision, sino que aumenta el Profit Factor")
        print(" y el beneficio neto absoluto. El Recall esta justificado.")
    else:
        print(" VEREDICTO INSTITUCIONAL: DENEGADO (PROFITABILITY PARADOX)")
        print(" El modelo infla el Win Rate destruyendo el Recall, perdiendo la convexidad")
        print(" de la estrategia. Se requiere optimizar el umbral probabilístico.")
    print("="*70)

if __name__ == "__main__":
    institutional_audit()
