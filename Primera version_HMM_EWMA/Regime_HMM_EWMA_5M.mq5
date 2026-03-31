//+------------------------------------------------------------------+
//|                                     Regime_HMM_EWMA_5M.mq5        |
//|                                  Copyright 2024, TradingAlgo      |
//|                            https://www.mql5.com/en/users/nuevoadmin |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, TradingAlgo"
#property link      "https://www.mql5.com/en/users/nuevoadmin"
#property strict
#property tester_file "..\\Files\\HMM_Params_5M.csv"

//---
#property version   "6.00" // V6: Microstructure & Projection
#property indicator_chart_window
#property indicator_buffers 35
#property indicator_plots   8

// Plot 1: HMA Main (Color Line)
#property indicator_label1  "HMA Trend"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrAqua,clrRed,clrGray
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

// Plot 2: HMA Halo (Color Line - glow)
#property indicator_label2  "HMA Halo"
#property indicator_type2   DRAW_COLOR_LINE
#property indicator_color2  clrAqua,clrRed,clrGray
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

// Plot 3: HMA Aura (Color Line - outer glow)
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

// Plot 7: Regime Change Bull Arrow (Purple)
#property indicator_label7  "Regime ▲"
#property indicator_type7   DRAW_ARROW
#property indicator_color7  clrMediumPurple
#property indicator_width7  2

// Plot 8: Regime Change Bear Arrow (Purple)
#property indicator_label8  "Regime ▼"
#property indicator_type8   DRAW_ARROW
#property indicator_color8  clrMediumPurple
#property indicator_width8  2

input string G1 = "─── HMM Engine Asimétrico ───";
input int    InpRetWindow   = 20;     // Return window (v_ret)
input int    InpVolWindow   = 60;     // Volatility window (v_vol)
input double InpThresh      = 0.65;   // Confidence threshold

// Dynamically Loaded Parameters (V6: Institutional DGP + ML Scoring)
double ExtPBull      = 0.980;   // P(Bull|Bull)
double ExtPBear      = 0.980;   // P(Bear|Bear)
double ExtSlopeT     = 0.0273;  // Slope threshold
double ExtJumpLambda = 0.05;    // Jump intensity (λ)
double ExtHMMNu      = 4.88;    // t-Student DoF (ν)

// ML Strength Score Weights (V7: Ridge + Scaling)
double ExtWConf      = 0.5;
double ExtWVol       = 0.5;
double ExtWSlope     = 0.5;
double ExtWInter     = 0.0;
// Feature Standardization (Z-score)
double ExtMuConf     = 0.5, ExtStdConf = 0.25;
double ExtMuVol      = 1.0, ExtStdVol  = 0.5;
double ExtMuSlope    = 1.0, ExtStdSlope = 2.0;

input string G2 = "─── HMA Confirmation ───";
input int    InpHMALen      = 150;    // HMA Length (V7.1 Reactivity)
input int    InpSlopeN      = 5;      // Slope lookback
input int    InpSlopeS      = 3;      // Slope smooth
input bool   InpHMAReq      = true;   // Require HMA confirm
input bool   InpHMAShow     = true;   // Show HMA


input string G3 = "─── EWMA Volatility ───";
input double InpLambda      = 0.970;  // Lambda (Decay)
input int    InpLongRunW    = 120;    // Long-run vol window

input string G4 = "─── Execution & Display ───";
input double      InpMinStrength      = 0.3;          // Minimum Strength for Trade Confirmation
input bool   InpShowBg      = true;   // Background tint (candles)
input bool   InpShowStr     = true;   // Show strength glow on HMA
input bool   InpShowRegArr  = true;   // Show regime change arrows
input bool   InpShowTbl     = true;   // Show table
input string InpTblPos      = "Top Left"; // Table corner

// --- Buffers ---
double b_hma_main[], b_hma_main_clr[];
double b_hma_halo[], b_hma_halo_clr[];
double b_hma_aura[], b_hma_aura_clr[];
double b_to_bull[], b_to_bear[];
double b_regime_bull[], b_regime_bear[];
double b_open[], b_high[], b_low[], b_close[], b_candle_clr[];

// Hidden Buffers for calculation
double b_p1[], b_sigma2_ewma[], b_strength[], b_regime[];
double b_hma_raw_slope[], b_hma_val[];
double b_returns[], b_mu_rets[], b_sig_rets[], b_atr[], b_lr_sigs[], b_init_vars[], b_shifted_close[];
double b_t1[], b_t2[], b_temp_d[];
// V4: Asymmetric emission + kurtosis-driven jump
double b_mu_bull[], b_mu_bear[], b_kurtosis[];
// V6: True mixture volatility projection
double b_sig_proj[];

// Global variables
int    g_atr_handle = INVALID_HANDLE;
int    g_hma_regime = 0;
double g_strength = 0.0;
double g_hmm_prob = 0.5;
double g_vol_ratio = 1.0;
double g_confidence = 0.0;

// Colors
color C_BULL = clrAqua;
color C_BEAR = C'240,19,19';
color C_NEUT = clrGray;
color C_STR  = C'0,255,136';

//+------------------------------------------------------------------+
//| Custom functions (O(1) Incremental)                              |
//+------------------------------------------------------------------+
// V7: Lanczos Log-Gamma approximation for MQL5 (No built-in MathGamma)
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
    double z = (x - mu) / sig;
    // V7: Include normalization constants for parity with Jump Normal
    // MQL5 Fix: Use custom LogGamma as MathLogGamma/MathGamma are not built-in
    double log_const = LogGamma((nu + 1.0) / 2.0) - LogGamma(nu / 2.0) - 0.5 * MathLog(nu * M_PI);
    return log_const - MathLog(sig) - ((nu + 1.0) / 2.0) * MathLog(1.0 + (z * z) / nu);
}

double LogNormalJump(double x, double sig_jump) {
    if(sig_jump <= 0) sig_jump = 1e-10;
    // V7: Standard Log-Normal likelihood
    return -MathLog(sig_jump) - 0.5 * MathLog(2.0 * M_PI) - 0.5 * MathPow(x / sig_jump, 2.0);
}

// V4 Fix #8: WMA warmup uses expanding simple mean instead of raw src[i]
void CalculateWMA(int rates_total, const double &src[], double &wma_buffer[], int period, int start) {
    if(period < 1) return;
    double weight_sum = period * (period + 1) / 2.0;
    int s = MathMax(0, start);
    for(int i=s; i<rates_total; i++) {
        if(i < period - 1) {
            // Expanding simple mean seed (institutional warmup)
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

// V4 Fix #5: Compute excess kurtosis over rolling window for jump sigma calibration
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
        m2 /= period;
        m4 /= period;
        double variance = m2;
        if(variance < 1e-20) { kurt_buffer[i] = 0; continue; }
        kurt_buffer[i] = (m4 / (variance * variance)) - 3.0;
    }
}

// V4 Fix #4: Conditional EMA for asymmetric emission (positive returns only)
void CalculateConditionalEMA_Pos(int rates_total, const double &src[], double &ema_buffer[], int period, int start) {
    if(period < 1) return;
    double alpha = 2.0 / (period + 1.0);
    int s = MathMax(1, start);
    if(s == 1) ema_buffer[0] = MathMax(src[0], 0.0);
    for(int i=s; i<rates_total; i++) {
        double val = MathMax(src[i], 0.0);
        ema_buffer[i] = val * alpha + ema_buffer[i-1] * (1.0 - alpha);
    }
}

// V4 Fix #4: Conditional EMA for asymmetric emission (negative returns → stored as positive magnitude)
void CalculateConditionalEMA_Neg(int rates_total, const double &src[], double &ema_buffer[], int period, int start) {
    if(period < 1) return;
    double alpha = 2.0 / (period + 1.0);
    int s = MathMax(1, start);
    if(s == 1) ema_buffer[0] = MathAbs(MathMin(src[0], 0.0));
    for(int i=s; i<rates_total; i++) {
        double val = MathAbs(MathMin(src[i], 0.0));
        ema_buffer[i] = val * alpha + ema_buffer[i-1] * (1.0 - alpha);
    }
}

//+------------------------------------------------------------------+
//| Indicator initialization                                         |
//+------------------------------------------------------------------+
int OnInit() {
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
    SetIndexBuffer(13, b_regime_bull,   INDICATOR_DATA);
    SetIndexBuffer(14, b_regime_bear,   INDICATOR_DATA);
    
    SetIndexBuffer(15, b_p1,           INDICATOR_CALCULATIONS);
    SetIndexBuffer(16, b_sigma2_ewma,  INDICATOR_CALCULATIONS);
    SetIndexBuffer(17, b_strength,     INDICATOR_CALCULATIONS);
    SetIndexBuffer(18, b_regime,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(19, b_hma_raw_slope,INDICATOR_CALCULATIONS);
    SetIndexBuffer(20, b_hma_val,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(21, b_returns,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(22, b_mu_rets,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(23, b_sig_rets,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(24, b_atr,           INDICATOR_CALCULATIONS);
    SetIndexBuffer(25, b_lr_sigs,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(26, b_init_vars,     INDICATOR_CALCULATIONS);
    SetIndexBuffer(27, b_shifted_close, INDICATOR_CALCULATIONS);
    SetIndexBuffer(28, b_t1,            INDICATOR_CALCULATIONS);
    SetIndexBuffer(29, b_t2,            INDICATOR_CALCULATIONS);
    SetIndexBuffer(30, b_temp_d,        INDICATOR_CALCULATIONS);
    // V4: New buffers for asymmetric emission + kurtosis
    SetIndexBuffer(31, b_mu_bull,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(32, b_mu_bear,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(33, b_kurtosis,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(34, b_sig_proj,      INDICATOR_CALCULATIONS);

    PlotIndexSetInteger(3, PLOT_ARROW, 225); // Thin Arrow Up
    PlotIndexSetInteger(4, PLOT_ARROW, 226); // Thin Arrow Down
    PlotIndexSetInteger(6, PLOT_ARROW, 233); // Thick Arrow Up (Purple)
    PlotIndexSetInteger(7, PLOT_ARROW, 234); // Thick Arrow Down (Purple)
    for(int i=0; i<8; i++) PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

    g_atr_handle = iATR(_Symbol, _Period, 14);

    IndicatorSetString(INDICATOR_SHORTNAME, "Regime HMM EWMA (5M)");
    
    // V7: CSV parsing with Numerical Stability support (15 columns)
    int handle = FileOpen("HMM_Params_5M.csv", FILE_READ | FILE_CSV | FILE_ANSI, ',');
    if(handle == INVALID_HANDLE) {
        PrintFormat("CRITICAL ERROR: Could NOT open HMM_Params_5M.csv in %s mode. Error %d", 
                    (MQLInfoInteger(MQL_TESTER) ? "TESTER" : "LIVE"), GetLastError());
        return(INIT_FAILED);
    }
    
    if(handle != INVALID_HANDLE) {
        // Read header row (15 columns)
        string cols[15]; for(int i=0; i<15; i++) cols[i] = FileReadString(handle);
        
        bool has_stability = (cols[9] == "MuConf" && cols[14] == "StdSlope");
        
        if(!FileIsEnding(handle)) {
            string vals[15]; for(int i=0; i<15; i++) vals[i] = FileReadString(handle);
            if(StringLen(vals[0]) > 0 && StringLen(vals[1]) > 0) {
                ExtPBull = StringToDouble(vals[0]); ExtPBear = StringToDouble(vals[1]); ExtSlopeT = StringToDouble(vals[2]);
                ExtJumpLambda = StringToDouble(vals[3]); ExtHMMNu = StringToDouble(vals[4]);
                
                // Read ML Weights
                ExtWConf = StringToDouble(vals[5]); ExtWVol = StringToDouble(vals[6]);
                ExtWSlope = StringToDouble(vals[7]); ExtWInter = StringToDouble(vals[8]);
                
                if(has_stability) {
                    ExtMuConf  = StringToDouble(vals[9]);  ExtMuVol  = StringToDouble(vals[10]); ExtMuSlope  = StringToDouble(vals[11]);
                    ExtStdConf = StringToDouble(vals[12]); ExtStdVol = StringToDouble(vals[13]); ExtStdSlope = StringToDouble(vals[14]);
                    if(ExtStdConf < 1e-10) ExtStdConf = 1.0; if(ExtStdVol < 1e-10) ExtStdVol = 1.0; if(ExtStdSlope < 1e-10) ExtStdSlope = 1.0;
                }
                PrintFormat("V7 Loaded 5M: PBull=%.3f λ=%.3f ν=%.2f Weights=[%.2f,%.2f,%.2f,%.2f] Mu=[%.2f,%.2f,%.2f]",
                            ExtPBull, ExtJumpLambda, ExtHMMNu, ExtWConf, ExtWVol, ExtWSlope, ExtWInter, ExtMuConf, ExtMuVol, ExtMuSlope);
            }
        }
        FileClose(handle);
    } else {
        Print("Could not load HMM_Params_5M.csv, using default fallbacks. Error: ", GetLastError());
    }
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Indicator calculation                                            |
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

    int hma_warmup = InpHMALen + (int)MathRound(MathSqrt(InpHMALen)) + 1;
    int min_start = MathMax(hma_warmup, InpLongRunW) + 1;

    int start = prev_calculated - 1;
    if(start < min_start) {
        start = min_start;
        b_p1[0] = 0.5;
        b_sigma2_ewma[0] = 0.0001;
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
    }

    // 0. F_{t-1} Estricto: Congelar estado previo, NUNCA procesar la vela viva
    int calc_limit = rates_total; 

    // V4 Fix #1: CopyBuffer ATR with correct chronological mapping
    int to_copy = calc_limit - start;
    if(to_copy > 0) {
        static double temp_atr[]; ArrayResize(temp_atr, to_copy, 1000);
        if(CopyBuffer(g_atr_handle, 0, 0, to_copy, temp_atr) <= 0) return(0);
        // Reverse: temp_atr[0]=newest → b_atr[calc_limit-1], temp_atr[N-1]=oldest → b_atr[start]
        for(int i=0; i<to_copy; i++) b_atr[start + i] = temp_atr[to_copy - 1 - i];
    }

    // 2. F_{t-1} Parity: Shift the array manually like Python's close.shift(1)
    for(int i = MathMax(0, start); i < calc_limit; i++) {
        b_shifted_close[i] = (i > 0) ? close[i-1] : close[0];
    }

    // 3. Pre-calculate HMA over shifted_close array inside O(1) start bounds
    CalculateHMA(calc_limit, b_shifted_close, b_hma_val, InpHMALen, start);

    // 4. Transform strictly in real-time bounds (incremental returns calculation)
    for(int i = MathMax(2, start); i < calc_limit; i++) {
        b_returns[i] = MathLog(close[i-1] / close[i-2]);
    }

    // 5. Incremental Recalculation of Volatility Components
    CalculateEMA(calc_limit, b_returns, b_mu_rets, InpRetWindow, start);
    CalculateStdev(calc_limit, b_returns, b_sig_rets, InpVolWindow, start);
    CalculateStdev(calc_limit, b_returns, b_lr_sigs, InpLongRunW, start);
    CalculateVariance(calc_limit, b_returns, b_init_vars, InpLongRunW, start);

    // V4 Fix #4: Asymmetric conditional EMAs for bull/bear drift
    CalculateConditionalEMA_Pos(calc_limit, b_returns, b_mu_bull, InpRetWindow, start);
    CalculateConditionalEMA_Neg(calc_limit, b_returns, b_mu_bear, InpRetWindow, start);

    // V4 Fix #5: Kurtosis for calibrated jump sigma
    CalculateKurtosis(calc_limit, b_returns, b_kurtosis, InpLongRunW, start);

    // Ensure HMM prior defaults during warmup range
    for(int i=1; i<start; i++) {
        if(b_p1[i] == 0.0) b_p1[i] = 0.5;
    }

    // --- Main System Loop (Iterates strictly over CLOSED bars) ---
    for(int i=start; i<calc_limit; i++) {
        double ret = b_returns[i];
        // V4 Fix #4: Asymmetric emission — separate bull/bear drift
        double mu_bull = MathMax(b_mu_bull[i], 1e-10);
        double mu_bear = MathMax(b_mu_bear[i], 1e-10);
        double sig_t = MathMax(b_sig_rets[i], 1e-10);

        // --- HMM Hamilton Filter (Merton Jump-Diffusion Mixture) ---
        double prev_p1 = (i > 0) ? b_p1[i-1] : 0.5;
        double p1_pred = ExtPBull * prev_p1 + (1.0 - ExtPBear) * (1.0 - prev_p1);
        double p0_pred = 1.0 - p1_pred;

        // V4 Fix #4: Asymmetric likelihood
        double ll1 = LogTStudent(ret,  mu_bull, sig_t, ExtHMMNu);
        double ll0 = LogTStudent(ret, -mu_bear, sig_t, ExtHMMNu);
        
        // V4 Fix #5: Jump component with kurtosis-calibrated sigma
        double excess_kurt = b_kurtosis[i];
        double kurt_mult = MathSqrt(MathMax(excess_kurt + 3.0, 3.0));
        kurt_mult = MathMax(2.0, MathMin(10.0, kurt_mult));
        double sig_jump = MathMax(b_lr_sigs[i] * kurt_mult, 1e-10);
        double ll_jump = LogNormalJump(ret, sig_jump);
        double ll_max = MathMax(MathMax(ll1, ll0), ll_jump);
        
        // Mixture: (1-λ)*t_student + λ*Normal_jump
        double lik1_mix = (1.0 - ExtJumpLambda) * MathExp(ll1 - ll_max) + ExtJumpLambda * MathExp(ll_jump - ll_max);
        double lik0_mix = (1.0 - ExtJumpLambda) * MathExp(ll0 - ll_max) + ExtJumpLambda * MathExp(ll_jump - ll_max);
        
        double lik1 = p1_pred * lik1_mix;
        double lik0 = p0_pred * lik0_mix;
        double norm_f = lik1 + lik0;

        double prob = norm_f > 1e-14 ? lik1 / norm_f : p1_pred;
        b_p1[i] = MathMax(1e-4, MathMin(0.9999, prob)); // V4 Ergodicity clamp
        double hmm_prob = b_p1[i];

        // V7 Fix #11: Complete Mixture Volatility Projection (Law of Total Variance)
        // Var_mix = E[Var(X|S)] + Var(E[X|S])
        // 1. E[Var(X|S)] = (1-λ)*(sig_t^2 * ν/(ν-2)) + λ*sig_jump^2
        // 2. Var(E[X|S]) = p(1-p) * ( (1-λ)*μ_bull - -(1-λ)*μ_bear )^2 
        //                = p(1-p) * (1-λ)^2 * (μ_bull + μ_bear)^2
        double t_scale = ExtHMMNu / (ExtHMMNu - 2.0);
        double var_t = (sig_t * sig_t) * t_scale;
        double var_j = (sig_jump * sig_jump);
        
        // V7 Fix #12: Exhaustive Emission Variance (Mean-Displacement term)
        // Var(X|S) = (1-λ)*var_t + λ*var_j + λ*(1-λ)*(μ - 0)^2
        double mu_s = (hmm_prob > 0.5) ? mu_bull : -mu_bear;
        double e_var_cond = (1.0 - ExtJumpLambda) * var_t + ExtJumpLambda * var_j + ExtJumpLambda * (1.0 - ExtJumpLambda) * (mu_s * mu_s);
        
        double var_e_cond = hmm_prob * (1.0 - hmm_prob) * MathPow(1.0 - ExtJumpLambda, 2.0) * MathPow(mu_bull + mu_bear, 2.0);
        
        b_sig_proj[i] = MathSqrt(MathMax(e_var_cond + var_e_cond, 1e-12));
        
        double confidence = MathAbs(hmm_prob - 0.5) * 2.0;

        // --- HMA Slope Regime ---
        double hma_val = b_hma_val[i];
        double hma_val_prev = b_hma_val[MathMax(i-InpSlopeN, 0)];
        b_hma_raw_slope[i] = (hma_val - hma_val_prev) / (double)InpSlopeN;

        double slope_sum = 0;
        for(int j=0; j<InpSlopeS; j++) slope_sum += b_hma_raw_slope[MathMax(i-j, 0)];
        double hma_slope = slope_sum / InpSlopeS;

        double hma_thresh_abs = b_atr[MathMax(i-1, 0)] * ExtSlopeT;
        int hma_regime = hma_slope > hma_thresh_abs ? 1 : hma_slope < -hma_thresh_abs ? -1 : 0;

        // --- EWMA RiskMetrics ---
        double innov = b_returns[i] - b_mu_rets[i];

        if(i < InpLongRunW) b_sigma2_ewma[i] = MathMax(b_init_vars[i], 1e-10);
        else b_sigma2_ewma[i] = (1.0 - InpLambda) * (innov * innov) + InpLambda * b_sigma2_ewma[MathMax(i-1,0)];

        double ewma_sigma = MathMax(MathSqrt(MathMax(b_sigma2_ewma[i], 0.0)), 1e-10);
        double lr_sigma = MathMax(b_lr_sigs[i], 1e-10);
        double vol_ratio = ewma_sigma / lr_sigma;

        // --- V7 ML Strength Score (Ridge + Standardization) ---
        double conf = MathAbs(hmm_prob - 0.5) * 2.0;
        double hma_slope_mag = MathAbs(hma_slope) / MathMax(hma_thresh_abs / (ExtSlopeT > 0 ? ExtSlopeT : 0.0273), 1e-10);
        
        // Z-score standardization: (X - mu) / std
        double s_conf  = (conf - ExtMuConf) / ExtStdConf;
        double s_vol   = (vol_ratio - ExtMuVol) / ExtStdVol;
        double s_slope = (hma_slope_mag - ExtMuSlope) / ExtStdSlope;
        
        // Logistic Ensemble: Prob(Success) = 1 / (1 + exp(-z))
        double z = ExtWConf * s_conf + ExtWVol * s_vol + ExtWSlope * s_slope + ExtWInter;
        b_strength[i] = 1.0 / (1.0 + MathExp(-z));
        
        g_strength = b_strength[i];
        g_hmm_prob = hmm_prob;
        g_vol_ratio = vol_ratio;
        g_confidence = conf;

        // --- Combined Regime ---
        bool hmm_bull = hmm_prob > InpThresh;
        bool hmm_bear = hmm_prob < (1.0 - InpThresh);
        bool hma_bull_ok = !InpHMAReq || hma_regime > 0;
        bool hma_bear_ok = !InpHMAReq || hma_regime < 0;

        int regime = (hmm_bull && hma_bull_ok) ? 1 : (hmm_bear && hma_bear_ok) ? -1 : 0;
        b_regime[i] = (double)regime;

        // --- Color index: 0=Aqua(Bull), 1=Red(Bear), 2=Gray(Neutral) ---
        double clr_idx = (regime == 1) ? 0.0 : (regime == -1) ? 1.0 : 2.0;

        // --- HMA Color Line Buffers ---
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

        // --- Regime Candles (visual only — uses current bar OHLC, not shifted) ---
        if(InpShowBg) {
            b_open[i] = open[i]; b_high[i] = high[i]; b_low[i] = low[i]; b_close[i] = close[i];
            b_candle_clr[i] = clr_idx;
        }

        // --- Entry Signals ---
        b_to_bull[i] = (regime == 1 && b_regime[MathMax(i-1,0)] != 1 && b_strength[i] > InpMinStrength) ? low[i] - 10 * _Point : EMPTY_VALUE;
        b_to_bear[i] = (regime == -1 && b_regime[MathMax(i-1,0)] != -1 && b_strength[i] > InpMinStrength) ? high[i] + 10 * _Point : EMPTY_VALUE;

        // --- Regime Change Arrows (Purple) ---
        if(InpShowRegArr && i > 0) {
            int prev_regime = (int)b_regime[i-1];
            bool regime_changed = (regime != prev_regime);
            b_regime_bull[i] = (regime_changed && regime == 1)  ? low[i]  - 20 * _Point : EMPTY_VALUE;
            b_regime_bear[i] = (regime_changed && regime == -1) ? high[i] + 20 * _Point : EMPTY_VALUE;
        } else {
            b_regime_bull[i] = EMPTY_VALUE;
            b_regime_bear[i] = EMPTY_VALUE;
        }

        if(i == calc_limit - 1) {
            g_hma_regime = hma_regime; g_strength = b_strength[i]; g_hmm_prob = hmm_prob;
            g_vol_ratio = vol_ratio; g_confidence = conf;
        }
    }

    if(InpShowTbl) DrawDashboard();
    return(rates_total);
}

//+------------------------------------------------------------------+
//| Dashboard Drawing (Top Left by default)                          |
//+------------------------------------------------------------------+
void DrawDashboard() {
    int x_off = 20, y_off = 30;
    ENUM_BASE_CORNER corner = CORNER_LEFT_UPPER;
    if(InpTblPos == "Top Right") corner = CORNER_RIGHT_UPPER;
    else if(InpTblPos == "Bottom Right") corner = CORNER_RIGHT_LOWER;
    else if(InpTblPos == "Bottom Left") corner = CORNER_LEFT_LOWER;

    string reg_str = (g_hmm_prob > InpThresh) ? "▲ BULL " : (g_hmm_prob < (1.0 - InpThresh)) ? "▼ BEAR " : "● NEUT ";
    color  reg_col = (g_hmm_prob > InpThresh) ? C_BULL  : (g_hmm_prob < (1.0 - InpThresh)) ? C_BEAR  : C_NEUT;

    CreateLabel("HMM_Title",    "── HMM EWMA 5M ──",                                     x_off, y_off,      corner, 9,  clrDimGray);
    CreateLabel("HMM_Regime",   "Regime:   " + reg_str,                                   x_off, y_off + 18, corner, 10, reg_col);
    CreateLabel("HMM_Strength", "Strength: " + DoubleToString(g_strength * 100, 1) + "%", x_off, y_off + 36, corner, 10, g_strength > 0.75 ? C_STR : clrWhite);
    CreateLabel("HMM_Prob",     "P(bull):  " + DoubleToString(g_hmm_prob, 3),             x_off, y_off + 54, corner, 10, clrWhite);
    CreateLabel("HMM_Vol",      "Vol Ratio: " + DoubleToString(g_vol_ratio, 2) + "x",    x_off, y_off + 72, corner, 10, g_vol_ratio > 1.5 ? clrOrangeRed : clrWhite);
}

void CreateLabel(string name, string text, int x, int y, ENUM_BASE_CORNER corner, int size, color col) {
    if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
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
}
//+------------------------------------------------------------------+
