//+------------------------------------------------------------------+
//|                                     MacroAgent_Kernel.mqh        |
//|                                  Copyright 2024, QuantFactory    |
//+------------------------------------------------------------------+
#property strict

#define STABILITY_CLAMP 20.0
#define EPSILON 1e-12

class CStatistics {
public:
    static double LogisticClamped(double z) {
        double clamped_z = MathMax(-STABILITY_CLAMP, MathMin(STABILITY_CLAMP, z));
        return 1.0 / (1.0 + MathExp(-clamped_z));
    }

    static double CalculateZScore(double value, double mean, double std) {
        if(std < EPSILON) return 0.0;
        return (value - mean) / std;
    }
};

class CVolatilityEngine {
public:
    // GJR-GARCH estático puro (Evita desincronización de estado en MT5)
    static double StepGJRGARCH(double prev_innov, double prev_sigma2, double var_target, 
                               double alpha, double gamma, double beta) {
        double persistence = alpha + beta + (gamma / 2.0);
        
        // Imposición de estacionariedad estricta
        if(persistence >= 1.0) {
            double scale = 0.99 / persistence;
            alpha *= scale; beta *= scale; gamma *= scale;
            persistence = 0.99;
        }
        
        double omega = var_target * (1.0 - persistence);
        double indicator = (prev_innov < 0) ? 1.0 : 0.0;
        double eps2 = prev_innov * prev_innov;
        
        double current_sigma2 = omega + alpha * eps2 + gamma * indicator * eps2 + beta * prev_sigma2;
        return MathMax(current_sigma2, EPSILON);
    }
};

class CStateSpace {
public:
    // Filtro de Kalman secuencial (p_state se pasa por referencia para mantener el estado en el buffer)
    static double StepKalman(double measurement, double prev_x, double &p_state, double q, double r) {
        double p_pred = p_state + q;
        double k_gain = p_pred / (p_pred + r);
        double x_new  = prev_x + k_gain * (measurement - prev_x);
        p_state = (1.0 - k_gain) * p_pred;
        return x_new;
    }

    // Estimador de Deriva Ornstein-Uhlenbeck con Clipping Asintótico
    static void EstimateOUDrift(const double &rets[], int start, int count, double lr_sigma, 
                                double &mu_bull, double &mu_bear) {
        if(count < 4) { mu_bull = EPSILON; mu_bear = EPSILON; return; }
        
        double sx = 0, sy = 0, sxx = 0, sxy = 0;
        for(int k=0; k<count-1; k++) {
            double x = rets[start + k];
            double y = rets[start + k + 1];
            sx += x; sy += y; sxx += x*x; sxy += x*y;
        }
        
        double denom = ((count-1) * sxx - sx * sx);
        double ar1 = (MathAbs(denom) > EPSILON) ? ((count-1) * sxy - sx * sy) / denom : 0.0;
        ar1 = MathMax(-0.9999, MathMin(0.9999, ar1)); // Restricción ergódica
        
        double intercept = (sy - ar1 * sx) / (count-1);
        double mu_ou = (MathAbs(1.0 - ar1) > EPSILON) ? intercept / (1.0 - ar1) : 0.0;
        
        // LIMITADOR DE SEGURIDAD (Evita explosión matemática si ar1 -> 1.0)
        double max_drift = 2.0 * MathMax(lr_sigma, EPSILON);
        mu_ou = MathMax(-max_drift, MathMin(max_drift, mu_ou));
        
        mu_bull = MathMax(mu_ou, EPSILON);
        mu_bear = MathMax(-mu_ou, EPSILON);
    }
};
