import numpy as np
import scipy.stats as stats

class PBOMetrics:
    """
    Evaluador de Probability of Overfitting (Métricas de DePrado).
    Aplica el Deflated Sharpe Ratio para castigar el Ratio de Sharpe 
    por la cantidad de combinaciones probadas y no-normalidad extrema.
    """
    def __init__(self, trials_count=50, risk_free_rate=0.0, rho=0.5):
        # Número de variantes de hiperparámetros exploradas durante I+D
        self.trials_count = max(trials_count, 1)
        self.risk_free = risk_free_rate
        self.rho = rho # Correlación empírica/teórica media entre sendas de P&L de la Fase de I+D

    def evaluate_dsr(self, strategy_returns):
        """
        Calcula el Sharpe Observado y su Probabilidad de Sobreajuste (PBO).
        """
        st_rets = np.array(strategy_returns)
        if len(st_rets) < 100 or np.std(st_rets) == 0:
            return 0.0, 1.0 # PBO 100% (inválido)
            
        mu = np.mean(st_rets)
        sigma = np.std(st_rets)
        
        # 1. Sharpe Ratio Anualizado (Asumiendo 15m barras, ~24000/año)
        anualization_factor = np.sqrt(24000)
        sharpe_obs = ((mu - self.risk_free) / sigma) * anualization_factor
        
        # 2. Skewness / Kurtosis Empírica
        skew = stats.skew(st_rets)
        kurt = stats.kurtosis(st_rets, fisher=False)
        
        # 3. Varianza del Ratio de Sharpe (Desviación Típica de la Distribución del Sharpe)
        n = len(st_rets)
        var_sr = (1 - skew * sharpe_obs + ((kurt - 1)/4.0) * (sharpe_obs**2)) / n
        
        # 4. Máximo Sharpe Esperado (SR_0) bajo la hipótesis nula de Múltiples Exámenes
        # DSR puro asume independencia. Bailey & De Prado (2014) ajustan la variable para
        # ensayos correlacionados (I+D cuantitativo típicamente produce rho > 0),
        # lo que previene un falso rechazo inflando SR_0 excesivamente (Error Tipo II).
        sr_expected = np.sqrt(1 - self.rho) * np.sqrt(2 * np.log(max(self.trials_count, 2)))
        
        # 5. Z-Score del Deflated Sharpe
        z = (sharpe_obs - sr_expected) / np.sqrt(max(var_sr, 1e-8))
        
        # P-Value = Normal CDF inverso. Queremos que el Sharpe superé drásticamente SR_0
        # PBO = Probabilidad de que este resultado provenga del ruido (H0)
        pbo = 1.0 - stats.norm.cdf(z)
        
        return float(sharpe_obs), float(pbo)
