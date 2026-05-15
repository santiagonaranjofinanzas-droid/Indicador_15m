import pandas as pd
import numpy as np
import xgboost as xgb
from sklearn.preprocessing import StandardScaler
import os

def rigorous_validation():
    print("======================================================================")
    print("   VALORACION RIGUROSA (WALK-FORWARD + PURGED EMBARGO)")
    print("======================================================================")

    # Rutas
    path = r"C:\Users\NuevoAdmin\AppData\Roaming\MetaQuotes\Terminal\Common\Files\Black_Knight_Telemetry.csv"
    if not os.path.exists(path):
        print("[ERROR] No se encuentra el archivo de telemetría.")
        return

    df = pd.read_csv(path)
    print(f"[INFO] Cargados {len(df)} trades.")

    features = ["strength", "prob", "sig_proj", "health", "valscore", "spread_ratio", "hour_sin", "hour_cos", "day_sin", "day_cos"]
    target = "result"

    # Walk-Forward Validation
    # Dividiremos la data en 6 bloques (ventanas temporales)
    # Entrenaremos en bloques previos para probar en el bloque siguiente (Out-of-sample real)
    
    n_folds = 6
    fold_size = len(df) // n_folds
    
    results = []
    
    print(f"[INFO] Iniciando Walk-Forward con {n_folds} ventanas temporales...")
    
    for i in range(1, n_folds):
        # Punto de división
        split_point = i * fold_size
        
        # Entrenamiento: bloques anteriores
        # Aplicamos "Purge": eliminamos los últimos 50 trades del entrenamiento 
        # para evitar que indicadores de largo plazo filtren información al test
        train_df = df.iloc[:split_point - 50]
        
        # Test: bloque actual
        test_df = df.iloc[split_point : split_point + fold_size]
        
        if len(train_df) < 500 or len(test_df) < 100:
            continue
            
        X_train, y_train = train_df[features], train_df[target]
        X_test, y_test = test_df[features], test_df[target]
        
        # Escalamiento local (sin look-ahead)
        scaler = StandardScaler()
        X_train_scaled = scaler.fit_transform(X_train)
        X_test_scaled = scaler.transform(X_test)
        
        # Entrenamiento
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
        
        # Predicción OOS
        preds = model.predict(dtest)
        
        # Evaluación del filtro al umbral 0.50
        mask = preds >= 0.50
        oos_trades = len(y_test[mask])
        if oos_trades > 0:
            oos_wr = y_test[mask].mean()
        else:
            oos_wr = 0
            
        base_wr = y_test.mean()
        edge = oos_wr - base_wr
        
        results.append({
            'fold': i,
            'base_wr': base_wr,
            'oos_wr': oos_wr,
            'edge': edge,
            'trades': oos_trades
        })
        
        print(f" Fold {i}: Base WR={base_wr*100:.2f}% | OOS WR={oos_wr*100:.2f}% | Edge={edge*100:+.2f}% | Trades={oos_trades}")

    # Resumen final de consistencia
    print("\n" + "-"*70)
    print("   RESUMEN DE CONSISTENCIA (OUT-OF-SAMPLE)")
    print("-"*70)
    
    if not results:
        print("[ERROR] No hay suficientes datos para validación.")
        return
        
    avg_edge = np.mean([r['edge'] for r in results])
    std_edge = np.std([r['edge'] for r in results])
    
    print(f" Promedio de Mejora (Edge): {avg_edge*100:+.2f}%")
    print(f" Desviación Estándar del Edge: {std_edge*100:.2f}%")
    
    # Coeficiente de Variación (Menor es mejor para consistencia)
    stability = 1 - (std_edge / abs(avg_edge) if avg_edge != 0 else 1)
    
    print(f" Indice de Estabilidad OOS: {stability*100:.2f}%")
    
    print("\n" + "="*70)
    if stability > 0.6 and avg_edge > 0.15:
        print(" VEREDICTO: [FIABLE] El modelo es consistente fuera de muestra.")
    elif avg_edge > 0.10:
        print(" VEREDICTO: [MODERADO] Mejora real, pero con variabilidad.")
    else:
        print(" VEREDICTO: [RIESGOSO] Resultados inconsistentes en Walk-Forward.")
    print("="*70)

if __name__ == "__main__":
    rigorous_validation()
