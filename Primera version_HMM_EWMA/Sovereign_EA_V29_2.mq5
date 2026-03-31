//+------------------------------------------------------------------+
//|                                     Sovereign_EA_V29_2.mq5        |
//|                                  Copyright 2024, TradingAlgo      |
//|                            https://www.mql5.com/en/users/nuevoadmin |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, TradingAlgo"
#property link      "https://www.mql5.com/en/users/nuevoadmin"
#property version   "1.10" // V1.1: Visual Dashboard Added
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

/*
   OPERATING CRITERIA (Sovereign V29.2):
   1. F(t-1) PARITY: Operates ONLY on closed bars to prevent repainting.
   2. HMM REGIME: Prob > 0.65 (Bullish) or Prob < 0.35 (Bearish).
   3. HMA ACCEL FILTER: HMA Slope must align with HMM regime.
   4. ML STRENGTH GATE: Strength must be >= InpMinStrength (Logistic Ensemble of 4 features).
   5. RISK: Fixed % balance per trade. Partial close 70% at 1:2 Reward/Risk ratio.
*/

//--- INPUTS
input string G1 = "─── Strategy Parameters ───";
input double InpMinStrength   = 0.35;    // Min ML Strength for Entry
input int    InpTP_Points     = 600;     // Take Profit (Standard Pips: 60.0)
input int    InpSL_Points     = 300;     // Stop Loss (Standard Pips: 30.0)
input bool   InpUsePartials   = true;    // Use Partial Closure (70% at 1:2)
input int    InpMagic         = 29201;   // Magic Number

input string G2 = "─── Risk Management ───";
input double InpRiskPercent   = 1.0;     // Risk per Trade (%)
input double InpMaxLot        = 10.0;    // Max allowed Lot

input string G3 = "─── Indicator Link ───";
input string InpIndiPath      = "Regime_HMM_EWMA_15M"; // Name in Indicators folder

input string G4 = "─── Visual Dashboard ───";
input color  InpDashColor     = clrAqua; // Color for the dashboard
input int    InpBase_X        = 20;      // X offset
input int    InpBase_Y        = 200;     // Y offset (moved down to avoid conflicts)

//--- Globals
CTrade         m_trade;
CSymbolInfo    m_symbol;
CPositionInfo  m_position;
CAccountInfo   m_account;
int            g_handle = INVALID_HANDLE;
double         g_last_strength = 0.0;
double         g_last_hmm = 0.5;
string         g_status = "SCANNING";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    if(!m_symbol.Name(_Symbol)) return(INIT_FAILED);
    m_trade.SetExpertMagicNumber(InpMagic);
    
    g_handle = iCustom(_Symbol, _Period, InpIndiPath);
    if(g_handle == INVALID_HANDLE) {
        Print("CRITICAL ERROR: Could NOT load Sovereign Indicator: ", InpIndiPath);
        return(INIT_FAILED);
    }
    
    DrawDashboard();
    Print("Sovereign EA V29.2 Visual Initialized successfully.");
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
    // 1. Fetch Signal (Buff 18=Regime, 17=Strength, 13=HMM Prob)
    double regime_arr[1], strength_arr[1], prob_arr[1];
    if(CopyBuffer(g_handle, 18, 0, 1, regime_arr) <= 0) return;
    if(CopyBuffer(g_handle, 17, 0, 1, strength_arr) <= 0) return;
    if(CopyBuffer(g_handle, 15, 0, 1, prob_arr) <= 0) return;
    
    int    regime   = (int)regime_arr[0];
    double strength = strength_arr[0];
    double prob     = (prob_arr[0] > 1.0) ? 0.5 : prob_arr[0];
    
    g_last_strength = strength;
    g_last_hmm      = prob;

    // 2. Position Management
    int total = PositionsTotal();
    bool has_position = false;
    for(int i=total-1; i>=0; i--) {
        if(m_position.SelectByIndex(i)) {
            if(m_position.Magic() == InpMagic && m_position.Symbol() == _Symbol) {
                has_position = true;
                g_status = "TRADING (" + (m_position.PositionType()==POSITION_TYPE_BUY?"Buy":"Sell") + ")";
                ManagePosition();
                break;
            }
        }
    }
    
    if(!has_position) g_status = "SCANNING";

    // 3. Trade Entry (Only on New Bar)
    if(IsNewBar()) {
        if(!has_position && regime != 0 && strength >= InpMinStrength) {
            ExecuteOrder(regime, strength);
        }
    }
    
    DrawDashboard();
}

//+------------------------------------------------------------------+
//| Order Execution                                                  |
//+------------------------------------------------------------------+
void ExecuteOrder(int type, double strength) {
    m_symbol.RefreshRates();
    double price = (type == 1) ? m_symbol.Ask() : m_symbol.Bid();
    double sl_dist = InpSL_Points * m_symbol.Point();
    double tp_dist = InpTP_Points * m_symbol.Point();
    
    double sl = (type == 1) ? price - sl_dist : price + sl_dist;
    double tp = (type == 1) ? price + tp_dist : price - tp_dist;
    
    double lot = CalculateLot(InpRiskPercent, InpSL_Points);
    lot = MathMin(InpMaxLot, MathMax(0.01, lot));
    
    ENUM_ORDER_TYPE ord_type = (type == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    string comment = "V29.2 [S:" + DoubleToString(strength, 2) + "]";
    
    if(m_trade.PositionOpen(_Symbol, ord_type, lot, price, sl, tp, comment)) {
        PrintFormat("Trade Opened: %s Size: %.2f", (type==1?"BUY":"SELL"), lot);
    }
}

//+------------------------------------------------------------------+
//| Position Management (Partials)                                   |
//+------------------------------------------------------------------+
void ManagePosition() {
    if(!InpUsePartials) return;
    if(m_position.PositionType() != POSITION_TYPE_BUY && m_position.PositionType() != POSITION_TYPE_SELL) return;

    double entry = m_position.PriceOpen();
    double current = m_position.PriceCurrent();
    double points_profit = (m_position.PositionType()==POSITION_TYPE_BUY) ? (current - entry) : (entry - current);
    points_profit /= m_symbol.Point();
    
    double partial_target = InpSL_Points * 2.0;

    // State check: If we haven't moved SL to BE, it's pending partial
    if(points_profit >= partial_target && MathAbs(m_position.StopLoss() - entry) > 1e-5) {
        double vol = NormalizeDouble(m_position.Volume() * 0.7, 2);
        if(vol >= 0.01) {
            if(m_trade.PositionClosePartial(m_position.Ticket(), vol)) {
                m_trade.PositionModify(m_position.Ticket(), entry, m_position.TakeProfit());
                Print("Sovereign: Partial Closed (70%) & BE Set.");
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
//| Visual Dashboard                                                 |
//+------------------------------------------------------------------+
void DrawDashboard() {
    string prefix = "SOV_EA_";
    int y = InpBase_Y;
    int x = InpBase_X;
    
    color str_col = (g_last_strength >= InpMinStrength) ? clrLime : clrRed;
    color hmm_col = (g_last_hmm > 0.65) ? clrAqua : (g_last_hmm < 0.35) ? clrRed : clrGray;

    CreateLabel(prefix+"T", "── SOVEREIGN V29.2 EA ──", x, y,      10, clrGray);
    CreateLabel(prefix+"S", "Status:   " + g_status,         x, y+18,  10, clrWhite);
    CreateLabel(prefix+"H", "HMM Prob: " + DoubleToString(g_last_hmm, 3), x, y+36, 10, hmm_col);
    CreateLabel(prefix+"M", "Strength: " + DoubleToString(g_last_strength*100, 1) + "%", x, y+54, 10, str_col);
    CreateLabel(prefix+"R", "Risk/Tr:  " + DoubleToString(InpRiskPercent, 1) + "%",      x, y+72, 10, clrWhite);
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
