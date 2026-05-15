import socket
import json
import os
import logging
import threading
from datetime import datetime
import numpy as np

# Phase 2 Core Math Modules (Alpha Generation)
from core_math import QuantitativeGARCH, AdaptiveKalmanFilter, HeuristicJumpHMM

# Phase 3 Risk & Microstructure Modules (Alpha execution & protection)
from risk_evt import CorwinSchultzEstimator, FractionalKellySizer, ExtremeValueTheorySL
from ml_engine.xgboost_oracle import XGBoostOracle

_log_level = os.getenv("Black_Knight_Aut_System_LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, _log_level, logging.INFO),
    format='%(asctime)s - %(levelname)s - %(message)s'
)

DEFAULT_HOST = os.getenv("Black_Knight_Aut_System_HOST", "127.0.0.1")
DEFAULT_PORT = int(os.getenv("Black_Knight_Aut_System_PORT", "8888"))
SOCKET_TIMEOUT_SEC = float(os.getenv("Black_Knight_Aut_System_SOCKET_TIMEOUT_SEC", "5.0"))
MAX_BUFFER_BYTES = int(os.getenv("Black_Knight_Aut_System_MAX_BUFFER_BYTES", "262144"))

class QuantEngine:
    """
    Controlador Maestro C++ / Python = Order Management Brain.
    Pasa las proyecciones del motor estocástico (Alpha) a través 
    del filtro de penalización (Risk), retornando el vector de disparo final.
    """
    def __init__(self, config=None):
        cfg = dict(config or {})

        garch_window = int(cfg.get("garch_window", 1000))
        hmm_components = int(cfg.get("hmm_components", 2))
        hmm_window = int(cfg.get("hmm_window", 500))
        cs_window = int(cfg.get("cs_window", 20))
        kelly_fraction = float(cfg.get("kelly_fraction", 0.25))
        direction_edge_threshold = float(cfg.get("direction_edge_threshold", 0.15))
        kelly_min_fraction = float(cfg.get("kelly_min_fraction", 0.005))
        kelly_max_fraction = float(cfg.get("kelly_max_fraction", 0.05))
        evt_tail_fraction = float(cfg.get("evt_tail_fraction", 0.05))
        evt_confidence_level = float(cfg.get("evt_confidence_level", 0.99))

        # Trade-quality and turnover controls
        self.min_hmm_confidence = float(np.clip(cfg.get("min_hmm_confidence", 0.58), 0.5, 0.95))
        self.signal_z_threshold = float(max(cfg.get("signal_z_threshold", 0.02), 0.0))
        self.max_spread_ratio = float(max(cfg.get("max_spread_ratio", 1.10), 0.05))
        self.cooldown_bars = int(max(cfg.get("cooldown_bars", 1), 0))
        self.confirm_bars = int(max(cfg.get("confirm_bars", 2), 1))
        self.require_trend_alignment = bool(cfg.get("require_trend_alignment", True))
        self.trade_side = str(cfg.get("trade_side", "both")).lower().strip()
        if self.trade_side not in ("both", "long_only", "short_only"):
            self.trade_side = "both"

        # Math Alpha Engine
        self.garch = QuantitativeGARCH(window_size=max(garch_window, 200))
        self.hmm = HeuristicJumpHMM(
            n_components=max(2, hmm_components),
            window_size=max(hmm_window, 150),
        )
        self.kalman = AdaptiveKalmanFilter(initial_state=0.0)
        
        # Microstructure Risk Engine (Defense)
        self.spread_cs = CorwinSchultzEstimator(window_size=max(cs_window, 5))
        self.kelly = FractionalKellySizer(
            kelly_fraction=kelly_fraction,
            direction_edge_threshold=direction_edge_threshold,
            min_fraction=max(0.0, kelly_min_fraction),
            max_fraction=max(kelly_max_fraction, kelly_min_fraction),
        )
        self.evt_sl = ExtremeValueTheorySL(
            tail_fraction=evt_tail_fraction,
            confidence_level=evt_confidence_level,
        )
        
        self.ml_oracle = XGBoostOracle()

        # ML Policy
        self.use_ml_gate = bool(cfg.get("use_ml_gate", False))
        self.ml_threshold = float(cfg.get("ml_threshold", 0.55))

        self._lock = threading.RLock()
        self._reset_runtime_state()

    def _reset_runtime_state(self):
        self.tick_counter = 0
        self.last_close = 0.0
        self.is_warmed_up = False
        self.last_trade_tick = -1_000_000
        self.pending_direction = "NEUTRAL"
        self.pending_streak = 0
        self.spread_cs.history = []
        self.spread_cs.current_spread = 0.0001
        self.kalman.x = 0.0
        self.kalman.P = 1.0

    @staticmethod
    def _safe_float(value, default=0.0):
        try:
            casted = float(value)
            if np.isfinite(casted):
                return casted
            return default
        except (TypeError, ValueError):
            return default

    @staticmethod
    def _validate_bar(o, h, l, c, v):
        values = np.array([o, h, l, c, v], dtype=float)
        if not np.all(np.isfinite(values)):
            return False
        if min(o, h, l, c) <= 0.0:
            return False
        if h < l:
            return False
        if v < 0.0:
            return False
        return True
        
    def warmup(self, history_data):
        with self._lock:
            if not isinstance(history_data, list) or len(history_data) < 250:
                raise ValueError("Warmup requires at least 250 historical bars.")

            self._reset_runtime_state()
            logging.info(
                "Warming up engine (Phase 2 & 3 pipeline) with %d historical bars...",
                len(history_data),
            )

            returns = []
            last_valid_close = None
            valid_bars = 0

            for i in range(1, len(history_data)):
                prev_row = history_data[i - 1]
                curr_row = history_data[i]

                if not isinstance(prev_row, (list, tuple)) or not isinstance(curr_row, (list, tuple)):
                    continue
                if len(prev_row) < 4 or len(curr_row) < 5:
                    continue

                o = self._safe_float(curr_row[0])
                h = self._safe_float(curr_row[1])
                l = self._safe_float(curr_row[2])
                c = self._safe_float(curr_row[3])
                v = self._safe_float(curr_row[4])
                prev_close = self._safe_float(prev_row[3])

                if not self._validate_bar(o, h, l, c, v):
                    continue
                if prev_close <= 0.0:
                    continue

                ret = float(np.log(c / prev_close))
                if not np.isfinite(ret):
                    continue

                returns.append(ret)
                self.spread_cs.update(h, l)
                valid_bars += 1
                last_valid_close = c

            if len(returns) < 200 or last_valid_close is None:
                raise ValueError("Warmup failed: insufficient valid return series.")

            self.garch.warmup(returns)
            self.hmm.warmup(returns)
            self.evt_sl.warmup(returns)

            self.kalman.x = 0.0
            self.kalman.P = 1.0
            self.last_close = last_valid_close
            self.is_warmed_up = True
            logging.info("Fully warmed up. L3 execution active (%d valid bars).", valid_bars)
        
    def process_tick(self, o, h, l, c, v):
        with self._lock:
            if not self.is_warmed_up:
                return {"error": "Not warmed up."}

            try:
                o = self._safe_float(o)
                h = self._safe_float(h)
                l = self._safe_float(l)
                c = self._safe_float(c)
                v = self._safe_float(v)

                if not self._validate_bar(o, h, l, c, v):
                    return {"error": "Invalid bar payload."}

                if self.last_close <= 0.0:
                    self.last_close = c
                    return {
                        "action": "execute",
                        "direction": "NEUTRAL",
                        "optimal_f": 0.0,
                        "stop_loss_dist": 0.015,
                    }

                ret = float(np.log(c / self.last_close))
                if not np.isfinite(ret):
                    return {"error": "Invalid return value."}
                self.last_close = c

                implicit_spread = float(np.clip(self.spread_cs.update(h, l), 0.0, 0.05))
                exo_var = float(max(self.kalman._garman_klass_var(o, h, l, c), 1e-10))

                lambda_smooth = 1e-4
                q_t_drift = max(exo_var * lambda_smooth, 1e-10)
                filtered_ret = float(
                    self.kalman.step(ret, R_t=max(implicit_spread**2, 1e-10), Q_t=q_t_drift)
                )

                self.tick_counter += 1
                force_fit = (self.tick_counter % 16 == 0)

                sig_proj = float(max(self.garch.update(ret, force_fit=force_fit), 1e-10))

                hmm_state = self.hmm.update(filtered_ret, exo_var, sig_proj, force_fit=force_fit)
                prob_bull = float(np.clip(hmm_state.get("bull", 0.5), 0.0, 1.0))
                prob_bear = float(np.clip(hmm_state.get("bear", 0.5), 0.0, 1.0))
                mu = float(hmm_state.get("drift", 0.0))
                if not np.isfinite(mu):
                    mu = 0.0

                mu_adj = max(abs(mu) - implicit_spread, 0.0)

                cvar_stop = float(self.evt_sl.update(ret, force_fit=force_fit))
                if (not np.isfinite(cvar_stop)) or cvar_stop <= 0.0:
                    cvar_stop = 0.015

                skew, kurt = self.evt_sl.get_higher_moments()
                if not np.isfinite(skew):
                    skew = 0.0
                if not np.isfinite(kurt):
                    kurt = 3.0

                f_star = float(
                    self.kelly.optimal_f(
                        mu_adj,
                        sig_proj,
                        prob_bull,
                        prob_bear,
                        skew=skew,
                        kurt=kurt,
                        cvar_stop=cvar_stop,
                    )
                )
                if not np.isfinite(f_star):
                    f_star = 0.0
                f_star = float(np.clip(f_star, 0.0, 0.05))

                sigma_proj = float(np.sqrt(max(sig_proj, 1e-10)))
                signal_z = float(mu_adj / max(sigma_proj, 1e-10))
                spread_ratio = float(implicit_spread / max(sigma_proj, 1e-10))
                confidence = float(max(prob_bull, prob_bear))
                trend_aligned = bool(mu == 0.0 or np.sign(mu) == np.sign(filtered_ret))

                direction = "NEUTRAL"
                gate_reason = ""
                quality_ok = (
                    confidence >= self.min_hmm_confidence
                    and signal_z >= self.signal_z_threshold
                    and spread_ratio <= self.max_spread_ratio
                )
                if self.require_trend_alignment and not trend_aligned:
                    quality_ok = False

                if f_star > 0.0 and quality_ok:
                    if prob_bull > prob_bear:
                        direction = "BUY"
                    elif prob_bear > prob_bull:
                        direction = "SELL"

                if direction == "BUY" and self.trade_side == "short_only":
                    direction = "NEUTRAL"
                    f_star = 0.0
                    gate_reason = "side_filter"
                elif direction == "SELL" and self.trade_side == "long_only":
                    direction = "NEUTRAL"
                    f_star = 0.0
                    gate_reason = "side_filter"

                if direction in ("BUY", "SELL"):
                    if direction == self.pending_direction:
                        self.pending_streak += 1
                    else:
                        self.pending_direction = direction
                        self.pending_streak = 1

                    if self.pending_streak < self.confirm_bars:
                        gate_reason = "confirm_wait"
                        direction = "NEUTRAL"
                        f_star = 0.0
                else:
                    self.pending_direction = "NEUTRAL"
                    self.pending_streak = 0

                if direction in ("BUY", "SELL"):
                    bars_since_last = self.tick_counter - self.last_trade_tick
                    if bars_since_last <= self.cooldown_bars:
                        gate_reason = "cooldown"
                        direction = "NEUTRAL"
                        f_star = 0.0
                    else:
                        self.last_trade_tick = self.tick_counter

                if not quality_ok and f_star > 0.0 and direction == "NEUTRAL" and gate_reason == "":
                    gate_reason = "quality_filter"

                xg_confidence = 1.0


                return {
                    "action": "execute",
                    "direction": direction,
                    "optimal_f": f_star,
                    "stop_loss_dist": float(cvar_stop),
                    "debug": {
                        "prob_bull": round(prob_bull, 4),
                        "prob_bear": round(prob_bear, 4),
                        "confidence": round(confidence, 4),
                        "xg_confidence": round(xg_confidence, 4),
                        "trend_align": trend_aligned,
                        "signal_z": round(signal_z, 4),
                        "spread_ratio": round(spread_ratio, 4),
                        "gate": gate_reason,
                        "mu_net": round(mu_adj, 6),
                        "spread_imp": round(implicit_spread, 6),
                    },
                }
            except Exception as exc:
                logging.exception("Process tick failure: %s", exc)
                return {"error": f"Process tick failure: {exc}"}

engine = QuantEngine()
_json_decoder = json.JSONDecoder()


def _send_json(client_socket, payload):
    message = json.dumps(payload, ensure_ascii=True, separators=(",", ":")) + "\n"
    client_socket.sendall(message.encode("utf-8"))


def _extract_json_payloads(buffer):
    payloads = []

    # Protocolo principal: un JSON por línea.
    while "\n" in buffer:
        line, buffer = buffer.split("\n", 1)
        line = line.replace("\x00", "").strip()
        if not line:
            continue
        try:
            payloads.append(json.loads(line))
        except json.JSONDecodeError:
            logging.warning("Invalid JSON line dropped: %s", line[:120])

    # Compatibilidad hacia atrás: payload sin salto de línea.
    while True:
        candidate = buffer.replace("\x00", "").lstrip()
        if not candidate or not candidate.startswith("{"):
            break
        try:
            payload, end_idx = _json_decoder.raw_decode(candidate)
        except json.JSONDecodeError:
            break
        payloads.append(payload)
        buffer = candidate[end_idx:]

    return payloads, buffer


def _background_warmup(client_socket, bars_data):
    try:
        engine.warmup(bars_data)
        _send_json(client_socket, {"status": "ready"})
        logging.info("Warmup complete. %d bars processed.", len(bars_data))
    except Exception as exc:
        logging.exception("Warmup thread failure: %s", exc)
        try:
            _send_json(client_socket, {"error": f"Warmup failed: {exc}"})
        except OSError:
            pass


def _process_payload(client_socket, payload):
    action = payload.get("action")

    if action == "init":
        data = payload.get("data", [])
        if not isinstance(data, list) or len(data) < 250:
            _send_json(client_socket, {"error": "Invalid init payload. Expected >=250 bars."})
            return

        _send_json(client_socket, {"status": "warming"})
        threading.Thread(
            target=_background_warmup,
            args=(client_socket, data),
            daemon=True,
        ).start()
        return

    if action == "evaluate":
        data = payload.get("data", [])
        if not isinstance(data, (list, tuple)) or len(data) != 5:
            _send_json(client_socket, {"error": "Invalid evaluate payload. Expected 5 values."})
            return

        result = engine.process_tick(*data)
        _send_json(client_socket, result)

        if "direction" in result:
            logging.info(
                "Signal evaluated: %s | Lote (%%): %.2f | SL_Dist: %.2f%%",
                result.get("direction", "NEUTRAL"),
                result.get("optimal_f", 0.0) * 100.0,
                result.get("stop_loss_dist", 0.0) * 100.0,
            )
        return

    if action == "xg_predict":
        data = payload.get("data", [])
        if not isinstance(data, (list, tuple)) or len(data) != 10:
            _send_json(client_socket, {"error": "Invalid xg_predict payload. Expected 10 values."})
            return

        xg_prob = engine.ml_oracle.predict_confidence(data)
        _send_json(client_socket, {"xg_confidence": xg_prob})
        return

    if action == "ping":
        _send_json(client_socket, {"status": "pong"})
        return

    _send_json(client_socket, {"error": "Unknown action."})

def handle_client(client_socket):
    # Optimización de performance a nivel de OS
    client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 128 * 1024)
    client_socket.settimeout(SOCKET_TIMEOUT_SEC)

    buffer = ""
    try:
        while True:
            try:
                raw_data = client_socket.recv(65536)
            except socket.timeout:
                continue

            if not raw_data:
                break

            chunk = raw_data.decode("utf-8", errors="ignore").replace("\x00", "")
            if not chunk:
                continue

            buffer += chunk

            if len(buffer) > MAX_BUFFER_BYTES:
                logging.warning("Dropping oversized payload buffer (%d bytes).", len(buffer))
                buffer = ""
                _send_json(client_socket, {"error": "Payload exceeds max buffer size."})
                continue

            payloads, buffer = _extract_json_payloads(buffer)
            for payload in payloads:
                if isinstance(payload, dict):
                    _process_payload(client_socket, payload)
                else:
                    _send_json(client_socket, {"error": "Invalid payload type."})

    except Exception as e:
        logging.error(f"Client disconnected - {e}")
    finally:
        client_socket.close()

from http.server import BaseHTTPRequestHandler, HTTPServer

class QuantHTTPHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length).decode('utf-8')
        response = {}
        try:
            payload = json.loads(post_data)
            action = payload.get("action")
            if action == "xg_predict":
                data = payload.get("data")
                if isinstance(data, list) and len(data) == 10:
                    xg_prob = engine.ml_oracle.predict_confidence(data)
                    response = {"xg_confidence": xg_prob}
                else:
                    response = {"error": "Invalid payload"}
            else:
                response = {"error": "Unknown action"}
        except Exception as e:
            response = {"error": str(e)}
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response).encode('utf-8'))
        
    def log_message(self, format, *args):
        pass # Suppress logging

def start_http_server(host, port):
    server = HTTPServer((host, port), QuantHTTPHandler)
    logging.info(f"+++ HTTP Server (Strategy Tester Fallback) started on {host}:{port} +++")
    server.serve_forever()

def start_server(host=DEFAULT_HOST, port=DEFAULT_PORT):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, int(port)))
    server.listen(16)
    logging.info(f"+++ Black_Knight_Aut_System Quant Server (L3 Engine Phase 3 Risk Pipeline) started on {host}:{port} +++")

    http_port = int(port) + 1
    threading.Thread(target=start_http_server, args=(host, http_port), daemon=True).start()

    try:
        while True:
            client_sock, address = server.accept()
            logging.info(f"Accepted OMS TCP connection from {address}")
            threading.Thread(target=handle_client, args=(client_sock,), daemon=True).start()
    except KeyboardInterrupt:
        logging.info("Server shutting down.")
    finally:
        server.close()


# --- FILE BRIDGE FOR MT5 STRATEGY TESTER ---

# --- FILE BRIDGE FOR MT5 STRATEGY TESTER ---
def file_bridge_loop(engine):
    import time
    import os
    import json
    import logging
    
    # Path tipico de Common Files de MT5 en Windows
    appdata = os.environ.get("APPDATA")
    common_path = os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files")
    request_file = os.path.join(common_path, "xg_request.json")
    response_file = os.path.join(common_path, "xg_response.json")
    
    logging.info(f"[BRIDGE] Monitoring: {request_file}")
    
    while True:
        try:
            if os.path.exists(request_file):
                # Leer peticion (esperar a que este liberado por si MT5 lo esta escribiendo)
                try:
                    with open(request_file, "r", encoding="utf-8") as rf:
                        data = json.load(rf)
                except json.JSONDecodeError:
                    # Archivo a medio escribir, reintentar despues
                    time.sleep(0.005)
                    continue
                except PermissionError:
                    time.sleep(0.005)
                    continue

                # Procesar
                res = {"error": "Unknown action"}
                action = data.get("action")
                if action == "xg_predict":
                    features = data.get("data", [])
                    if len(features) == 10:
                        xg_conf = float(engine.ml_oracle.predict_confidence(features))
                        res = {"xg_confidence": xg_conf}
                    else:
                        res = {"error": "Invalid features format"}
                else:
                    # En caso de ticks (fallback general)
                    try:
                        res = engine.process_tick(data.get("o"), data.get("h"), data.get("l"), data.get("c"), data.get("v"))
                    except Exception as ex:
                        res = {"error": str(ex)}
                
                # Escribir respuesta (atomic)
                tmp_resp = response_file + ".tmp"
                with open(tmp_resp, "w", encoding="utf-8") as wf:
                    json.dump(res, wf)
                
                # Renombrar para que MT5 lo lea completo (evitar lecturas parciales)
                if os.path.exists(response_file):
                    os.remove(response_file)
                os.rename(tmp_resp, response_file)
                
                # Borrar peticion para indicar que se proceso
                os.remove(request_file)
            
            time.sleep(0.001) # Ultra baja latencia
        except (PermissionError, FileNotFoundError):
            # WinError 32: MT5 esta leyendo/escribiendo el archivo.
            # WinError 2: MT5 borro el archivo despues de que comprobamos que existia.
            time.sleep(0.005)
        except Exception as e:
            logging.error(f"[BRIDGE ERROR] {e}")
            time.sleep(0.1)

if __name__ == "__main__":
    # Iniciar bridge en un hilo separado
    import threading
    bridge_thread = threading.Thread(target=file_bridge_loop, args=(engine,), daemon=True)
    bridge_thread.start()
    
    # Iniciar servidores normales
    start_server()
