import numpy as np
import scipy.stats as stats
import warnings

warnings.filterwarnings('ignore', category=RuntimeWarning)

class ExtremeValueTheorySL:
    """
    Teoría de Valores Extremos para Stop Loss Asimétrico.
    Ajusta la Distribución Generalizada de Pareto (GPD) a la cola de caídas,
    proyectando el Conditional Value at Risk (CVaR) al 99% para poner el SL fuera de su alcance.
    """
    def __init__(self, tail_fraction=0.05, confidence_level=0.99, max_history=24000):
        self.history = []
        self.tail_fraction = float(np.clip(tail_fraction, 0.01, 0.25)) # Analiza el 5% de peores rendimientos
        self.confidence_level = float(np.clip(confidence_level, 0.90, 0.999)) # Muro de contención al 99%
        self.max_history = max_history
        self.cvar = 0.015 # SL conservador inicial (1.5%)
        self.last_shape = None
        self.last_scale = None

    def _compute_cvar(self, u, shape, scale):
        alpha = self.confidence_level
        tail_prob = max((1.0 - alpha) / max(self.tail_fraction, 1e-6), 1e-12)

        if abs(shape) > 1e-6:
            var_alpha = u + (scale / shape) * (tail_prob**(-shape) - 1.0)
            # Para shape >= 1 el ES teórico no existe (cola infinita); usamos VaR como bound conservador.
            if shape >= 1.0:
                cvar_alpha = var_alpha
            else:
                cvar_alpha = (var_alpha + scale - shape * u) / (1.0 - shape)
        else:
            var_alpha = u - scale * np.log(tail_prob)
            cvar_alpha = var_alpha + scale

        if not np.isfinite(cvar_alpha):
            return self.cvar
        return max(float(cvar_alpha), 0.001)
        
    def warmup(self, initial_returns):
        self.history = list(initial_returns[-self.max_history:])
        self._fit_gpd()
        
    def update(self, new_return, force_fit=False):
        self.history.append(new_return)
        if len(self.history) > self.max_history:
            self.history.pop(0)

        if force_fit or self.last_shape is None:
            self._fit_gpd()
        else:
            self._fast_forecast()
        return self.cvar

    def _fast_forecast(self):
        arr = np.array(self.history)
        losses = np.abs(arr[arr < 0])
        if len(losses) < 50: return
        
        u = np.quantile(losses, 1.0 - self.tail_fraction)
        shape = self.last_shape
        scale = self.last_scale

        if shape is None or scale is None:
            return
        if (not np.isfinite(shape)) or (not np.isfinite(scale)) or scale <= 0.0:
            return
        
        self.cvar = self._compute_cvar(u, shape, scale)
            
    def _fit_gpd(self):
        if len(self.history) < 200: return
        
        arr = np.array(self.history)
        
        # Filtramos caídas absolutas para medir magnitud de shock asimétrico
        losses = np.abs(arr[arr < 0])
        if len(losses) < 50: return # Mínimo necesario de caídas
        
        # Umbral "u" donde empieza la cola gorda (Peaks Over Threshold)
        u = np.quantile(losses, 1.0 - self.tail_fraction)
        excedances = losses[losses > u] - u
        
        # Riesgo de convergencia MLE
        if len(excedances) < 10: return
        
        try:
            # Statsmodels/Scipy genpareto -> f(x) = (1 + shape * (x/scale))^(-1 - 1/shape)
            shape, _, scale = stats.genpareto.fit(excedances, floc=0)
            if (not np.isfinite(shape)) or (not np.isfinite(scale)) or scale <= 0.0:
                return

            # Clamp institucional: colas demasiado explosivas degradan estabilidad operativa.
            shape = float(np.clip(shape, -0.50, 0.95))
            self.last_shape = shape
            self.last_scale = scale

            # Establecemos que el Stop Loss mínimo sea 0.1% de distancia
            # Para XAUUSD (~2000), 0.1% son aprox 20 pips ($2) de movimiento bruto mínimo.
            self.cvar = self._compute_cvar(u, shape, scale)
        except Exception:
            # Silently fallback a 1.5% ante no convergencia
            pass
            
    def get_stop_loss_distance(self):
        return self.cvar

    def get_higher_moments(self):
        """Retorna la Asimetría y Curtosis para ajustes de Cornish-Fisher."""
        if len(self.history) < 50:
            return 0.0, 3.0
        arr = np.array(self.history)
        skew = float(stats.skew(arr))
        kurt = float(stats.kurtosis(arr, fisher=False))
        if not np.isfinite(skew):
            skew = 0.0
        if (not np.isfinite(kurt)) or kurt < 1.0:
            kurt = 3.0
        return skew, kurt
