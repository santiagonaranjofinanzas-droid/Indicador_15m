//+------------------------------------------------------------------+
//|                                     Black_Knight_Aut_System_EA_V30_0.mq5        |
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
   OPERATING CRITERIA (Black_Knight_Aut_System Quantum V30.0):
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

input string G2B = "─── Institutional Risk Throttle ───";
input bool   InpUseHealthRisk   = true;   // Ajustar riesgo por Health score
input double InpHealthHardStop  = 0.30;   // No trade debajo de este health
input double InpHealthWarn       = 0.60;  // Zona de reducción de riesgo
input double InpRiskFloorMult    = 0.25;  // Multiplicador mínimo de riesgo
input double InpRiskCeilMult     = 1.00;  // Multiplicador máximo de riesgo

input string G2C = "─── Institutional Meta-Execution ───";
input bool   InpUseMetaExecution  = true;   // Activar meta-labeling de ejecución
input double InpExecMinHealthy    = 0.55;   // Score mínimo estado healthy
input double InpExecMinWarning    = 0.70;   // Score mínimo estado warning
input double InpExecSpreadPenalty = 0.35;   // Penalización de spread relativo
input double InpTelemetryEmaAlpha = 0.20;   // EMA de telemetría de resultados

input string G3 = "─── Indicator Link ───";
input string InpIndiPath      = "Black_Knight_Aut_System_MT5\\Black_Knight_Aut_System_Engine"; // V8.1 Required

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
double         g_last_health = 1.0;
double         g_last_valscore = 1.0;
double         g_last_exec_score = 1.0;
double         g_last_risk_mult = 1.0;
double         g_last_state_risk_mult = 1.0;
ulong          g_partial_done_ticket = 0;
double         g_edge_ema = 0.0;
double         g_win_ema = 0.5;
datetime       g_last_hist_scan = 0;
string         g_last_state = "HEALTHY";
string         g_status = "SCANNING";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    if(!m_symbol.Name(_Symbol)) return(INIT_FAILED);
    m_trade.SetExpertMagicNumber(InpMagic);
    g_last_hist_scan = TimeCurrent() - 86400;
    
    g_handle = iCustom(_Symbol, _Period, InpIndiPath);
    if(g_handle == INVALID_HANDLE) {
        Print("CRITICAL ERROR: Could NOT load Quantum Indicator: ", InpIndiPath);
        return(INIT_FAILED);
    }
    
    Print("Black_Knight_Aut_System Master EA V30.0 Initialized successfully.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    IndicatorRelease(g_handle);
    ObjectsDeleteAll(0, "BK_EA_");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    UpdateExecutionTelemetry();

    // 1. Fetch Signal on closed bar (shift=1) to avoid look-ahead in execution
    const int decision_shift = 1;
    double regime_arr[1], strength_arr[1], prob_arr[1], sig_arr[1], health_arr[1], valscore_arr[1];
    if(CopyBuffer(g_handle, 18, decision_shift, 1, regime_arr) <= 0) return;
    if(CopyBuffer(g_handle, 17, decision_shift, 1, strength_arr) <= 0) return;
    if(CopyBuffer(g_handle, 15, decision_shift, 1, prob_arr) <= 0) return;
    if(CopyBuffer(g_handle, 32, decision_shift, 1, sig_arr) <= 0) return; // Varianza Proyectada
    if(CopyBuffer(g_handle, 38, decision_shift, 1, health_arr) <= 0) health_arr[0] = 1.0;
    if(CopyBuffer(g_handle, 40, decision_shift, 1, valscore_arr) <= 0) valscore_arr[0] = 1.0;
    
    int    regime   = (int)regime_arr[0];
    double strength = strength_arr[0];
    double prob     = (prob_arr[0] > 1.0) ? 0.5 : prob_arr[0];
    double sig_proj = sig_arr[0];
    double health   = MathMax(0.0, MathMin(1.0, health_arr[0]));
    double valscore = MathMax(0.0, MathMin(1.0, valscore_arr[0]));
    
    g_last_strength = strength;
    g_last_hmm      = prob;
    g_last_sig_proj = sig_proj;
    g_last_health   = health;
    g_last_valscore = valscore;

    int state = DetermineSystemState(health, valscore);
    g_last_state = StateToString(state);

    g_last_risk_mult = GetRiskMultiplier(health);
    g_last_state_risk_mult = StateRiskMultiplier(state);

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
    
    if(!has_position) {
        g_status = "SCANNING MARKET";
        g_partial_done_ticket = 0;
    }

    // 3. Trade Entry (Only on New Bar)
    if(IsNewBar()) {
        if(!has_position && state > 0 && health >= InpHealthHardStop && regime != 0 && strength >= InpMinStrength) {
            double exec_score = ComputeExecutionScore(strength, health, valscore, sig_proj);
            g_last_exec_score = exec_score;

            double exec_min = (state == 2) ? InpExecMinHealthy : InpExecMinWarning;
            if(!InpUseMetaExecution || exec_score >= exec_min) {
                ExecuteOrder(regime, strength, sig_proj, health, state);
            }
        }
    }
    
    DrawDashboard();
}

//+------------------------------------------------------------------+
//| Order Execution (Volatility Targeting)                           |
//+------------------------------------------------------------------+
void ExecuteOrder(int type, double strength, double sig_proj, double health, int state) {
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
    
    double risk_eff = InpRiskPercent * GetRiskMultiplier(health) * StateRiskMultiplier(state);
    double lot = CalculateLot(risk_eff, sl_pts);
    lot = MathMin(InpMaxLot, MathMax(0.01, lot));
    
    ENUM_ORDER_TYPE ord_type = (type == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    string comment = "Q-Vol [σ:" + DoubleToString(sig_proj*100, 2) + "%|H:" + DoubleToString(health*100.0, 0) + "%]";
    
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
    if(g_partial_done_ticket == m_position.Ticket()) return;

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
                g_partial_done_ticket = m_position.Ticket();
                Print("Black_Knight_Aut_System Quantum: Partial Executed. Risk Eliminated.");
            }
        }
    }
}

double GetRiskMultiplier(double health) {
    if(!InpUseHealthRisk) return 1.0;

    double h = MathMax(0.0, MathMin(1.0, health));
    if(h >= InpHealthWarn) {
        return InpRiskCeilMult;
    }

    double denom = MathMax(InpHealthWarn - InpHealthHardStop, 1e-6);
    double t = MathMax(0.0, MathMin(1.0, (h - InpHealthHardStop) / denom));
    return InpRiskFloorMult + t * (InpRiskCeilMult - InpRiskFloorMult);
}

double StateRiskMultiplier(int state) {
    if(state >= 2) return 1.00;
    if(state == 1) return 0.60;
    return 0.25;
}

int DetermineSystemState(double health, double valscore) {
    if(health < InpHealthHardStop || valscore < 0.45) return 0; // Defensive
    if(health < InpHealthWarn || valscore < 0.65) return 1;     // Warning
    return 2;                                                    // Healthy
}

string StateToString(int state) {
    if(state >= 2) return "HEALTHY";
    if(state == 1) return "WARNING";
    return "DEFENSIVE";
}

double ComputeExecutionScore(double strength, double health, double valscore, double sig_proj) {
    double spread_pts = (m_symbol.Ask() - m_symbol.Bid()) / MathMax(m_symbol.Point(), 1e-12);
    double ref_price = (m_symbol.Ask() + m_symbol.Bid()) * 0.5;
    double exp_sl_pts = (ref_price * MathMax(sig_proj, 1e-6) * InpVolMultiplier) / MathMax(m_symbol.Point(), 1e-12);
    exp_sl_pts = MathMax(1.0, exp_sl_pts);

    double spread_ratio = spread_pts / exp_sl_pts;
    double micro_score = MathMax(0.0, MathMin(1.0, 1.0 - InpExecSpreadPenalty * spread_ratio));

    double edge_norm = MathMax(0.0, MathMin(1.0, 0.5 + 0.5 * g_edge_ema));
    double telemetry_score = 0.60 * MathMax(0.0, MathMin(1.0, g_win_ema)) + 0.40 * edge_norm;
    double signal_score = 0.40 * MathMax(0.0, MathMin(1.0, strength))
                        + 0.30 * MathMax(0.0, MathMin(1.0, health))
                        + 0.30 * MathMax(0.0, MathMin(1.0, valscore));

    return MathMax(0.0, MathMin(1.0, 0.50 * signal_score + 0.30 * micro_score + 0.20 * telemetry_score));
}

void UpdateExecutionTelemetry() {
    datetime now_t = TimeCurrent();
    if(!HistorySelect(g_last_hist_scan, now_t)) return;

    int deals = HistoryDealsTotal();
    datetime max_seen = g_last_hist_scan;

    for(int i=0; i<deals; i++) {
        ulong deal_ticket = HistoryDealGetTicket(i);
        if(deal_ticket == 0) continue;

        datetime dt = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
        if(dt <= g_last_hist_scan) continue;

        string sym = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
        long magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
        long entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
        if(sym != _Symbol || magic != InpMagic || entry != DEAL_ENTRY_OUT) continue;

        double pnl = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                   + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                   + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

        double balance = MathMax(AccountInfoDouble(ACCOUNT_BALANCE), 1.0);
        double edge = MathMax(-1.0, MathMin(1.0, pnl / (0.01 * balance)));
        double win = (pnl > 0.0) ? 1.0 : 0.0;

        g_edge_ema = (1.0 - InpTelemetryEmaAlpha) * g_edge_ema + InpTelemetryEmaAlpha * edge;
        g_win_ema  = (1.0 - InpTelemetryEmaAlpha) * g_win_ema  + InpTelemetryEmaAlpha * win;

        if(dt > max_seen) max_seen = dt;
    }

    g_last_hist_scan = max_seen;
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
    string prefix = "BK_EA_";
    int y = InpBase_Y;
    int x = InpBase_X;
    
    color str_col = (g_last_strength >= InpMinStrength) ? clrSpringGreen : clrTomato;
    color hmm_col = (g_last_hmm > 0.65) ? clrDeepSkyBlue : (g_last_hmm < 0.35) ? clrTomato : clrSlateGray;

    CreateLabel(prefix+"T", "── Black_Knight_Aut_System MASTER V30.0 ──", x, y,      10, clrGray);
    CreateLabel(prefix+"S", "System Status: " + g_status,         x, y+18,  10, clrWhite);
    CreateLabel(prefix+"H", "Market Direction: " + DoubleToString(g_last_hmm, 3), x, y+36, 10, hmm_col);
    CreateLabel(prefix+"M", "Master Strength: " + DoubleToString(g_last_strength*100, 1) + "%", x, y+54, 10, str_col);
    CreateLabel(prefix+"V", "σ Projected:  " + DoubleToString(g_last_sig_proj*100, 3) + "%", x, y+72, 10, clrDimGray);
    CreateLabel(prefix+"R", "Risk Allocation:  " + DoubleToString(InpRiskPercent * g_last_risk_mult, 2) + "%", x, y+90, 10, clrWhite);
    CreateLabel(prefix+"Q", "Health Score:  " + DoubleToString(g_last_health*100.0, 1) + "%", x, y+108, 10, g_last_health<InpHealthWarn?clrTomato:clrSilver);
    CreateLabel(prefix+"E", "Exec Score:   " + DoubleToString(g_last_exec_score*100.0, 1) + "%", x, y+126, 10, g_last_exec_score<InpExecMinHealthy?clrTomato:clrSilver);
    CreateLabel(prefix+"W", "Val / State:  " + DoubleToString(g_last_valscore*100.0, 1) + "% / " + g_last_state, x, y+144, 10, g_last_state=="HEALTHY"?clrSpringGreen:(g_last_state=="WARNING"?clrGold:clrTomato));
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
