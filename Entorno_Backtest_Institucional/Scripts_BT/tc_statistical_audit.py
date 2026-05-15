import pandas as pd
import numpy as np
import scipy.stats as stats
import argparse

def calculate_mintrl(returns, confidence_level=0.95):
    """
    Calcula el Minimum Track Record Length (MinTRL) de Bailey & Lopez de Prado.
    returns: Serie de Pandas con retornos por operación.
    """
    n = len(returns)
    if n < 3:
        return np.inf

    sr_hat = np.mean(returns) / np.std(returns, ddof=1)
    skewness = stats.skew(returns)
    kurtosis = stats.kurtosis(returns, fisher=False) # Pearson's kurtosis

    z_alpha = stats.norm.ppf(confidence_level)
    
    # MinTRL analítico
    term1 = 1 - skewness * sr_hat + ((kurtosis - 1) / 4.0) * (sr_hat ** 2)
    term2 = (z_alpha / sr_hat) ** 2
    mintrl = 1 + term1 * term2

    return mintrl, sr_hat, skewness, kurtosis

def block_bootstrap_sr(returns, n_bootstraps=10000, block_size=5):
    """
    Block Bootstrapping para mantener dependencia temporal fraccional.
    """
    n = len(returns)
    bootstrapped_sr = np.zeros(n_bootstraps)
    ret_array = returns.values

    for i in range(n_bootstraps):
        # Sample blocks with replacement
        indices = np.random.randint(0, n - block_size + 1, size=n // block_size)
        boot_sample = np.concatenate([ret_array[idx:idx+block_size] for idx in indices])
        
        # Calculate SR for boot sample
        if np.std(boot_sample, ddof=1) > 0:
            bootstrapped_sr[i] = np.mean(boot_sample) / np.std(boot_sample, ddof=1)
        else:
            bootstrapped_sr[i] = 0.0

    return bootstrapped_sr

def run_audit():
    parser = argparse.ArgumentParser(description="Statistical Audit for T_C (MinTRL & Bootstrapping)")
    parser.add_argument("--data", type=str, required=True, help="Ruta al reporte de retornos generados en T_C (CSV)")
    args = parser.parse_args()

    df = pd.read_csv(args.data)
    # Suponemos que la columna 'pnl' o 'return' tiene los resultados netos
    target_col = 'pnl' if 'pnl' in df.columns else 'result'
    if target_col not in df.columns:
        print(f"[ERROR] No se encontró la columna de retornos en el CSV. Nombres encontrados: {df.columns}")
        return

    returns = df[target_col].astype(float)
    n_trades = len(returns)

    print("\n" + "="*70)
    print("   EVALUACIÓN ESTADÍSTICA DE LA VENTANA T_C (Hold-Out)")
    print("="*70)
    
    mintrl, sr_hat, skew, kurt = calculate_mintrl(returns)

    print(f"Trades Ejecutados (N): {n_trades}")
    print(f"Sharpe Ratio (SR)  : {sr_hat:.4f}")
    print(f"Skewness           : {skew:.4f}")
    print(f"Kurtosis           : {kurt:.4f}")
    print(f"-> MinTRL Requerido: {mintrl:.2f} trades")

    if n_trades < mintrl:
        print("\n[PELIGRO] N < MinTRL: La muestra carece de poder estadístico (Type II Error Risk).")
        print("          El Sharpe Ratio es ilusorio debido al sesgo y colas pesadas.")
    else:
        print("\n[ÉXITO]   N >= MinTRL: La muestra tiene significancia estadística.")

    print("\nIniciando Block Bootstrapping (10,000 trayectorias)...")
    boot_sr = block_bootstrap_sr(returns)
    conf_interval = np.percentile(boot_sr, [5, 95])
    prob_loss = np.mean(boot_sr <= 0)

    print(f"Intervalo Confianza (90%) Sharpe: [{conf_interval[0]:.4f}, {conf_interval[1]:.4f}]")
    print(f"P(Sharpe <= 0)                  : {prob_loss*100:.2f}%")

    if conf_interval[0] < 0:
        print("\n[PELIGRO] El límite inferior de confianza es negativo. Estrategia no robusta a stress testing.")
    else:
        print("\n[ÉXITO]   El Límite inferior de confianza es positivo. Estrategia robusta.")

if __name__ == "__main__":
    run_audit()
