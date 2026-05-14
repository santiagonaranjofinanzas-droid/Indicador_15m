import numpy as np

class CorwinSchultzEstimator:
    """
    Estimador de Microestructura de Garman-Klass y Corwin-Schultz.
    Infiere el Spread (fricción real del mercado) a partir de los Altos y Bajos de las velas.
    Si el Spread supera al Drift esperado, la operación estadística carece de Edge neto.
    """
    def __init__(self, window_size=20):
        self.history = []
        self.window_size = window_size
        self.current_spread = 0.0001 # Fallback conservador
        
    def update(self, h, l):
        """Agrega los extremos de la vela y re-estima."""
        # Evitar ceros o precios corrompidos
        if h <= 0 or l <= 0: return self.current_spread
        h = max(h, l * 1.00001)
        
        self.history.append((h, l))
        if len(self.history) > self.window_size:
            self.history.pop(0)
            
        return self._calculate_spread()
            
    def _calculate_spread(self):
        if len(self.history) < 2: return self.current_spread
        
        # Tomando las dos últimas velas para cálculo dinámico rápido
        betas = []
        gammas = []
        for i in range(1, len(self.history)):
            h1, l1 = self.history[i-1]
            h2, l2 = self.history[i]
            
            # Componente B: Varianza suma de días adyacentes
            b_val = (np.log(h1/l1)**2) + (np.log(h2/l2)**2)
            
            # Componente Y: Varianza del máximo entre los dos días
            h_max = max(h1, h2)
            l_min = min(l1, l2)
            g_val = (np.log(h_max/l_min))**2
            
            betas.append(b_val)
            gammas.append(g_val)
            
        beta = np.mean(betas)
        gamma = np.mean(gammas)
        
        # Despeje de Alpha
        den = 3 - 2 * np.sqrt(2)
        if den <= 1e-12:
            return self.current_spread
        
        # Evitar square roots negativos en mercados anómalos
        if (not np.isfinite(beta)) or (not np.isfinite(gamma)) or beta < 0 or gamma < 0:
            return self.current_spread
        
        alpha = (np.sqrt(2 * beta) - np.sqrt(beta)) / den - np.sqrt(gamma / den)
        
        # Retornar Spread a 0 si alpha < 0 (Spread negativo no tiene sentido)
        if alpha < 0: 
            alpha = 0
            
        exp_a = np.exp(alpha)
        # S (Spread Implícito en porcentaje)
        S = 2 * (exp_a - 1) / (1 + exp_a)

        # Bound institucional para evitar explosión del ruido de medida en barras corruptas.
        self.current_spread = float(np.clip(S, 0.0, 0.05))
        return float(self.current_spread)
