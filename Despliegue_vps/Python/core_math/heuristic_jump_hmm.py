import numpy as np
import warnings
from hmmlearn import hmm

# Silenciar warnings de Scikit y HMM
warnings.filterwarnings("ignore")

class HeuristicJumpHMM:
    """
    Modelo Oculto de Markov con Penalidad de Salto Heurística.
    Aisla los Hidden States, los ordena por Deriva Media (Mu) y aplica
    penalizaciones logísticas basadas en observables exógenos (Volatilidad).
    Nota: La matriz de transición es homogénea en el tiempo. El "TVTP" es simulado vía heurística.
    """
    def __init__(self, n_components=3, window_size=500):
        self.n_components = n_components
        self.window_size = window_size
        # Usamos GaussianHMM base para iteraciones EM eficientes
        self.model = hmm.GaussianHMM(n_components=n_components, 
                                     covariance_type="diag", 
                                     n_iter=100,
                                     tol=0.01) # Baja tolerancia para velocidad
        self.history = []
        self.is_fitted = False
        
    def warmup(self, initial_returns):
        """Pre-calienta el estado iterativo."""
        self.history = list(initial_returns[-self.window_size:])
        self._fit()
        
    def _fit(self):
        if len(self.history) < 100: return
        data = np.array(self.history).reshape(-1, 1)
        try:
            self.model.fit(data)
            self.is_fitted = True
        except Exception:
            self.is_fitted = False
            
    def update(self, new_return, exo_variance, garch_variance, force_fit=False):
        """
        Ingresa nuevo dato, mantiene ventana rodante, refitea (opcional) y 
        devuelve las probabilidades ajustadas evaluando varianza estructural.
        """
        self.history.append(new_return)
        if len(self.history) > self.window_size:
            self.history.pop(0)
            
        if force_fit or not self.is_fitted:
            self._fit()
            
        return self._predict_tvtp(new_return, exo_variance, garch_variance)
        
    def _predict_tvtp(self, z_t, exo_var, garch_var):
        """Lógica Algorítmica de Descuento (TVTP)."""
        if not self.is_fitted:
            return {"bull": 0.33, "neutral": 0.33, "bear": 0.33, "drift": 0.0}
            
        data = np.array(self.history).reshape(-1, 1)
        # Extraer probabilidades Posteriores Smoothing (O(N) Forward-Backward)
        _, posteriors = self.model.score_samples(data)
        
        # Aislar vector probabilístico del Tiempo Actual [t]
        p_t = posteriors[-1] 
        
        # En Unsupervised ML, los estados no tienen etiquetas fijas.
        # Ordenamos los estados en función de la Mediana/Media de sus gaussianas.
        means = self.model.means_.flatten()
        stds  = np.sqrt(self.model.covars_.flatten())
        sorted_idx = np.argsort(means)
        
        # p_bear siempre será el estado de índice con media más baja
        p_bear = p_t[sorted_idx[0]]
        # p_bull la media más alta
        p_bull = p_t[sorted_idx[-1]]
        
        if self.n_components == 3:
            p_neutral = p_t[sorted_idx[1]]
        else:
            p_neutral = 0.0
            
        # --- Lógica TVTP Logística (Atenuación Condicional) ---
        # Si la varianza Exógena (Garman-Klass) excede la proyectada por GARCH condicional,
        # significa un cisne negro o microestructura ruidosa no capturada en el GJR.
        if exo_var > (garch_var * 3.0):
            # Penalty de Salto (Jump Diffusion penalizer)
            discount = 0.5 # Corta la certidumbre a la mitad
            p_bull *= discount
            p_bear *= discount
            p_neutral = 1.0 - (p_bull + p_bear)
            
        # Drift Esperado Ponderado
        drift_esperado = (p_bear * means[sorted_idx[0]]) + (p_bull * means[sorted_idx[-1]])
            
        return {
            "bull": float(p_bull),
            "neutral": float(p_neutral),
            "bear": float(p_bear),
            "drift": float(drift_esperado) # Retornar deriva predictiva también
        }
