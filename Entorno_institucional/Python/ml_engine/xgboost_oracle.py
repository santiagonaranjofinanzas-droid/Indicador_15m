import os
import logging
import numpy as np
import xgboost as xgb
import joblib

class XGBoostOracle:
    """
    Real-time inference engine for the Meta-Labeling layer.
    """
    def __init__(self, model_path="ml_engine/meta_model.json", scaler_path="ml_engine/scaler.pkl"):
        self.model_path = model_path
        self.scaler_path = scaler_path
        self.model = None
        self.scaler = None
        self._load_model()

    def _load_model(self):
        try:
            if os.path.exists(self.model_path):
                self.model = xgb.Booster()
                self.model.load_model(self.model_path)
                logging.info(f"XGBoost model loaded from {self.model_path}")
            
            if os.path.exists(self.scaler_path):
                self.scaler = joblib.load(self.scaler_path)
                logging.info(f"Scaler loaded from {self.scaler_path}")
        except Exception as e:
            logging.error(f"Failed to load XGBoost components: {e}")

    def predict_confidence(self, feature_list):
        """
        Predicts the probability of a win given the feature vector.
        If no model is loaded, returns 1.0 (pass-through).
        """
        if self.model is None:
            return 1.0
        
        try:
            # Prepare feature array directly from the list sent by MT5
            feature_vector = np.array([feature_list], dtype=float)

            if self.scaler:
                feature_vector = self.scaler.transform(feature_vector)
            
            dmatrix = xgb.DMatrix(feature_vector)
            prob = self.model.predict(dmatrix)
            return float(prob[0])
        except Exception as e:
            logging.error(f"XGBoost inference error: {e}")
            return 1.0
