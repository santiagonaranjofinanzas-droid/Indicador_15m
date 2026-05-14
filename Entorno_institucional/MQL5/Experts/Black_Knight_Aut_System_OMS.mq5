//+------------------------------------------------------------------+
//|                                     Black_Knight_Aut_System_OMS.mq5            |
//|                                     Order Management System      |
//|                    Black_Knight_Aut_System Institutional Series | L3 Quant     |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

input string InpHost = "127.0.0.1";
input int    InpPort = 8888;
input int    InpMagic= 40001;
input double InpRisk = 1.0;
input int    InpWarmupBars = 500;
input int    InpSendChunkBytes = 4096;

enum ENUM_OMS_STATE {
    STATE_INIT,
    STATE_WAIT_READY,
    STATE_ACTIVE
};

ENUM_OMS_STATE g_state = STATE_INIT;
int    g_socket = INVALID_HANDLE;
CTrade g_trade;
CSymbolInfo g_symbol;
string g_status = "CONNECTING...";
string g_reply_buffer = "";

bool SendJsonChunked(int socket_handle, string payload) {
    uchar req[];
    int copied = StringToCharArray(payload, req, 0, WHOLE_ARRAY, CP_UTF8);
    if(copied <= 1) return false;

    // StringToCharArray incluye terminador nulo; no se envía por red.
    int total = copied - 1;
    int offset = 0;
    int chunk_size = MathMax(512, InpSendChunkBytes);

    while(offset < total && !IsStopped()) {
        int to_send = MathMin(chunk_size, total - offset);

        uchar chunk[];
        ArrayResize(chunk, to_send);
        ArrayCopy(chunk, req, 0, offset, to_send);

        int sent = SocketSend(socket_handle, chunk, to_send);
        if(sent <= 0) {
            return false;
        }

        offset += sent;
    }

    return (offset == total);
}

bool ReconnectBridge() {
    if(g_socket != INVALID_HANDLE) {
        SocketClose(g_socket);
        g_socket = INVALID_HANDLE;
    }

    ResetLastError();
    g_socket = SocketCreate();
    if(g_socket == INVALID_HANDLE) {
        Print("Socket recreate failure: ", GetLastError());
        return false;
    }

    if(!SocketConnect(g_socket, InpHost, InpPort, 1000)) {
        Print("Bridge reconnect failure: ", GetLastError());
        SocketClose(g_socket);
        g_socket = INVALID_HANDLE;
        return false;
    }

    g_state = STATE_INIT;
    g_reply_buffer = "";
    Print("Bridge reconnected. Restarting warmup handshake.");
    return true;
}

int OnInit() {
    g_trade.SetExpertMagicNumber(InpMagic);
    g_symbol.Name(_Symbol);
    
    // Iniciar socket TCP
    ResetLastError();
    g_socket = SocketCreate();
    if(g_socket == INVALID_HANDLE) {
        Print("Socket failure: ", GetLastError());
        return INIT_FAILED;
    }
    
    if(!SocketConnect(g_socket, InpHost, InpPort, 1000)) {
        Print("Bridge Connect failure: ", GetLastError());
        SocketClose(g_socket);
        g_socket = INVALID_HANDLE;
        return INIT_FAILED;
    }
    
    // Habilitar Timer a 250ms (~4 Hz) para la Máquina de Estados Non-Blocking
    EventSetMillisecondTimer(250);
    g_state = STATE_INIT;
    
    Print("Socket established. Delegating Warmup to OnTimer State Machine.");
    return INIT_SUCCEEDED; // ¡Retorno flash a MT5 en < 1ms para evitar Init Timeout!
}

void OnDeinit(const int reason) {
    EventKillTimer();
    if(g_socket != INVALID_HANDLE) SocketClose(g_socket);
}

void OnTimer() {
    if(g_socket == INVALID_HANDLE) return;
    
    //---------------------------------------------------------
    // ETAPA 1: Enviar payload de Warmup y cambiar de estado
    //---------------------------------------------------------
    if(g_state == STATE_INIT) {
        MqlRates rates[];
        ArraySetAsSeries(rates, true);
        int num_bars = MathMax(250, InpWarmupBars);
        if(CopyRates(_Symbol, _Period, 1, num_bars, rates) != num_bars) {
            Print("Warmup failure: Unable to copy rates");
            return;
        }
        
        string json = "{\"action\":\"init\",\"data\":[";
        for(int i = num_bars - 1; i >= 0; i--) {
            json += StringFormat("[%.5f,%.5f,%.5f,%.5f,%I64d]", 
                                 rates[i].open, rates[i].high, rates[i].low, rates[i].close, rates[i].tick_volume);
            if(i > 0) json += ",";
        }
        json += "]}\n";

        if(SendJsonChunked(g_socket, json)) {
            Print("Async Warmup payload sent. Entering Async Wait State. Bars=", num_bars);
            g_state = STATE_WAIT_READY;
            g_reply_buffer = "";
        } else {
            Print("Error sending warmup socket request: ", GetLastError(), " | bars=", num_bars, " | chunk=", InpSendChunkBytes);
            ReconnectBridge();
        }
    }
    //---------------------------------------------------------
    // ETAPA 2: Escuchar asíncronamente el ACK "ready" de Python
    //---------------------------------------------------------
    else if(g_state == STATE_WAIT_READY) {
        // Consultar a WinSock pasivamente sin asediar el buffer
        uint available = SocketIsReadable(g_socket);
        if(available > 0) {
            uchar res[];
            // Le pedimos exactamente lo disponible con 100ms de holgura
            int len = SocketRead(g_socket, res, available, 100); 
            
            if(len > 0) {
                g_reply_buffer += CharArrayToString(res, 0, len);
                if(StringFind(g_reply_buffer, "ready") >= 0) {
                    Print("--- Quant Server Fully Synced and Ready ---");
                    g_state = STATE_ACTIVE; // Activar EA
                    g_reply_buffer = "";
                }
            } else {
                Print("Socket read error during warmup wait: ", GetLastError());
                ReconnectBridge();
            }
        }
    }
}

void OnTick() {
    if(g_socket == INVALID_HANDLE || g_state != STATE_ACTIVE) return;
    
    // Evaluate only on new bar (F(t-1) Parity constraint)
    if(IsNewBar()) {
        double open[1], high[1], low[1], close[1];
        long vol[1];
        if(CopyOpen(_Symbol, _Period, 1, 1, open) <= 0) return;
        if(CopyHigh(_Symbol, _Period, 1, 1, high) <= 0) return;
        if(CopyLow(_Symbol, _Period, 1, 1, low) <= 0) return;
        if(CopyClose(_Symbol, _Period, 1, 1, close) <= 0) return;
        if(CopyTickVolume(_Symbol, _Period, 1, 1, vol) <= 0) return;
        
        string json = StringFormat("{\"action\":\"evaluate\",\"data\":[%.5f,%.5f,%.5f,%.5f,%I64d]}\n",
                                   open[0], high[0], low[0], close[0], vol[0]);

        if(SendJsonChunked(g_socket, json)) {
            
            // Loop de Espera Micro-Síncrona segura HFT (~500ms max)
            uint available = 0;
            int max_spins = 50; 
            for(int spins = 0; spins < max_spins && !IsStopped(); spins++) {
                available = SocketIsReadable(g_socket);
                if(available > 0) break;
                Sleep(10); // Polling amigable de 10ms
            }

            if(available > 0) {
                uchar res[];
                int len = SocketRead(g_socket, res, available, 100); 
                if(len > 0) {
                    string ans = CharArrayToString(res, 0, len);
                    PrintFormat("L3 Engine Ans: %s", ans);
                    ExecuteQuantSignal(ans); // EJECUCIÓN DIRECTA A MERCADO
                } else {
                    Print("Socket read error on evaluate: ", GetLastError());
                    ReconnectBridge();
                }
            } else {
                Print("Warning: No reply from Python L3 Engine on Evaluate.");
            }
        } else {
            Print("Error sending evaluation TCP request: ", GetLastError());
            ReconnectBridge();
        }
    }
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

//+------------------------------------------------------------------+
//| L3 Microstructure Execution Engine                               |
//+------------------------------------------------------------------+
double ParseJSONDouble(string json, string key) {
    int key_idx = StringFind(json, "\"" + key + "\"");
    if(key_idx < 0) return 0.0;
    
    // Buscar los ":" después de la key
    int colon_idx = StringFind(json, ":", key_idx + StringLen(key));
    if(colon_idx < 0) return 0.0;
    
    // Buscar el delimitador de cierre (coma o llave)
    int end_comma = StringFind(json, ",", colon_idx);
    int end_brace = StringFind(json, "}", colon_idx);
    
    int end_idx = -1;
    if(end_comma > 0 && end_brace > 0) end_idx = MathMin(end_comma, end_brace);
    else if(end_comma > 0) end_idx = end_comma;
    else if(end_brace > 0) end_idx = end_brace;
    if(end_idx < 0) return 0.0;
    
    string val_str = StringSubstr(json, colon_idx + 1, end_idx - colon_idx - 1);
    StringReplace(val_str, " ", "");
    StringReplace(val_str, "\"", ""); 
    StringReplace(val_str, "\r", "");
    StringReplace(val_str, "\n", "");
    return StringToDouble(val_str);
}

void ExecuteQuantSignal(string json_signal) {
    string dir = "NEUTRAL";
    if(StringFind(json_signal, "\"direction\":\"BUY\"") >= 0 || StringFind(json_signal, "\"direction\": \"BUY\"") >= 0) dir = "BUY";
    else if(StringFind(json_signal, "\"direction\":\"SELL\"") >= 0 || StringFind(json_signal, "\"direction\": \"SELL\"") >= 0) dir = "SELL";
    
    if(dir == "NEUTRAL") return; 
    
    // Extraer Fracción Real Óptima y Tail Dist L3
    double optimal_f = ParseJSONDouble(json_signal, "optimal_f");
    double sl_dist = ParseJSONDouble(json_signal, "stop_loss_dist");
    if(optimal_f <= 0.0) optimal_f = InpRisk / 100.0; // Fallback al Risk % de Entrada
    if(sl_dist <= 0.0) return;
    
    // Stop & Reverse System (Elimina la posición opuesta en Shift de Régimen)
    bool has_active_position = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic) {
            long type = PositionGetInteger(POSITION_TYPE);
            if((type == POSITION_TYPE_BUY && dir == "SELL") || (type == POSITION_TYPE_SELL && dir == "BUY")) {
                Print("Regime Shift Detected L3. Liquidating opposite position: ", ticket);
                g_trade.PositionClose(ticket);
            } else {
                has_active_position = true;
            }
        }
    }
    
    if(has_active_position) return; 

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Cálculo Invariante de Riesgo para evitar el 30% Drawdown y restringirlo a lo dictado por Kelly
    double risk_amount_usd = AccountInfoDouble(ACCOUNT_BALANCE) * optimal_f; 
    
    double sl_price = 0.0;
    double tp_price = 0.0;
    double pips_at_risk = 0.0;
    
    // Ratio de Riesgo-Recompensa Base = 1:3 Institucional
    double reward_ratio = 3.0; 

    if(dir == "BUY") {
        if(sl_dist > 0.0) {
            sl_price = ask * (1.0 - sl_dist);
            pips_at_risk = ask - sl_price;
            tp_price = ask + (pips_at_risk * reward_ratio); 
        }
    } else if(dir == "SELL") {
         if(sl_dist > 0.0) {
            sl_price = bid * (1.0 + sl_dist);
            pips_at_risk = sl_price - bid;
            tp_price = bid - (pips_at_risk * reward_ratio); 
         }
    }
    
    // Prevención de división por Zero
    if(pips_at_risk <= 0) pips_at_risk = 1.0; 
    
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tick_value <= 0.0 || tick_size <= 0.0) return;
    
    double ticks_sl = pips_at_risk / tick_size;
    double cost_per_lot_on_sl = ticks_sl * tick_value; // Ejemplo: 3000 ticks * 1 USD = $3000 de arrastre por cada Lote
    
    double true_lot = risk_amount_usd / cost_per_lot_on_sl; // Ej: $50 USD Max Loss / $3000 de costo_lote = 0.016 lotes limpios
    
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double calculated_lot = MathFloor(true_lot / step) * step;
    if(calculated_lot < min_lot) calculated_lot = min_lot;
    if(calculated_lot > max_lot) calculated_lot = max_lot;

    // Normalización de precios MQL5 (Requisito Obligatorio del Broker)
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl_price = NormalizeDouble(sl_price, digits);
    tp_price = NormalizeDouble(tp_price, digits);
    int lot_digits = 2;
    if(step > 0.0) {
        lot_digits = (int)MathMax(0.0, MathRound(-MathLog10(step)));
    }
    calculated_lot = NormalizeDouble(calculated_lot, lot_digits);

    if(dir == "BUY") {
        ResetLastError();
        bool buy_ok = g_trade.Buy(calculated_lot, _Symbol, ask, sl_price, tp_price, "L3 Bridge");
        if(buy_ok) {
            PrintFormat("+++ L3 ORDER PLACED [BUY] | Vol: %.2f | Kelly Risk: %.2f%% ($%.2f USD) | SL: %.5f | TP: %.5f +++", 
                        calculated_lot, optimal_f*100, risk_amount_usd, sl_price, tp_price);
        } else {
            PrintFormat("BUY failed | retcode=%d | lasterror=%d", (int)g_trade.ResultRetcode(), GetLastError());
        }
                    
    } else if(dir == "SELL") {
         ResetLastError();
         bool sell_ok = g_trade.Sell(calculated_lot, _Symbol, bid, sl_price, tp_price, "L3 Bridge");
         if(sell_ok) {
             PrintFormat("--- L3 ORDER PLACED [SELL] | Vol: %.2f | Kelly Risk: %.2f%% ($%.2f USD) | SL: %.5f | TP: %.5f ---", 
                         calculated_lot, optimal_f*100, risk_amount_usd, sl_price, tp_price);
         } else {
             PrintFormat("SELL failed | retcode=%d | lasterror=%d", (int)g_trade.ResultRetcode(), GetLastError());
         }
    }
}
