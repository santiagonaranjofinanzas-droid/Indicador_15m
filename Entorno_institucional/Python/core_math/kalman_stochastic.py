import numpy as np

class AdaptiveKalmanFilter:
    """
    Filtro de Kalman con Covarianza de Ruido de Medida (R_t) Estocástica.
    Utiliza el estimador de Garman-Klass para medir la expansión de rango intrabarra.
    ATENCIÓN DIMENSIONAL: El estado `x` y las observaciones `z_t` deben operar
    en el espacio de retornos logarítmicos (ej: 0.001), NO en precios absolutos.
    Si la barra es muy volátil, el filtro confía menos en la observación actual.
    """
    def __init__(self, initial_state=0.0, initial_cov=1.0, process_noise=0.0001):
        self.x = initial_state
        self.P = initial_cov
        self.Q = process_noise # Ruido estructural del proceso (Deriva)
        
    def _garman_klass_var(self, o, h, l, c):
        """Estimador Garman-Klass de volatilidad."""
        if l == 0 or o == 0: return 1e-8
        
        # Protección contra rangos cero
        h = max(h, l * 1.00001) 
        
        term1 = 0.5 * (np.log(h / l))**2
        term2 = (2 * np.log(2) - 1) * (np.log(c / o))**2
        var_gk = term1 - term2
        return max(var_gk, 1e-8)
        
    def step(self, z_t, R_t, Q_t):
        """
        Calcula el estado filtrado F(t) aislando el ruido estructural del ruido de medida.
        """
        self.Q = max(Q_t, 1e-8)
        
        # 1. Predicción a priori
        x_pred = self.x
        P_pred = self.P + self.Q
        
        # 2. Ruido de Medida Estocástico (Microestructura)
        R_t = max(R_t, 1e-8)
        
        # 3. Ganancia de Kalman (Sensibilidad)
        S = P_pred + R_t
        K = P_pred / S if S != 0 else 0
        
        # 4. Actualización a posteriori
        self.x = x_pred + K * (z_t - x_pred)
        self.P = (1 - K) * P_pred
        
        return self.x
