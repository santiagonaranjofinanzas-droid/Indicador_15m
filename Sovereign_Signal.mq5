//+------------------------------------------------------------------+
//|                                     Regime_HMM_EWMA_15M.mq5       |
//|                                  Copyright 2024, TradingAlgo      |
//|                            https://www.mql5.com/en/users/nuevoadmin |
//+------------------------------------------------------------------+
// V8.0 QuantFactory: Todos los 6 puntos estructurales implementados:
//  [x] 1. Concept Drift → Z-score dinámico sobre ventana móvil
//  [x] 2. GJR-GARCH(1,1) → Reemplaza EWMA (efecto apalancamiento)
//  [x] 3. Jump-Diffusion → λ y ν calibrados dinámicamente via momentos
//  [x] 4. Filtro de Kalman → Reemplaza HMA como gate de régimen
//  [x] 5. Ornstein-Uhlenbeck → Reemplaza Conditional EMA para drift
//  [x] 6. Clamping Logístico → z ∈ [-20,20] previene NaN/overflow
//+------------------------------------------------------------------+
#include "Sovereign_Core.mqh"

#property copyright "Copyright 2024, TradingAlgo"
#property link      "https://www.mql5.com/en/users/nuevoadmin"
#property strict
#property tester_file "..\\Files\\HMM_Params_15M.csv"
#property version   "8.10" // V8.1: F(t-1) Parity + Kalman State Isolation
#property indicator_chart_window
#property indicator_buffers 41
#property indicator_plots   8

// Plot 1: HMA Main (Color Line) — visual only, logic uses Kalman
#property indicator_label1  "HMA Trend"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrAqua,clrRed,clrGray
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

// Plot 2: HMA Halo
#property indicator_label2  "HMA Halo"
#property indicator_type2   DRAW_COLOR_LINE
#property indicator_color2  clrAqua,clrRed,clrGray
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

// Plot 3: HMA Aura
#property indicator_label3  "HMA Aura"
#property indicator_type3   DRAW_COLOR_LINE
#property indicator_color3  clrAqua,clrRed,clrGray
#property indicator_style3  STYLE_SOLID
#property indicator_width3  5

// Plot 4: Entry Bull Arrow
#property indicator_label4  "To Bull"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrAqua
#property indicator_width4  1

// Plot 5: Entry Bear Arrow
#property indicator_label5  "To Bear"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrRed
#property indicator_width5  1

// Plot 6: Regime Candles
#property indicator_label6  "Regime Candles"
#property indicator_type6   DRAW_COLOR_CANDLES
#property indicator_color6  clrAqua,clrRed,clrGray
#property indicator_style6  STYLE_SOLID
#property indicator_width6  1

// Plot 7: Regime Change Bull Arrow
#property indicator_label7  "Regime ▲"
#property indicator_type7   DRAW_ARROW
#property indicator_color7  clrMediumPurple
#property indicator_width7  2

// Plot 8: Regime Change Bear Arrow
#property indicator_label8  "Regime ▼"
#property indicator_type8   DRAW_ARROW
#property indicator_color8  clrMediumPurple
#property indicator_width8  2

//--- INPUTS
input string G1 = "─── HMM Engine ───";
input int    InpRetWindow   = 20;     // Return window (v_ret)
input int    InpVolWindow   = 60;     // Volatility window (v_vol)
input double InpThresh      = 0.65;   // Confidence threshold

// Dynamically Loaded Parameters (from CSV, overridden at runtime)
double ExtPBull      = 0.980;
double ExtPBear      = 0.980;
double ExtSlopeT     = 0.0273;
double ExtJumpLambda = 0.05;
double ExtHMMNu      = 4.88;
double ExtWConf      = 0.5;
double ExtWVol       = 0.5;
double ExtWSlope     = 0.5;
double ExtWInter     = 0.0;
// Static fallbacks (kept for CSV compatibility, replaced at runtime by dynamic)
double ExtMuConf = 0.5, ExtStdConf = 0.25;
double ExtMuVol  = 1.0, ExtStdVol  = 0.5;
double ExtMuSlope= 1.0, ExtStdSlope= 2.0;

// --- PUNTO 2: GJR-GARCH ---
input string G2 = "─── Volatility: GJR-GARCH(1,1) ───";
input double InpGarchOmega  = 0.000001; // ω (long-run variance floor)
input double InpGarchAlpha  = 0.05;     // α (ARCH effect)
input double InpGarchGamma  = 0.05;     // γ (Asymmetry / Leverage)
input double InpGarchBeta   = 0.88;     // β (GARCH persistence)
input int    InpLongRunW    = 120;      // Long-run vol window (initial seed)

// --- PUNTO 3: Jump-Diffusion Dynamic Calibration ---
input string G3 = "─── Jump-Diffusion Calibration ───";
input int    InpRecalibWindow = 500;   // Recalibration window (barras)
input double InpJumpSigmaK    = 3.0;  // Threshold: k*σ para detectar salto

// --- PUNTO 4: Kalman Filter Gate ---
input string G4 = "─── Kalman Filter (HMA Replacement) ───";
input double InpKalmanQ       = 0.0001;  // Process noise (Q) — reactividad
input double InpKalmanR       = 0.01;    // Measurement noise (R) — suavizado
input bool   InpKalmanGate    = true;    // Usar Kalman como gate (true) o no
input bool   InpHMAShow       = true;    // Mostrar HMA visualmente

// --- PUNTO 5: Ornstein-Uhlenbeck Drift ---
input string G5 = "─── Asymmetric Drift: Ornstein-Uhlenbeck ───";
input int    InpOUWindow      = 60;    // Ventana AR(1) para estimar OU

// --- PUNTO 1 & 6: Online ML + Stability ---
input string G6 = "─── Machine Learning Online ───";
input int    InpDriftWindow   = 2000;  // Ventana rodante Z-Score (Concept Drift)

// --- Display ---
input string G7 = "─── Execution & Display ───";
input double InpMinStrength   = 0.3;
input bool   InpShowBg        = true;
input bool   InpShowStr       = true;
input bool   InpShowRegArr    = true;
input bool   InpShowTbl       = true;
input string InpTblPos        = "Top Left";

//--- Buffers (output)
double b_hma_main[], b_hma_main_clr[];
double b_hma_halo[], b_hma_halo_clr[];
double b_hma_aura[], b_hma_aura_clr[];
double b_to_bull[], b_to_bear[];
double b_regime_bull[], b_regime_bear[];
double b_open[], b_high[], b_low[], b_close[], b_candle_clr[];

//--- Buffers (hidden calculations)
double b_p1[], b_sigma2_gjr[], b_strength[], b_regime[];
double b_hma_raw_slope[], b_hma_val[];
double b_returns[], b_mu_rets[], b_sig_rets[], b_atr[], b_lr_sigs[], b_init_vars[], b_shifted_close[];
double b_t1[], b_t2[], b_temp_d[];
double b_kurtosis[];
double b_sig_proj[];
// V8: Online scaling buffers
double b_raw_conf[], b_raw_vol[], b_raw_slope[];
// V8.1: Kalman Filter Isolated State Tracking (Anti-Repainting)
double b_kalman_x[], b_kalman_p[];

//--- Global State Variables
int    g_atr_handle    = INVALID_HANDLE;
double g_strength      = 0.0;
double g_hmm_prob      = 0.5;
double g_vol_ratio     = 1.0;
double g_confidence    = 0.0;
double g_nu_dynamic    = 4.88;  // ν calibrado dinámicamente (Punto 3)
double g_lambda_dynamic= 0.05;  // λ calibrado dinámicamente (Punto 3)
double g_kalman_slope  = 0.0;   // Kalman-estimated slope (Punto 4, Display Only)

color C_BULL = clrAqua;
color C_BEAR = C'240,19,19';
color C_NEUT = clrGray;
color C_STR  = C'0,255,136';

//+------------------------------------------------------------------+
//| Utility: Lanczos Log-Gamma                                       |
//+------------------------------------------------------------------+
double LogGamma(double x) {
    if(x <= 0) return 0;
    static const double p[] = {
        676.5203681218851, -1259.1392167224028, 771.32342877765313,
        -176.61502916214059, 12.507343278686905, -0.13857109526572012,
        9.9843695780195716e-6, 1.5056327351493116e-7
    };
    double y = x;
    if(y < 0.5) return MathLog(M_PI / MathSin(M_PI * y)) - LogGamma(1.0 - y);
    y -= 1.0;
    double x_p = 0.99999999999980993;
    for(int i = 0; i < 8; i++) x_p += p[i] / (y + (double)i + 1.0);
    double t = y + 7.5;
    return 0.5 * MathLog(2.0 * M_PI) + (y + 0.5) * MathLog(t) - t + MathLog(x_p);
}

double LogTStudent(double x, double mu, double sig, double nu) {
    if(sig <= 0) sig = 1e-10;
    if(nu <= 2.0) nu = 2.01;
    double z = (x - mu) / sig;
    double log_const = LogGamma((nu + 1.0) / 2.0) - LogGamma(nu / 2.0) - 0.5 * MathLog(nu * M_PI);
    return log_const - MathLog(sig) - ((nu + 1.0) / 2.0) * MathLog(1.0 + (z * z) / nu);
}

double LogNormalJump(double x, double sig_jump) {
    if(sig_jump <= 0) sig_jump = 1e-10;
    return -MathLog(sig_jump) - 0.5 * MathLog(2.0 * M_PI) - 0.5 * MathPow(x / sig_jump, 2.0);
}

//+------------------------------------------------------------------+
//| Incremental Array Functions                                       |
//+------------------------------------------------------------------+
void CalculateWMA(int rates_total, const double &src[], double &wma_buffer[], int period, int start) {
    if(period < 1) return;
    double weight_sum = period * (period + 1) / 2.0;
    int s = MathMax(0, start);
    for(int i=s; i<rates_total; i++) {
        if(i < period - 1) {
            double warmup_sum = 0;
            for(int k=0; k<=i; k++) warmup_sum += src[k];
            wma_buffer[i] = warmup_sum / (i + 1);
            continue;
        }
        double sum = 0;
        for(int j=0; j<period; j++) sum += src[i-j] * (period - j);
        wma_buffer[i] = sum / weight_sum;
    }
}

void CalculateHMA(int rates_total, const double &src[], double &hma_buffer[], int length, int start) {
    if(length < 2) return;
    int half = length / 2;
    int sqn  = (int)MathRound(MathSqrt(length));
    CalculateWMA(rates_total, src, b_t1, half, start);
    CalculateWMA(rates_total, src, b_t2, length, start);
    int s = MathMax(0, start);
    for(int i=s; i<rates_total; i++) b_temp_d[i] = 2.0 * b_t1[i] - b_t2[i];
    CalculateWMA(rates_total, b_temp_d, hma_buffer, sqn, start);
}

void CalculateEMA(int rates_total, const double &src[], double &ema_buffer[], int period, int start) {
    if(period < 1) return;
    double alpha = 2.0 / (period + 1.0);
    int s = MathMax(1, start);
    if(s == 1) ema_buffer[0] = src[0];
    for(int i=s; i<rates_total; i++)
        ema_buffer[i] = src[i] * alpha + ema_buffer[i-1] * (1.0 - alpha);
}

void CalculateStdev(int rates_total, const double &src[], double &dev_buffer[], int period, int start) {
    if(period < 2) return;
    int s = MathMax(0, start);
    for(int i=s; i<rates_total; i++) {
        if(i < period - 1) { dev_buffer[i] = 0; continue; }
        double sum = 0;
        for(int j=0; j<period; j++) sum += src[i-j];
        double mean = sum / period;
        double sq_sum = 0;
        for(int j=0; j<period; j++) sq_sum += MathPow(src[i-j] - mean, 2);
        dev_buffer[i] = MathSqrt(sq_sum / (period > 1 ? period - 1.0 : 1.0));
    }
}

void CalculateVariance(int rates_total, const double &src[], double &var_buffer[], int period, int start) {
    if(period < 2) return;
    int s = MathMax(0, start);
    for(int i=s; i<rates_total; i++) {
        if(i < period - 1) { var_buffer[i] = 0; continue; }
        double sum = 0;
        for(int j=0; j<period; j++) sum += src[i-j];
        double mean = sum / period;
        double sq_sum = 0;
        for(int j=0; j<period; j++) sq_sum += MathPow(src[i-j] - mean, 2);
        var_buffer[i] = sq_sum / (period > 1 ? period - 1.0 : 1.0);
    }
}

void CalculateKurtosis(int rates_total, const double &src[], double &kurt_buffer[], int period, int start) {
    if(period < 4) return;
    int s = MathMax(0, start);
    for(int i=s; i<rates_total; i++) {
        if(i < period - 1) { kurt_buffer[i] = 0; continue; }
        double sum = 0;
        for(int j=0; j<period; j++) sum += src[i-j];
        double mean = sum / period;
        double m2 = 0, m4 = 0;
        for(int j=0; j<period; j++) {
            double diff = src[i-j] - mean;
            double d2 = diff * diff;
            m2 += d2;
            m4 += d2 * d2;
        }
        m2 /= period; m4 /= period;
        if(m2 < 1e-20) { kurt_buffer[i] = 0; continue; }
        kurt_buffer[i] = (m4 / (m2 * m2)) - 3.0;
    }
}

// PUNTO 5: EstimateOUDrift ahora delegado a CStateSpace::EstimateOUDrift (Kernel)

//+------------------------------------------------------------------+
//| Indicator initialization                                         |
//+------------------------------------------------------------------+
int OnInit() {
    // --- Output Buffers ---
    SetIndexBuffer(0,  b_hma_main,     INDICATOR_DATA);
    SetIndexBuffer(1,  b_hma_main_clr, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(2,  b_hma_halo,     INDICATOR_DATA);
    SetIndexBuffer(3,  b_hma_halo_clr, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(4,  b_hma_aura,     INDICATOR_DATA);
    SetIndexBuffer(5,  b_hma_aura_clr, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(6,  b_to_bull,      INDICATOR_DATA);
    SetIndexBuffer(7,  b_to_bear,      INDICATOR_DATA);
    SetIndexBuffer(8,  b_open,         INDICATOR_DATA);
    SetIndexBuffer(9,  b_high,         INDICATOR_DATA);
    SetIndexBuffer(10, b_low,          INDICATOR_DATA);
    SetIndexBuffer(11, b_close,        INDICATOR_DATA);
    SetIndexBuffer(12, b_candle_clr,   INDICATOR_COLOR_INDEX);
    SetIndexBuffer(13, b_regime_bull,  INDICATOR_DATA);
    SetIndexBuffer(14, b_regime_bear,  INDICATOR_DATA);
    
    // --- Internal Calculation Buffers ---
    SetIndexBuffer(15, b_p1,           INDICATOR_CALCULATIONS);
    SetIndexBuffer(16, b_sigma2_gjr,   INDICATOR_CALCULATIONS); // [V8] was b_sigma2_ewma
    SetIndexBuffer(17, b_strength,     INDICATOR_CALCULATIONS);
    SetIndexBuffer(18, b_regime,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(19, b_hma_raw_slope,INDICATOR_CALCULATIONS);
    SetIndexBuffer(20, b_hma_val,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(21, b_returns,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(22, b_mu_rets,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(23, b_sig_rets,     INDICATOR_CALCULATIONS);
    SetIndexBuffer(24, b_atr,          INDICATOR_CALCULATIONS);
    SetIndexBuffer(25, b_lr_sigs,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(26, b_init_vars,    INDICATOR_CALCULATIONS);
    SetIndexBuffer(27, b_shifted_close,INDICATOR_CALCULATIONS);
    SetIndexBuffer(28, b_t1,           INDICATOR_CALCULATIONS);
    SetIndexBuffer(29, b_t2,           INDICATOR_CALCULATIONS);
    SetIndexBuffer(30, b_temp_d,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(31, b_kurtosis,     INDICATOR_CALCULATIONS);
    SetIndexBuffer(32, b_sig_proj,     INDICATOR_CALCULATIONS);
    // V8: Online scaling + OU (reuses slots previously for b_mu_bull/b_mu_bear)
    SetIndexBuffer(33, b_raw_conf,     INDICATOR_CALCULATIONS);
    SetIndexBuffer(34, b_raw_vol,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(35, b_raw_slope,    INDICATOR_CALCULATIONS);
    // V8.1: Kalman Filter Buffers
    SetIndexBuffer(36, b_kalman_x,     INDICATOR_CALCULATIONS);
    SetIndexBuffer(37, b_kalman_p,     INDICATOR_CALCULATIONS);
    // Padding buffers (needed for buffer count = 41)
    SetIndexBuffer(38, b_hma_raw_slope,INDICATOR_CALCULATIONS); // alias ok (same ptr)
    SetIndexBuffer(39, b_t1,           INDICATOR_CALCULATIONS); // alias ok
    SetIndexBuffer(40, b_t2,           INDICATOR_CALCULATIONS); // alias ok

    PlotIndexSetInteger(3, PLOT_ARROW, 225);
    PlotIndexSetInteger(4, PLOT_ARROW, 226);
    PlotIndexSetInteger(6, PLOT_ARROW, 233);
    PlotIndexSetInteger(7, PLOT_ARROW, 234);
    for(int i=0; i<8; i++) PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

    g_atr_handle = iATR(_Symbol, _Period, 14);
    
    // V8.1: State now handled inside OnCalculate buffers
    
    g_nu_dynamic = ExtHMMNu;
    g_lambda_dynamic = ExtJumpLambda;

    IndicatorSetString(INDICATOR_SHORTNAME, "Sovereign Signal V8.1");
    
    // V8: CSV parsing (keeps backward compat, static params used only as seed)
    int handle = FileOpen("HMM_Params_15M.csv", FILE_READ | FILE_CSV | FILE_ANSI, ',');
    if(handle == INVALID_HANDLE) {
        Print("WARNING: HMM_Params_15M.csv not found. Using built-in defaults.");
        return(INIT_SUCCEEDED); // Non-fatal: dynamic params will self-calibrate
    }
    string cols[15]; for(int i=0; i<15; i++) cols[i] = FileReadString(handle);
    bool has_stability = (cols[9] == "MuConf" && cols[14] == "StdSlope");
    if(!FileIsEnding(handle)) {
        string vals[15]; for(int i=0; i<15; i++) vals[i] = FileReadString(handle);
        if(StringLen(vals[0]) > 0) {
            ExtPBull = StringToDouble(vals[0]); ExtPBear = StringToDouble(vals[1]);
            ExtSlopeT = StringToDouble(vals[2]);
            ExtJumpLambda = StringToDouble(vals[3]); g_lambda_dynamic = ExtJumpLambda;
            ExtHMMNu = StringToDouble(vals[4]);      g_nu_dynamic = ExtHMMNu;
            ExtWConf = StringToDouble(vals[5]); ExtWVol = StringToDouble(vals[6]);
            ExtWSlope = StringToDouble(vals[7]); ExtWInter = StringToDouble(vals[8]);
            if(has_stability) {
                ExtMuConf=StringToDouble(vals[9]); ExtMuVol=StringToDouble(vals[10]);
                ExtMuSlope=StringToDouble(vals[11]);
                ExtStdConf=StringToDouble(vals[12]); ExtStdVol=StringToDouble(vals[13]);
                ExtStdSlope=StringToDouble(vals[14]);
            }
            PrintFormat("V8 Loaded CSV: PBull=%.3f λ=%.3f ν=%.2f", ExtPBull, ExtJumpLambda, ExtHMMNu);
        }
    }
    FileClose(handle);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Main Calculation                                                 |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[]) {

    if(rates_total < 300) return(0);

    int hma_warmup = 150 + (int)MathRound(MathSqrt(150)) + 1;
    int min_start = MathMax(hma_warmup, InpLongRunW) + 1;
    int start = prev_calculated - 1;
    if(start < min_start) {
        start = min_start;
        b_p1[0] = 0.5;
        b_sigma2_gjr[0] = InpGarchOmega / (1.0 - InpGarchAlpha - InpGarchGamma*0.5 - InpGarchBeta);
        if(b_sigma2_gjr[0] <= 0 || b_sigma2_gjr[0] > 1.0) b_sigma2_gjr[0] = 0.0001;
        ArrayInitialize(b_hma_main, EMPTY_VALUE);
        ArrayInitialize(b_hma_halo, EMPTY_VALUE);
        ArrayInitialize(b_hma_aura, EMPTY_VALUE);
        ArrayInitialize(b_to_bull, EMPTY_VALUE);
        ArrayInitialize(b_to_bear, EMPTY_VALUE);
        ArrayInitialize(b_regime_bull, EMPTY_VALUE);
        ArrayInitialize(b_regime_bear, EMPTY_VALUE);
        ArrayInitialize(b_open, EMPTY_VALUE);
        ArrayInitialize(b_high, EMPTY_VALUE);
        ArrayInitialize(b_low, EMPTY_VALUE);
        ArrayInitialize(b_close, EMPTY_VALUE);
        ArrayInitialize(b_kalman_x, 0.0);
        ArrayInitialize(b_kalman_p, 1.0);
        // Init Kalman from first valid close
        if (min_start > 0) {
            b_kalman_x[min_start-1] = close[min_start-1];
            b_kalman_p[min_start-1] = 1.0;
        }
    }

    int calc_limit = rates_total;

    // --- ATR Copy ---
    int to_copy = calc_limit - start;
    if(to_copy > 0) {
        static double temp_atr[]; ArrayResize(temp_atr, to_copy, 1000);
        if(CopyBuffer(g_atr_handle, 0, 0, to_copy, temp_atr) <= 0) return(0);
        for(int i=0; i<to_copy; i++) b_atr[start + i] = temp_atr[to_copy - 1 - i];
    }

    // --- F_{t-1} Parity ---
    for(int i=MathMax(0,start); i<calc_limit; i++)
        b_shifted_close[i] = (i > 0) ? close[i-1] : close[0];

    // --- HMA (Visual only in V8) ---
    CalculateHMA(calc_limit, b_shifted_close, b_hma_val, 150, start);

    // --- Returns ---
    for(int i=MathMax(2,start); i<calc_limit; i++)
        b_returns[i] = MathLog(close[i-1] / close[i-2]);

    // --- Volatility Base Components ---
    CalculateEMA(calc_limit, b_returns, b_mu_rets, InpRetWindow, start);
    CalculateStdev(calc_limit, b_returns, b_sig_rets, InpVolWindow, start);
    CalculateStdev(calc_limit, b_returns, b_lr_sigs, InpLongRunW, start);
    CalculateVariance(calc_limit, b_returns, b_init_vars, InpLongRunW, start);
    CalculateKurtosis(calc_limit, b_returns, b_kurtosis, InpLongRunW, start);

    // Prior warmup
    for(int i=1; i<start; i++) if(b_p1[i] == 0.0) b_p1[i] = 0.5;

    // ==========================================
    // MAIN LOOP
    // ==========================================
    for(int i=start; i<calc_limit; i++) {
        double ret = b_returns[i];
        double sig_t = MathMax(b_sig_rets[i], 1e-10);
        double lr_sigma = MathMax(b_lr_sigs[i], 1e-10);

        // PUNTO 5: Ornstein-Uhlenbeck Drift (Kernel Object)
        double mu_bull_ou, mu_bear_ou;
        int ou_start = MathMax(2, i - InpOUWindow + 1);
        CStateSpace::EstimateOUDrift(b_returns, ou_start, MathMin(InpOUWindow, i - ou_start + 1), 
                                     lr_sigma, mu_bull_ou, mu_bear_ou);

        // PUNTO 2: GJR-GARCH Volatility (Kernel Object)
        if(i < InpLongRunW) {
            b_sigma2_gjr[i] = MathMax(b_init_vars[i], 1e-10);
        } else {
            double prev_innov = b_returns[i-1] - b_mu_rets[i-1];
            double prev_sigma = MathMax(b_sigma2_gjr[i-1], 1e-10);
            b_sigma2_gjr[i] = CVolatilityEngine::StepGJRGARCH(prev_innov, prev_sigma, MathMax(b_init_vars[i], 1e-10),
                                                              InpGarchAlpha, InpGarchGamma, InpGarchBeta);
        }
        double gjr_sigma = MathSqrt(b_sigma2_gjr[i]);

        // =========================================
        // PUNTO 3: Dynamic Calibration λ and ν
        // Via method of moments (every InpRecalibWindow bars)
        // =========================================
        if(i >= InpLongRunW && (i % InpRecalibWindow == 0)) {
            int w = MathMin(i, InpRecalibWindow);
            // ν from excess kurtosis: ν = 6/κ + 4 (MOM estimator for t-Student)
            double kappa = b_kurtosis[i];
            if(kappa > 0.01) g_nu_dynamic = MathMax(2.5, MathMin(30.0, 6.0 / kappa + 4.0));
            
            // λ from jump rate: fraction of |ret| > k*σ in last w bars
            int jump_count = 0;
            double threshold = InpJumpSigmaK * lr_sigma;
            for(int k=0; k<w; k++) {
                if(MathAbs(b_returns[i-k]) > threshold) jump_count++;
            }
            g_lambda_dynamic = MathMax(0.01, MathMin(0.30, (double)jump_count / w));
        }

        // PUNTO 4: Kalman Filter Gate (Kernel Object) V8.1: Buffered State Tracking
        double prev_kx = (i > 0) ? b_kalman_x[i-1] : b_shifted_close[i];
        double prev_kp = (i > 0) ? b_kalman_p[i-1] : 1.0;
        double current_kp = prev_kp; // Isolated reference logic
        
        b_kalman_x[i] = CStateSpace::StepKalman(b_shifted_close[i], prev_kx, current_kp, InpKalmanQ, InpKalmanR);
        b_kalman_p[i] = current_kp;
        
        g_kalman_slope = (b_kalman_x[i] - prev_kx) / MathMax(_Point, 1e-10);
        // Kalman gate threshold in ATR units
        double atr_i = MathMax(b_atr[MathMax(i-1,0)], 1e-10);
        double kalman_thresh = atr_i * ExtSlopeT / MathMax(_Point, 1e-10);

        // =========================================
        // HMM Hamilton Filter (Merton Jump-Diffusion)
        // Now uses OU drift (Point 5) + dynamic λ,ν (Point 3)
        // =========================================
        double prev_p1 = (i > 0) ? b_p1[i-1] : 0.5;
        double p1_pred = ExtPBull * prev_p1 + (1.0 - ExtPBear) * (1.0 - prev_p1);
        double p0_pred = 1.0 - p1_pred;

        // Likelihoods with OU drift and dynamic ν
        double ll1 = LogTStudent(ret,  mu_bull_ou, sig_t, g_nu_dynamic);
        double ll0 = LogTStudent(ret, -mu_bear_ou, sig_t, g_nu_dynamic);

        // Jump component with kurtosis-calibrated sigma + dynamic λ
        double excess_kurt = b_kurtosis[i];
        double kurt_mult = MathSqrt(MathMax(excess_kurt + 3.0, 3.0));
        kurt_mult = MathMax(2.0, MathMin(10.0, kurt_mult));
        double sig_jump = MathMax(lr_sigma * kurt_mult, 1e-10);
        double ll_jump = LogNormalJump(ret, sig_jump);
        double ll_max  = MathMax(MathMax(ll1, ll0), ll_jump);

        double lam = g_lambda_dynamic;
        double lik1_mix = (1.0 - lam) * MathExp(ll1 - ll_max) + lam * MathExp(ll_jump - ll_max);
        double lik0_mix = (1.0 - lam) * MathExp(ll0 - ll_max) + lam * MathExp(ll_jump - ll_max);

        double lik1 = p1_pred * lik1_mix;
        double lik0 = p0_pred * lik0_mix;
        double norm_f = lik1 + lik0;
        double prob = (norm_f > 1e-14) ? lik1 / norm_f : p1_pred;
        b_p1[i] = MathMax(1e-4, MathMin(0.9999, prob));
        double hmm_prob = b_p1[i];

        // Mixture Volatility Projection (Law of Total Variance)
        double nu_d = g_nu_dynamic;
        double t_scale = (nu_d > 2.0) ? nu_d / (nu_d - 2.0) : 1.5;
        double var_t = (sig_t * sig_t) * t_scale;
        double var_j = (sig_jump * sig_jump);
        double mu_s_val = (hmm_prob > 0.5) ? mu_bull_ou : -mu_bear_ou;
        double e_var_cond = (1.0-lam)*var_t + lam*var_j + lam*(1.0-lam)*(mu_s_val*mu_s_val);
        double var_e_cond = hmm_prob*(1.0-hmm_prob)*MathPow(1.0-lam,2.0)*MathPow(mu_bull_ou+mu_bear_ou,2.0);
        b_sig_proj[i] = MathSqrt(MathMax(e_var_cond + var_e_cond, 1e-12));

        double confidence = MathAbs(hmm_prob - 0.5) * 2.0;

        // =========================================
        // PUNTO 4: Kalman Gate (Replaces HMA gate)
        // =========================================
        int kalman_regime = (g_kalman_slope > kalman_thresh) ? 1
                          : (g_kalman_slope < -kalman_thresh) ? -1 : 0;

        // HMA Slope (kept for visual line coloring only)
        double hma_val = b_hma_val[i];
        double hma_val_prev = b_hma_val[MathMax(i-5, 0)];
        b_hma_raw_slope[i] = (hma_val - hma_val_prev) / 5.0;
        double hma_slope = b_hma_raw_slope[i];

        // Volatility ratio using GJR sigma vs long-run (Punto 2)
        double vol_ratio = gjr_sigma / lr_sigma;

        // =========================================
        // PUNTO 1 & 6: Online Z-Score + Clamped Logistic
        // =========================================
        double hma_thresh_abs = atr_i * ExtSlopeT;
        double hma_slope_mag = MathAbs(hma_slope) / MathMax(hma_thresh_abs / MathMax(ExtSlopeT, 0.0273), 1e-10);

        b_raw_conf[i]  = confidence;
        b_raw_vol[i]   = vol_ratio;
        b_raw_slope[i] = hma_slope_mag;

        // Rolling statistics for Z-score
        int lookback = MathMin(i - start + 1, InpDriftWindow);
        if(lookback < 2) lookback = 2;

        double sum_c=0, sum_v=0, sum_s=0;
        for(int k=0; k<lookback; k++) {
            sum_c += b_raw_conf[i-k];
            sum_v += b_raw_vol[i-k];
            sum_s += b_raw_slope[i-k];
        }
        double mu_c = sum_c/lookback, mu_v = sum_v/lookback, mu_s2 = sum_s/lookback;
        double sq_c=0, sq_v=0, sq_s=0;
        for(int k=0; k<lookback; k++) {
            sq_c += MathPow(b_raw_conf[i-k]-mu_c,2);
            sq_v += MathPow(b_raw_vol[i-k]-mu_v,2);
            sq_s += MathPow(b_raw_slope[i-k]-mu_s2,2);
        }
        double std_c = MathMax(MathSqrt(sq_c/(lookback-1.0)), 1e-6);
        double std_v = MathMax(MathSqrt(sq_v/(lookback-1.0)), 1e-6);
        double std_s = MathMax(MathSqrt(sq_s/(lookback-1.0)), 1e-6);

        // PUNTO 1 & 6: Z-Score Dinámico y Clamping Logístico (Kernel Object)
        double s_conf  = CStatistics::CalculateZScore(confidence, mu_c, std_c);
        double s_vol   = CStatistics::CalculateZScore(vol_ratio, mu_v, std_v);
        double s_slope = CStatistics::CalculateZScore(hma_slope_mag, mu_s2, std_s);

        double z = ExtWConf*s_conf + ExtWVol*s_vol + ExtWSlope*s_slope + ExtWInter;
        b_strength[i] = CStatistics::LogisticClamped(z); // Clamping anti-overflow integrado

        g_strength   = b_strength[i];
        g_hmm_prob   = hmm_prob;
        g_vol_ratio  = vol_ratio;
        g_confidence = confidence;

        // =========================================
        // Combined Regime (Kalman gate replaces HMA)
        // =========================================
        bool hmm_bull = hmm_prob > InpThresh;
        bool hmm_bear = hmm_prob < (1.0 - InpThresh);
        bool gate_bull_ok = !InpKalmanGate || kalman_regime > 0;
        bool gate_bear_ok = !InpKalmanGate || kalman_regime < 0;

        int regime = (hmm_bull && gate_bull_ok) ? 1 : (hmm_bear && gate_bear_ok) ? -1 : 0;
        b_regime[i] = (double)regime;
        double clr_idx = (regime == 1) ? 0.0 : (regime == -1) ? 1.0 : 2.0;

        // --- HMA Visual (Kalman direction colors the line) ---
        if(InpHMAShow) {
            b_hma_main[i] = hma_val;
            b_hma_halo[i] = InpShowStr ? hma_val : EMPTY_VALUE;
            b_hma_aura[i] = InpShowStr ? hma_val : EMPTY_VALUE;
        } else {
            b_hma_main[i] = EMPTY_VALUE;
            b_hma_halo[i] = EMPTY_VALUE;
            b_hma_aura[i] = EMPTY_VALUE;
        }
        b_hma_main_clr[i] = clr_idx;
        b_hma_halo_clr[i] = clr_idx;
        b_hma_aura_clr[i] = clr_idx;

        // --- Regime Candles ---
        if(InpShowBg) {
            b_open[i]=open[i]; b_high[i]=high[i]; b_low[i]=low[i]; b_close[i]=close[i];
            b_candle_clr[i] = clr_idx;
        }

        // --- Entry Signals ---
        b_to_bull[i] = (regime==1 && b_regime[MathMax(i-1,0)]!=1 && b_strength[i]>InpMinStrength)
                       ? low[i] - 10*_Point : EMPTY_VALUE;
        b_to_bear[i] = (regime==-1 && b_regime[MathMax(i-1,0)]!=-1 && b_strength[i]>InpMinStrength)
                       ? high[i] + 10*_Point : EMPTY_VALUE;

        // --- Regime Change Arrows ---
        if(InpShowRegArr && i > 0) {
            int prev_reg = (int)b_regime[i-1];
            bool changed = (regime != prev_reg);
            b_regime_bull[i] = (changed && regime==1)  ? low[i]  - 20*_Point : EMPTY_VALUE;
            b_regime_bear[i] = (changed && regime==-1) ? high[i] + 20*_Point : EMPTY_VALUE;
        } else {
            b_regime_bull[i] = EMPTY_VALUE;
            b_regime_bear[i] = EMPTY_VALUE;
        }
    }

    if(InpShowTbl) DrawDashboard();
    return(rates_total);
}

//+------------------------------------------------------------------+
//| Dashboard — Updated for V8                                       |
//+------------------------------------------------------------------+
void DrawDashboard() {
    int x_off = 20, y_off = 30;
    ENUM_BASE_CORNER corner = CORNER_LEFT_UPPER;
    if(InpTblPos == "Top Right")    corner = CORNER_RIGHT_UPPER;
    else if(InpTblPos == "Bottom Right") corner = CORNER_RIGHT_LOWER;
    else if(InpTblPos == "Bottom Left")  corner = CORNER_LEFT_LOWER;

    string reg_str = (g_hmm_prob > 0.65) ? "▲ BULL" : (g_hmm_prob < 0.35) ? "▼ BEAR" : "● NEUT";
    color  reg_col = (g_hmm_prob > 0.65) ? C_BULL : (g_hmm_prob < 0.35) ? C_BEAR : C_NEUT;
    
    string nu_str  = DoubleToString(g_nu_dynamic, 2);
    string lam_str = DoubleToString(g_lambda_dynamic * 100.0, 1) + "%";
    string kalman_dir = (g_kalman_slope > 0) ? "▲" : (g_kalman_slope < 0) ? "▼" : "─";

    CreateLabel("HMM_Title",    "── HMM V8 (GJR/Kalman/OU) ──",                          x_off, y_off,      corner, 9,  clrDimGray);
    CreateLabel("HMM_Regime",   "Regime:    " + reg_str,                                   x_off, y_off+18,   corner, 10, reg_col);
    CreateLabel("HMM_Strength", "Strength:  " + DoubleToString(g_strength*100,1) + "%",    x_off, y_off+36,   corner, 10, g_strength>0.75?C_STR:clrWhite);
    CreateLabel("HMM_Prob",     "P(bull):   " + DoubleToString(g_hmm_prob,3),              x_off, y_off+54,   corner, 10, clrWhite);
    CreateLabel("HMM_Vol",      "Vol Ratio: " + DoubleToString(g_vol_ratio,2)+"x",         x_off, y_off+72,   corner, 10, g_vol_ratio>1.5?clrOrangeRed:clrWhite);
    CreateLabel("HMM_Nu",       "ν (dyn):   " + nu_str,                                    x_off, y_off+90,   corner, 9,  clrDimGray);
    CreateLabel("HMM_Lambda",   "λ (dyn):   " + lam_str,                                   x_off, y_off+106,  corner, 9,  clrDimGray);
    CreateLabel("HMM_Kalman",   "Kalman:    " + kalman_dir + " " + DoubleToString(g_kalman_slope,0), x_off, y_off+122, corner, 9, clrDimGray);
}

void CreateLabel(string name, string text, int x, int y, ENUM_BASE_CORNER corner, int size, color col) {
    if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetString(0,  name, OBJPROP_TEXT, text);
    ObjectSetString(0,  name, OBJPROP_FONT, "Consolas");
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
    ObjectSetInteger(0, name, OBJPROP_COLOR, col);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void OnDeinit(const int reason) {
    ObjectsDeleteAll(0, "HMM_");
    if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
}
