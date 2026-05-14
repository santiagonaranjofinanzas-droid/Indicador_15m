import numpy as np

class PurgedWalkForward:
    """
    Walk-Forward Cross-Validation con Embargo y Purga.
    Protege contra fugas de datos (Data Leakage) asilando la memoria
    autoregresiva de los modelos GARCH/HMM.
    """
    def __init__(self, n_splits=5, purge_size=500, embargo_size=100, min_train_size=500, min_test_size=100):
        self.n_splits = n_splits
        self.purge_size = purge_size  # Barras eliminadas entre Train y Test
        self.embargo_size = embargo_size  # Barras adicionales de separación temporal
        self.min_train_size = min_train_size
        self.min_test_size = min_test_size
        
    def split(self, total_len):
        """
        Retorna listas de (train_indices, test_indices)
        Respetando estrictamente la flecha del tiempo (Walk-Forward clásico).
        """
        splits = []
        if total_len <= 0:
            return splits

        indices = np.arange(total_len)

        test_size = max(total_len // (self.n_splits + 1), self.min_test_size)
        total_gap = self.purge_size + self.embargo_size
        
        # Iterar avanzando en el tiempo
        for i in range(1, self.n_splits + 1):
            train_end = max(i * test_size, self.min_train_size)
            test_start = train_end + total_gap
            if test_start >= total_len:
                break
            test_end = test_start + test_size
            
            # Si el test se sale de rango, terminamos
            if test_end > total_len:
                test_end = total_len
            
            test_idx = indices[test_start:test_end]
            train_idx = indices[:train_end]
            
            # Checkeos de sanidad matemática
            if len(train_idx) >= self.min_train_size and len(test_idx) >= self.min_test_size:
                splits.append((train_idx, test_idx))
                
        return splits
