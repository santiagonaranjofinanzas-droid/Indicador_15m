import numpy as np

class FractionalKellySizer:
    """
    Dimensionador de Posición de Crecimiento Asintótico Óptimo (Criterio de Kelly).
    Calcula qué porcentaje del capital debe exponerse frente a cada operación,
    basado en el Edge de la deriva ajustada (Corwin-Schultz) y atenuado al 25%.
    """
    def __init__(self, kelly_fraction=0.25, direction_edge_threshold=0.15, min_fraction=0.005, max_fraction=0.05):
        # Atenuador 'c' de Drawdown Adverso (0.25 = Quarter Kelly)
        self.c = float(np.clip(kelly_fraction, 0.0, 1.0))
        self.direction_edge_threshold = float(np.clip(direction_edge_threshold, 0.0, 1.0))
        self.min_fraction = float(max(min_fraction, 0.0))
        self.max_fraction = float(max(max_fraction, self.min_fraction))
        
    def optimal_f(self, mu_adj, sigma_sq, prob_bull, prob_bear, skew=0.0, kurt=3.0, cvar_stop=0.0):
        """
        Retorna la fracción f* de exposición de capital ajustada por Cornish-Fisher.
        Si el Edge es negativo, rechaza la operación enviando 0.0.
        """
        values = np.array([mu_adj, sigma_sq, prob_bull, prob_bear, skew, kurt, cvar_stop], dtype=float)
        if not np.all(np.isfinite(values)):
            return 0.0

        sigma_sq = max(float(sigma_sq), 1e-10)
        prob_bull = float(np.clip(prob_bull, 0.0, 1.0))
        prob_bear = float(np.clip(prob_bear, 0.0, 1.0))

        # HMM Directional Edge: Si ambos estados compiten 40%-40%, no hay ventaja topológica
        dir_edge = abs(prob_bull - prob_bear)
        
        # Filtro Riguroso: Si la diferencia de probabilidades es menor al 15%, Abortar Ejecución
        if dir_edge < self.direction_edge_threshold:
            return 0.0
            
        # Filtro de Microestructura C-S: Spread Implícito es más dañino que la expectativa
        if mu_adj <= 0:
            return 0.0
            
        # Validación Dimensional Estricta (Protección contra explosión de Kelly)
        # mu_adj y sigma_sq deben estar en escala decimal de log-retornos (ej. mu ~ 0.0005, sigma_sq ~ 0.000001)
        if abs(mu_adj) > 0.1 or sigma_sq > 0.1:
            # Si entran valores en escala porcentual entera (ej. 1.5 en vez de 0.015), abortar para evitar apalancamiento masivo
            return 0.0
            
        # Extraer Momentos Desnormalizados Exactos (mu_3, mu_4)
        sigma = np.sqrt(sigma_sq)
        mu_3 = skew * (sigma**3)
        mu_4 = kurt * (sigma**4)
        
        # Búsqueda de Raíces: g'(f) = -mu_4 * f^3 + mu_3 * f^2 - sigma^2 * f + mu_adj = 0
        coeffs = [-mu_4, mu_3, -sigma_sq, mu_adj]
        
        try:
            rts = np.roots(coeffs)
            real_rts = rts[np.isreal(rts)].real
            valid_rts = real_rts[(real_rts > 0.0) & (real_rts <= 0.5)] # Hard cap teórico de evaluación
            if len(valid_rts) > 0:
                # Si la función convexa tiene máximo local válido
                # La fracción de Kelly de Taylor es la raíz misma.
                f_mod = float(valid_rts.max())
            else:
                # Decaimiento a aproximación log-normal segura
                f_mod = mu_adj / max(sigma_sq, 1e-8)
        except Exception:
            f_mod = mu_adj / max(sigma_sq, 1e-8)

        if not np.isfinite(f_mod):
            return 0.0

        # Bound teórico previo al cap institucional.
        f_mod = float(np.clip(f_mod, 0.0, 0.25))
            
        # Cuarteo de Kelly (Atenuación C)
        f_mod *= self.c
        
        # Límites Institucionales Mandatorios (Risk Cap):
        # Evaluar la pérdida CVaR proyectada
        if f_mod > 0:
            if cvar_stop > 0.0 and (f_mod * cvar_stop) > self.max_fraction:
                # Hard EVT Bound: Limitar Kelly para que en el peor caso al 99% no perdamos > 5%
                f_mod = self.max_fraction / cvar_stop
                
            f_final = max(min(f_mod, self.max_fraction), self.min_fraction)
        else:
            f_final = 0.0
            
        return float(f_final)
