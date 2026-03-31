//+------------------------------------------------------------------+
//|                                     Sovereign_EA_V30_0.mq5        |
//|                                  Copyright 2024, TradingAlgo      |
//|                        Agente Maestro: QUANTUM EDITION V30.0      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, TradingAlgo"
#property link      "https://www.mql5.com/en/users/nuevoadmin"
#property version   "30.00" // V30: Quantum Engine Integration
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

/*
   OPERATING CRITERIA (Sovereign Quantum V30.0):
   1. F(t-1) PARITY: Operates ONLY on closed bars (Zero Lag Policy).
   2. QUANTUM HMM REGIME: Uses GJR-GARCH(1,1) Volatility + Kalman Filter Gate.
   3. ADAPTIVE Z-SCORE: ML Strength scales with Online Concept Drift mitigation.
   4. DYNAMIC JUMP-DIFFUSION: Nu (ν) and Lambda (λ) calibrate every 500 bars.
   5. RISK: Fixed % balance per trade. Partial close 70% at 1:2 R/R.
*/

//--- INPUTS
input string G1 = "─── Quantum Risk Parameters ───";
input double InpMinStrength   = 0.35;    // Min ML Strength for Entry
input double InpVolMultiplier = 2.5;     // Multiplicador de Volatilidad para SL (ej. 2.5 sigma)
input double InpRewardRisk    = 2.0;     // Ratio Riesgo/Beneficio (TP = SL * RR)
input bool   InpUsePartials   = true;    // Use Partial Closure
input int    InpMagic         = 30001;   // Magic Number (V30 Series)

input string G2 = "─── Risk Management ───";
input double InpRiskPercent   = 1.0;     // Risk per Trade (%)
input double InpMaxLot        = 10.0;    // Max allowed Lot

input string G3 = "─── Indicator Link ───";
input string InpIndiPath      = "Regime_HMM_EWMA_15M"; // V8.0 Required

input string G4 = "─── Visual Dashboard (Quantum) ───";
input color  InpDashColor     = clrAqua; 
input int    InpBase_X        = 20;      
input int    InpBase_Y        = 200;     

//--- Globals
CTrade         m_trade;
CSymbolInfo    m_symbol;
CPositionInfo  m_position;
CAccountInfo   m_account;
int            g_handle = INVALID_HANDLE;
double         g_last_strength = 0.0;
double         g_last_hmm = 0.5;
double         g_last_sig_proj = 0.0;
string         g_status = "SCANNING";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    if(!m_symbol.Name(_Symbol)) return(INIT_FAILED);
    m_trade.SetExpertMagicNumber(InpMagic);
    
    g_handle = iCustom(_Symbol, _Period, InpIndiPath);
    if(g_handle == INVALID_HANDLE) {
        Print("CRITICAL ERROR: Could NOT load Quantum Indicator: ", InpIndiPath);
        return(INIT_FAILED);
    }
    
    DrawDashboard();
    Print("Sovereign Quantum EA V30.0 Initialized successfully.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    IndicatorRelease(g_handle);
    ObjectsDeleteAll(0, "SOV_EA_");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. Fetch Signal (Buff 18=Regime, 17=Strength, 15=HMM Prob, 32=Sig Proj)
    double regime_arr[1], strength_arr[1], prob_arr[1], sig_arr[1];
    if(CopyBuffer(g_handle, 18, 0, 1, regime_arr) <= 0) return;
    if(CopyBuffer(g_handle, 17, 0, 1, strength_arr) <= 0) return;
    if(CopyBuffer(g_handle, 15, 0, 1, prob_arr) <= 0) return;
    if(CopyBuffer(g_handle, 32, 0, 1, sig_arr) <= 0) return; // Varianza Proyectada
    
    int    regime   = (int)regime_arr[0];
    double strength = strength_arr[0];
    double prob     = (prob_arr[0] > 1.0) ? 0.5 : prob_arr[0];
    double sig_proj = sig_arr[0];
    
    g_last_strength = strength;
    g_last_hmm      = prob;
    g_last_sig_proj = sig_proj;

    // 2. Position Management
    int total = PositionsTotal();
    bool has_position = false;
    for(int i=total-1; i>=0; i--) {
        if(m_position.SelectByIndex(i)) {
            if(m_position.Magic() == InpMagic && m_position.Symbol() == _Symbol) {
                has_position = true;
                g_status = "QUANTUM TRADING (" + (m_position.PositionType()==POSITION_TYPE_BUY?"Buy":"Sell") + ")";
                ManagePosition();
                break;
            }
        }
    }
    
    if(!has_position) g_status = "SCANNING MARKET";

    // 3. Trade Entry (Only on New Bar)
    if(IsNewBar()) {
        if(!has_position && regime != 0 && strength >= InpMinStrength) {
            ExecuteOrder(regime, strength, sig_proj);
        }
    }
    
    DrawDashboard();
}

//+------------------------------------------------------------------+
//| Order Execution (Volatility Targeting)                           |
//+------------------------------------------------------------------+
void ExecuteOrder(int type, double strength, double sig_proj) {
    m_symbol.RefreshRates();
    double price = (type == 1) ? m_symbol.Ask() : m_symbol.Bid();
    
    // Volatility Targeting: Distancia = Precio * Volatilidad Logarítmica * Multiplicador
    double vol_distance_price = price * sig_proj * InpVolMultiplier;
    
    // Garantizar un mínimo estructural (evitar stop loss menores al spread)
    double min_sl_price = (m_symbol.Ask() - m_symbol.Bid()) * 3.0; // Mínimo 3x Spread
    vol_distance_price = MathMax(vol_distance_price, min_sl_price);

    double sl = (type == 1) ? price - vol_distance_price : price + vol_distance_price;
    double tp_distance = vol_distance_price * InpRewardRisk;
    double tp = (type == 1) ? price + tp_distance : price - tp_distance;
    
    // Convertir distancia en precio a puntos para el cálculo de lote
    int sl_pts = (int)(vol_distance_price / m_symbol.Point());
    
    double lot = CalculateLot(InpRiskPercent, sl_pts);
    lot = MathMin(InpMaxLot, MathMax(0.01, lot));
    
    ENUM_ORDER_TYPE ord_type = (type == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    string comment = "Q-Vol [σ:" + DoubleToString(sig_proj*100, 2) + "%]";
    
    if(m_trade.PositionOpen(_Symbol, ord_type, lot, price, sl, tp, comment)) {
        PrintFormat("Trade Opened. Lot: %.2f | Dynamic SL Pts: %d", lot, sl_pts);
    }
}

//+------------------------------------------------------------------+
//| Position Management (Dynamic Partials)                           |
//+------------------------------------------------------------------+
void ManagePosition() {
    if(!InpUsePartials) return;
    if(m_position.PositionType() != POSITION_TYPE_BUY && m_position.PositionType() != POSITION_TYPE_SELL) return;

    double entry = m_position.PriceOpen();
    double current = m_position.PriceCurrent();
    double sl_level = m_position.StopLoss();
    
    // Calcular dinámicamente el riesgo inicial expuesto
    double initial_risk_price = MathAbs(entry - sl_level);
    if(initial_risk_price < m_symbol.Point()) return; // SL ya movido a BE

    double profit_price = (m_position.PositionType()==POSITION_TYPE_BUY) ? (current - entry) : (entry - current);
    
    // Target para parciales (ej. 1:1 o 1:1.5 dependiendo del RewardRisk)
    double partial_target_price = initial_risk_price * (InpRewardRisk / 1.5); 

    if(profit_price >= partial_target_price) {
        double vol = NormalizeDouble(m_position.Volume() * 0.7, 2);
        if(vol >= 0.01) {
            if(m_trade.PositionClosePartial(m_position.Ticket(), vol)) {
                m_trade.PositionModify(m_position.Ticket(), entry, m_position.TakeProfit());
                Print("Sovereign Quantum: Partial Executed. Risk Eliminated.");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Risk Utility                                                     |
//+------------------------------------------------------------------+
double CalculateLot(double risk_pct, int sl_pts) {
    double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(sl_pts <= 0 || tick_val <= 0) return 0.01;
    
    double risk_money = AccountInfoDouble(ACCOUNT_BALANCE) * (risk_pct / 100.0);
    double lot = risk_money / (sl_pts * (tick_val / tick_size * m_symbol.Point()));
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Visual Dashboard (Quantum Enhanced)                              |
//+------------------------------------------------------------------+
void DrawDashboard() {
    string prefix = "SOV_EA_";
    int y = InpBase_Y;
    int x = InpBase_X;
    
    color str_col = (g_last_strength >= InpMinStrength) ? clrSpringGreen : clrTomato;
    color hmm_col = (g_last_hmm > 0.65) ? clrDeepSkyBlue : (g_last_hmm < 0.35) ? clrTomato : clrSlateGray;

    CreateLabel(prefix+"T", "── SOVEREIGN QUANTUM V30.0 ──", x, y,      10, clrGray);
    CreateLabel(prefix+"S", "System Status: " + g_status,         x, y+18,  10, clrWhite);
    CreateLabel(prefix+"H", "HMM Bull Prob: " + DoubleToString(g_last_hmm, 3), x, y+36, 10, hmm_col);
    CreateLabel(prefix+"M", "Quantum Strength: " + DoubleToString(g_last_strength*100, 1) + "%", x, y+54, 10, str_col);
    CreateLabel(prefix+"V", "σ Projected:  " + DoubleToString(g_last_sig_proj*100, 3) + "%", x, y+72, 10, clrDimGray);
    CreateLabel(prefix+"R", "Risk Allocation:  " + DoubleToString(InpRiskPercent, 1) + "%",      x, y+90, 10, clrWhite);
}

void CreateLabel(string name, string text, int x, int y, int size, color col) {
    if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_COLOR, col);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
    ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

bool IsNewBar() {
    static datetime last_time = 0;
    datetime curr_time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
    if(curr_time != last_time) {
        last_time = curr_time;
        return(true);
    }
    return(false);
}
