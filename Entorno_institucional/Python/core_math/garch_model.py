import numpy as np
import pandas as pd
from arch import arch_model
import warnings

warnings.filterwarnings('ignore', category=FutureWarning)
warnings.filterwarnings('ignore', category=RuntimeWarning)

class QuantitativeGARCH:
    """
    Motor Asimétrico de Volatilidad (GJR-GARCH QMLE)
    Captura el 'Leverage Effect' (Caídas generan más varianza que subidas).
    """
    def __init__(self, window_size=1000, p=1, o=1, q=1, dist='skewt'):
        self.window_size = window_size
        self.p = p
        self.o = o
        self.q = q
        self.dist = dist
        self.returns_buffer = []
        self.last_forecast = 0.0001
        self.last_params = None

    def warmup(self, initial_returns):
        """Inicializa el buffer con datos históricos (ej. 500 barras pasadas)"""
        self.returns_buffer = list(initial_returns[-self.window_size:])
        self._fit_model()

    def update(self, new_return, force_fit=False):
        """Añade un nuevo retorno, mantiene la ventana y re-estima asincronamente."""
        self.returns_buffer.append(new_return)
        if len(self.returns_buffer) > self.window_size:
            self.returns_buffer.pop(0)

        if force_fit or self.last_params is None:
            self._fit_model()
        else:
            self._fast_forecast()
            
        return self.last_forecast

    def _fast_forecast(self):
        """Proyección O(1) usando los parámetros estables previos."""
        if len(self.returns_buffer) < 50 or self.last_params is None: return
        ret_series = pd.Series(self.returns_buffer) * 100.0
        am = arch_model(ret_series, vol='GARCH', p=self.p, o=self.o, q=self.q, 
                        dist=self.dist, mean='Zero', rescale=False)
        # fix() evalúa el modelo sin optimizar (instantáneo)
        res = am.fix(self.last_params)
        forecasts = res.forecast(horizon=1)
        var_t1 = forecasts.variance.iloc[-1, 0] / 10000.0
        self.last_forecast = max(var_t1, 1e-8)

    def _fit_model(self):
        if len(self.returns_buffer) < 50:
            return # No hay suficientes datos

        ret_series = pd.Series(self.returns_buffer) * 100.0 # ARCH convergiendo mejor con %
        
        # Mean=Zero o Constant. GJR-GARCH(1,1) con SkewT.
        am = arch_model(ret_series, vol='GARCH', p=self.p, o=self.o, q=self.q, 
                        dist=self.dist, mean='Zero', rescale=False)
        try:
            # Disp='off' silencia log, update_freq=0
            res = am.fit(disp='off', options={'maxiter': 50})
            self.last_params = res.params
            
            # Predict 1 step ahead
            forecasts = res.forecast(horizon=1)
            # Varianza proyectada en escala decimal original
            var_t1 = forecasts.variance.iloc[-1, 0] / 10000.0
            self.last_forecast = max(var_t1, 1e-8)
        except Exception as e:
            # Fallback a varianza asintótica muestral en caso de no convergencia
            var_t1 = np.var(self.returns_buffer[-50:])
            self.last_forecast = max(var_t1, 1e-8)

    def get_conditional_variance(self):
        return self.last_forecast
