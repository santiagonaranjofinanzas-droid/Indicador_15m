import xgboost as xgb
import matplotlib.pyplot as plt
import os
import json

# Paths
MODEL_PATH = r"c:\Users\NuevoAdmin\Desktop\15m - HMM\Entorno_institucional\Python\ml_engine\meta_model.json"
REPORT_PATH = r"c:\Users\NuevoAdmin\Desktop\15m - HMM\Entorno_institucional\Python\ml_engine\training_report.json"
OUTPUT_IMAGE = r"c:\Users\NuevoAdmin\Desktop\15m - HMM\Entorno_institucional\Python\ml_engine\feature_importance.png"

def main():
    if not os.path.exists(MODEL_PATH):
        print(f"Error: Model not found at {MODEL_PATH}")
        return

    # Load model
    model = xgb.Booster()
    model.load_model(MODEL_PATH)

    # Load feature names from report if available
    features = ["f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9"] # Defaults
    if os.path.exists(REPORT_PATH):
        with open(REPORT_PATH, "r") as f:
            report = json.load(f)
            features = report.get("features", features)
    
    # Map feature names to model
    model.feature_names = features

    # Get importance (Gain is usually the most informative for finance)
    importance_types = ['weight', 'gain', 'cover']
    
    fig, axes = plt.subplots(1, 2, figsize=(15, 6))
    
    # Plot Gain (Contribution to accuracy)
    xgb.plot_importance(model, importance_type='gain', ax=axes[0], show_values=False, 
                        title='Feature Importance (Gain)', xlabel='Average Gain')
    
    # Plot Weight (Frequency of use)
    xgb.plot_importance(model, importance_type='weight', ax=axes[1], show_values=False, 
                        title='Feature Importance (Weight)', xlabel='F-Score (Frequency)')
    
    plt.tight_layout()
    plt.savefig(OUTPUT_IMAGE)
    print(f"Chart saved to {OUTPUT_IMAGE}")

if __name__ == "__main__":
    main()
