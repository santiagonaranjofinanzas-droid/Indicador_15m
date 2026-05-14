import sys
import os
import numpy as np
import logging

# Inyectar el entorno raíz para llamar al motor de Fase 3
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from quant_server import QuantEngine
from validation.purged_walkforward import PurgedWalkForward
from validation.pbo_metrics import PBOMetrics

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')

class OOSSimulator:
    """
    Simulador Vectorial Offline.
    Ejecuta el Core Cuantitativo (Fase 2 y 3) iterativamente a través 
    de bloques temporales purgados (Walk-Forward clásico) para descubrir Overfitting.
    """
    def __init__(self, synthetic_history_len=5000):
        # En el mundo real, aquí se cargaría el DataFrame XAUUSD de MetaTrader
        # Generaremos ruido de mercado para este test sintético.
        self.data_len = synthetic_history_len
        self.cv = PurgedWalkForward(n_splits=3, purge_size=200)
        self.pbo = PBOMetrics(trials_count=20) # 20 iteraciones asumiendo múltiples I+D
        
    def generate_synthetic_data(self):
        """OHLCV Dummy para testear el simulador."""
        np.random.seed(42)
        returns = np.random.normal(0, 0.001, self.data_len)
        closes = 2000.0 * np.exp(np.cumsum(returns)) # Oro Dummy
        
        # O, H, L, C, V
        hist = []
        for c in closes:
            hist.append([c-0.1, c+0.5, c-0.5, c, 100])
        return np.array(hist)
        
    def run_walkforward(self):
        data = self.generate_synthetic_data()
        splits = self.cv.split(len(data))
        logging.info(f"Generated {len(splits)} Purged Walk-Forward Splits.")
        
        all_oos_returns = []
        
        for k, (train_idx, test_idx) in enumerate(splits):
            logging.info(f"--- FOLD {k+1} ---")

            # Motor nuevo por fold para evitar fuga de estado entre bloques OOS.
            fold_engine = QuantEngine()
            
            # 1. WarmpUp (Train)
            train_data = data[train_idx]
            fold_engine.warmup(train_data.tolist())
            
            # 2. Testing OOS (Tick a Tick ciego)
            test_data = data[test_idx]
            fold_returns = []
            equity = 1.0 # Control de Volatility Drag Muestral
            
            for i in range(len(test_data)):
                row = test_data[i]
                # Inferencia L3
                cmd = fold_engine.process_tick(row[0], row[1], row[2], row[3], row[4])
                
                # Simular P&L (Dirección * Retorno Futuro de la barra)
                if i < len(test_data)-1 and "action" in cmd:
                    f_star = cmd.get("optimal_f", 0.0)
                    dir_mult = 1.0 if cmd.get("direction") == "BUY" else (-1.0 if cmd.get("direction")=="SELL" else 0.0)
                    
                    # Retorno Asumiendo Slippage por Open Mismatch
                    # Si MQL5 ejecuta en el Tick 0 de la barra i+1, la entrada es el Open de i+1.
                    # Asume que se cierra la operación en el Cierre de la vela i+1.
                    next_return = np.log(test_data[i+1][3] / test_data[i+1][0])
                    
                    # Simulación Realista con Equidad Acumulada (captura el Volatility Drag del sizing dinámico)
                    trade_pct_return = dir_mult * f_star * next_return
                    equity *= (1.0 + trade_pct_return)
                    
                    fold_returns.append(trade_pct_return)
                    
            all_oos_returns.extend(fold_returns)
            logging.info(f"Fold {k+1} completed. Executed {len(fold_returns)} bars. Terminal Equity: {equity:.4f}")
            
        # PBO Evaluation
        sharpe, pbo_chance = self.pbo.evaluate_dsr(all_oos_returns)
        
        logging.info("=" * 40)
        logging.info("  REPORTE FINAL PURGED WALK-FORWARD OOS")
        logging.info("=" * 40)
        logging.info(f"Total OOS Bars Traded : {len(all_oos_returns)}")
        logging.info(f"Deflated Sharpe Ratio : {sharpe:.4f}")
        logging.info(f"Overfitting (PBO) %   : {pbo_chance*100.0:.2f} %")
        if pbo_chance > 0.05:
            logging.warning("ALERTA QUANT: El sistema está sobreajustado o no tiene Edge ante ruido Aleatorio.")
        else:
            logging.info("SISTEMA ROBUSTO E INSTITUTIONAL-READY.")

if __name__ == "__main__":
    sim = OOSSimulator()
    sim.run_walkforward()
