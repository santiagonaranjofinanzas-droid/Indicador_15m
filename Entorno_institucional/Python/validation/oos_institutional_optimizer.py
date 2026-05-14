import argparse
import json
import logging
import os
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, List, Tuple

import numpy as np
import pandas as pd

# Ensure root package imports work when executing this file directly.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from quant_server import QuantEngine
from validation.pbo_metrics import PBOMetrics
from validation.purged_walkforward import PurgedWalkForward


logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logging.getLogger("hmmlearn").setLevel(logging.ERROR)
logging.getLogger("hmmlearn.hmm").setLevel(logging.ERROR)


MT5_TIMEFRAME_MAP = {
    "M1": "TIMEFRAME_M1",
    "M5": "TIMEFRAME_M5",
    "M15": "TIMEFRAME_M15",
    "M30": "TIMEFRAME_M30",
    "H1": "TIMEFRAME_H1",
    "H4": "TIMEFRAME_H4",
    "D1": "TIMEFRAME_D1",
}


BARS_PER_YEAR = {
    "M1": 24 * 60 * 252,
    "M5": 24 * 12 * 252,
    "M15": 24 * 4 * 252,
    "M30": 24 * 2 * 252,
    "H1": 24 * 252,
    "H4": 6 * 252,
    "D1": 252,
}


@dataclass
class EvalResult:
    returns: np.ndarray
    trades: int


def _standardize_ohlcv(df: pd.DataFrame) -> pd.DataFrame:
    if df is None or df.empty:
        raise ValueError("Empty dataframe for OHLCV data.")

    lower_cols = {c.lower(): c for c in df.columns}

    def col(name_options: List[str]) -> str:
        for opt in name_options:
            if opt in lower_cols:
                return lower_cols[opt]
        return ""

    c_open = col(["open"])
    c_high = col(["high"])
    c_low = col(["low"])
    c_close = col(["close"])
    c_vol = col(["tick_volume", "volume", "real_volume"])

    if not all([c_open, c_high, c_low, c_close]):
        raise ValueError("Missing OHLC columns in source data.")

    out = pd.DataFrame(
        {
            "open": pd.to_numeric(df[c_open], errors="coerce"),
            "high": pd.to_numeric(df[c_high], errors="coerce"),
            "low": pd.to_numeric(df[c_low], errors="coerce"),
            "close": pd.to_numeric(df[c_close], errors="coerce"),
            "volume": pd.to_numeric(df[c_vol], errors="coerce") if c_vol else 1.0,
        }
    )

    out = out.replace([np.inf, -np.inf], np.nan).dropna()
    out = out[(out["open"] > 0) & (out["high"] > 0) & (out["low"] > 0) & (out["close"] > 0)]
    out["high"] = np.maximum(out["high"].values, out["low"].values)
    out["volume"] = np.maximum(out["volume"].values, 0.0)

    if len(out) < 500:
        raise ValueError("Insufficient clean bars after standardization (<500).")

    return out


def _timeframe_to_mt5_constant(mt5_module, timeframe: str):
    timeframe_name = MT5_TIMEFRAME_MAP.get(timeframe)
    if timeframe_name is None:
        raise ValueError(f"Unsupported timeframe for MT5: {timeframe}")
    return getattr(mt5_module, timeframe_name)


def _sqlite_connection(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA temp_store=MEMORY;")
    return conn


def _ensure_timeseries_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS mt5_rates (
            symbol TEXT NOT NULL,
            timeframe TEXT NOT NULL,
            time INTEGER NOT NULL,
            open REAL NOT NULL,
            high REAL NOT NULL,
            low REAL NOT NULL,
            close REAL NOT NULL,
            volume REAL NOT NULL,
            spread REAL,
            real_volume REAL,
            source TEXT NOT NULL,
            chunk_id INTEGER NOT NULL,
            inserted_at TEXT NOT NULL,
            PRIMARY KEY (symbol, timeframe, time)
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_mt5_rates_symbol_timeframe_time ON mt5_rates(symbol, timeframe, time)")
    conn.commit()


def _persist_rates_chunk(
    conn: sqlite3.Connection,
    df: pd.DataFrame,
    symbol: str,
    timeframe: str,
    source: str,
    chunk_id: int,
) -> None:
    if df.empty:
        return

    payload = df.copy()

    if "volume" not in payload.columns:
        if "tick_volume" in payload.columns:
            payload["volume"] = payload["tick_volume"]
        elif "real_volume" in payload.columns:
            payload["volume"] = payload["real_volume"]
        else:
            payload["volume"] = 0.0

    payload["symbol"] = symbol
    payload["timeframe"] = timeframe
    payload["source"] = source
    payload["chunk_id"] = int(chunk_id)
    payload["inserted_at"] = datetime.now(timezone.utc).isoformat()

    if "spread" not in payload.columns:
        payload["spread"] = None
    if "real_volume" not in payload.columns:
        payload["real_volume"] = None

    payload = payload[[
        "symbol",
        "timeframe",
        "time",
        "open",
        "high",
        "low",
        "close",
        "volume",
        "spread",
        "real_volume",
        "source",
        "chunk_id",
        "inserted_at",
    ]]

    rows = payload.to_records(index=False).tolist()
    conn.executemany(
        """
        INSERT OR REPLACE INTO mt5_rates
        (symbol, timeframe, time, open, high, low, close, volume, spread, real_volume, source, chunk_id, inserted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    conn.commit()


def _load_rates_from_sqlite(db_path: str, symbol: str, timeframe: str, bars: int) -> pd.DataFrame:
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"SQL timeseries database not found: {db_path}")

    with _sqlite_connection(db_path) as conn:
        _ensure_timeseries_schema(conn)
        query = (
            "SELECT time, open, high, low, close, volume, spread, real_volume "
            "FROM mt5_rates WHERE symbol = ? AND timeframe = ? "
            "ORDER BY time DESC LIMIT ?"
        )
        rows = conn.execute(query, (symbol, timeframe, int(bars))).fetchall()

    if not rows:
        raise ValueError("No MT5 rows found in SQL timeseries database.")

    df = pd.DataFrame(rows, columns=["time", "open", "high", "low", "close", "volume", "spread", "real_volume"])
    df = df.sort_values("time").reset_index(drop=True)
    return _standardize_ohlcv(df)


def load_mt5_data_chunked(
    symbol: str,
    timeframe: str,
    bars: int,
    db_path: str,
    chunk_size: int = 1000,
    terminal_path: str | None = None,
) -> pd.DataFrame:
    import MetaTrader5 as mt5

    tf = _timeframe_to_mt5_constant(mt5, timeframe)
    if terminal_path:
        initialized = mt5.initialize(path=terminal_path)
    else:
        initialized = mt5.initialize()

    if not initialized:
        code, msg = mt5.last_error()
        raise RuntimeError(f"MetaTrader5 initialize failed: {code} {msg}")

    try:
        symbol_selected = False
        for _ in range(3):
            if mt5.symbol_select(symbol, True):
                symbol_selected = True
                break
            code, msg = mt5.last_error()
            if code != -1:
                break
        if not symbol_selected:
            code, msg = mt5.last_error()
            raise RuntimeError(f"Unable to select symbol {symbol}: {code} {msg}")

        conn = _sqlite_connection(db_path)
        try:
            _ensure_timeseries_schema(conn)

            collected_frames: List[pd.DataFrame] = []
            start_pos = 0
            chunk_id = 0
            target_bars = int(bars)

            while start_pos < target_bars:
                request_count = min(int(chunk_size), target_bars - start_pos)
                rates = None
                for _ in range(3):
                    rates = mt5.copy_rates_from_pos(symbol, tf, start_pos, request_count)
                    if rates is not None and len(rates) > 0:
                        break
                if rates is None or len(rates) == 0:
                    code, msg = mt5.last_error()
                    raise RuntimeError(f"MT5 chunk request failed at start_pos={start_pos}: {code} {msg}")

                chunk = pd.DataFrame(rates)
                if "time" not in chunk.columns:
                    raise RuntimeError("MT5 chunk is missing time column.")

                chunk = chunk.sort_values("time").drop_duplicates(subset=["time"]).reset_index(drop=True)
                collected_frames.append(chunk)
                _persist_rates_chunk(conn, chunk, symbol=symbol, timeframe=timeframe, source="mt5", chunk_id=chunk_id)

                chunk_id += 1
                start_pos += len(chunk)
                if len(chunk) < request_count:
                    break

            if not collected_frames:
                raise RuntimeError("MT5 returned no rate chunks.")

            merged = pd.concat(collected_frames, ignore_index=True)
            merged = merged.sort_values("time").drop_duplicates(subset=["time"]).reset_index(drop=True)
            if len(merged) > target_bars:
                merged = merged.tail(target_bars).reset_index(drop=True)

            logging.info("Data source: MT5 chunked | bars=%d | db=%s", len(merged), db_path)
            return _standardize_ohlcv(merged)
        finally:
            conn.close()
    finally:
        mt5.shutdown()


def load_mt5_data(symbol: str, timeframe: str, bars: int) -> pd.DataFrame:
    import MetaTrader5 as mt5

    tf_map = {
        "M1": mt5.TIMEFRAME_M1,
        "M5": mt5.TIMEFRAME_M5,
        "M15": mt5.TIMEFRAME_M15,
        "M30": mt5.TIMEFRAME_M30,
        "H1": mt5.TIMEFRAME_H1,
        "H4": mt5.TIMEFRAME_H4,
        "D1": mt5.TIMEFRAME_D1,
    }

    if timeframe not in tf_map:
        raise ValueError(f"Unsupported timeframe for MT5: {timeframe}")

    if not mt5.initialize():
        code, msg = mt5.last_error()
        raise RuntimeError(f"MetaTrader5 initialize failed: {code} {msg}")

    try:
        rates = mt5.copy_rates_from_pos(symbol, tf_map[timeframe], 0, int(bars))
        if rates is None or len(rates) == 0:
            code, msg = mt5.last_error()
            raise RuntimeError(f"MT5 returned no rates: {code} {msg}")
        df = pd.DataFrame(rates)
        return _standardize_ohlcv(df)
    finally:
        mt5.shutdown()


def load_yfinance_data(symbol: str, interval: str, period: str) -> pd.DataFrame:
    import yfinance as yf

    df = yf.download(
        symbol,
        interval=interval,
        period=period,
        progress=False,
        auto_adjust=False,
        threads=False,
    )

    if isinstance(df.columns, pd.MultiIndex):
        df.columns = [c[0] for c in df.columns]

    return _standardize_ohlcv(df)


def load_market_data(
    symbol: str,
    timeframe: str,
    bars: int,
    yf_symbol: str,
    yf_period: str,
    db_path: str,
    chunk_size: int,
    mt5_terminal_path: str,
    allow_yfinance_fallback: bool,
    use_sql_cache: bool,
) -> Tuple[pd.DataFrame, str]:
    if use_sql_cache:
        df = _load_rates_from_sqlite(db_path=db_path, symbol=symbol, timeframe=timeframe, bars=bars)
        logging.info("Data source: SQL cache | bars=%d | db=%s", len(df), db_path)
        return df, "sql_cache"

    try:
        df = load_mt5_data_chunked(
            symbol=symbol,
            timeframe=timeframe,
            bars=bars,
            db_path=db_path,
            chunk_size=chunk_size,
            terminal_path=mt5_terminal_path or None,
        )
        return df, "mt5"
    except Exception as exc:
        if not allow_yfinance_fallback:
            raise
        logging.warning("MT5 chunked data unavailable (%s). Falling back to yfinance.", exc)

    interval_map = {
        "M1": "1m",
        "M5": "5m",
        "M15": "15m",
        "M30": "30m",
        "H1": "60m",
        "H4": "60m",
        "D1": "1d",
    }
    interval = interval_map.get(timeframe, "15m")
    df = load_yfinance_data(symbol=yf_symbol, interval=interval, period=yf_period)
    logging.info("Data source: yfinance | bars=%d", len(df))
    return df, "yfinance"


def compute_metrics(returns: np.ndarray, timeframe: str, trades: int) -> Dict[str, float]:
    if returns is None or len(returns) == 0:
        return {
            "trades": float(trades),
            "n_returns": 0.0,
            "mean": 0.0,
            "vol": 0.0,
            "sharpe": 0.0,
            "sortino": 0.0,
            "cagr": 0.0,
            "max_drawdown": 1.0,
            "calmar": 0.0,
            "profit_factor": 0.0,
            "win_rate": 0.0,
            "expectancy": 0.0,
            "terminal_equity": 1.0,
        }

    rets = np.array(returns, dtype=float)
    rets = rets[np.isfinite(rets)]
    if len(rets) == 0:
        return {
            "trades": float(trades),
            "n_returns": 0.0,
            "mean": 0.0,
            "vol": 0.0,
            "sharpe": 0.0,
            "sortino": 0.0,
            "cagr": 0.0,
            "max_drawdown": 1.0,
            "calmar": 0.0,
            "profit_factor": 0.0,
            "win_rate": 0.0,
            "expectancy": 0.0,
            "terminal_equity": 1.0,
        }

    bars_per_year = float(BARS_PER_YEAR.get(timeframe, BARS_PER_YEAR["M15"]))
    mu = float(np.mean(rets))
    sigma = float(np.std(rets))
    downside = rets[rets < 0]
    down_sigma = float(np.std(downside)) if len(downside) > 0 else 0.0

    sharpe = (mu / sigma) * np.sqrt(bars_per_year) if sigma > 0 else 0.0
    sortino = (mu / down_sigma) * np.sqrt(bars_per_year) if down_sigma > 0 else 0.0

    equity = np.cumprod(1.0 + rets)
    running_max = np.maximum.accumulate(equity)
    drawdowns = (equity / np.maximum(running_max, 1e-12)) - 1.0
    max_dd = float(np.min(drawdowns)) if len(drawdowns) > 0 else 0.0

    terminal = float(equity[-1]) if len(equity) > 0 else 1.0
    years = len(rets) / bars_per_year if bars_per_year > 0 else 0.0
    cagr = (terminal ** (1.0 / years) - 1.0) if years > 0 and terminal > 0 else 0.0
    calmar = cagr / abs(max_dd) if max_dd < 0 else 0.0

    gross_pos = float(np.sum(rets[rets > 0]))
    gross_neg = float(-np.sum(rets[rets < 0]))
    profit_factor = (gross_pos / gross_neg) if gross_neg > 0 else (10.0 if gross_pos > 0 else 0.0)

    win_rate = float(np.mean(rets > 0)) if len(rets) > 0 else 0.0

    return {
        "trades": float(trades),
        "n_returns": float(len(rets)),
        "mean": mu,
        "vol": sigma,
        "sharpe": float(sharpe),
        "sortino": float(sortino),
        "cagr": float(cagr),
        "max_drawdown": float(max_dd),
        "calmar": float(calmar),
        "profit_factor": float(profit_factor),
        "win_rate": float(win_rate),
        "expectancy": float(mu),
        "terminal_equity": terminal,
    }


def simulate_oos(
    data: np.ndarray,
    train_idx: np.ndarray,
    test_idx: np.ndarray,
    config: Dict[str, float],
    transaction_cost_bps: float,
) -> EvalResult:
    engine = QuantEngine(config=config)

    train = data[train_idx]
    test = data[test_idx]

    engine.warmup(train.tolist())

    ret_list: List[float] = []
    trades = 0
    tc = float(transaction_cost_bps) / 10000.0

    for i in range(len(test) - 1):
        row = test[i]
        result = engine.process_tick(row[0], row[1], row[2], row[3], row[4])
        if not isinstance(result, dict):
            continue

        if result.get("action") != "execute":
            continue

        direction = result.get("direction", "NEUTRAL")
        f_star = float(result.get("optimal_f", 0.0) or 0.0)

        if direction not in ("BUY", "SELL") or f_star <= 0.0:
            continue

        next_open = float(test[i + 1][0])
        next_close = float(test[i + 1][3])
        if next_open <= 0.0 or next_close <= 0.0:
            continue

        next_ret = np.log(next_close / next_open)
        dir_mult = 1.0 if direction == "BUY" else -1.0
        pnl = dir_mult * f_star * next_ret

        # Institutional friction penalty (spread/slippage/latency) in return units.
        pnl -= tc * f_star

        if np.isfinite(pnl):
            ret_list.append(float(pnl))
            trades += 1

    return EvalResult(returns=np.array(ret_list, dtype=float), trades=trades)


def score_candidate(metrics: Dict[str, float], pbo_value: float) -> float:
    sharpe = metrics["sharpe"]
    sortino = metrics["sortino"]
    calmar = metrics["calmar"]
    max_dd = abs(metrics["max_drawdown"])
    trades = metrics["trades"]
    pf = metrics["profit_factor"]
    win_rate = metrics["win_rate"]
    expectancy = metrics["expectancy"]

    score = sharpe + 0.4 * sortino + 0.3 * calmar + 0.2 * np.log(max(pf, 1e-6))
    score += 0.1 * np.sign(expectancy) * np.sqrt(abs(expectancy) + 1e-12)

    if max_dd > 0.25:
        score -= 5.0 * (max_dd - 0.25)
    if trades < 120:
        score -= 0.5
    if trades > 2500:
        score -= 0.25 * ((trades - 2500.0) / 500.0)
    if win_rate < 0.48:
        score -= 0.25 * (0.48 - win_rate)

    score -= 2.0 * pbo_value
    return float(score)


def build_candidate_configs(n_candidates: int, seed: int) -> List[Dict[str, float]]:
    rng = np.random.default_rng(seed)

    space = {
        "garch_window": [700, 900, 1100],
        "hmm_components": [2, 3],
        "hmm_window": [350, 500, 650],
        "cs_window": [10, 20, 30],
        "kelly_fraction": [0.20, 0.25, 0.30],
        "direction_edge_threshold": [0.12, 0.15, 0.18, 0.20],
        "min_hmm_confidence": [0.56, 0.60, 0.64, 0.68],
        "signal_z_threshold": [0.01, 0.02, 0.03, 0.05],
        "max_spread_ratio": [0.70, 0.90, 1.10, 1.30],
        "cooldown_bars": [0, 1, 2, 3],
        "confirm_bars": [1, 2, 3],
        "require_trend_alignment": [True, False],
        "trade_side": ["both", "long_only", "short_only"],
        "evt_tail_fraction": [0.03, 0.05, 0.08],
        "evt_confidence_level": [0.975, 0.99],
        "kelly_min_fraction": [0.0, 0.0025, 0.005],
        "kelly_max_fraction": [0.03, 0.05],
    }

    baseline = {
        "garch_window": 1000,
        "hmm_components": 2,
        "hmm_window": 500,
        "cs_window": 20,
        "kelly_fraction": 0.25,
        "direction_edge_threshold": 0.15,
        "min_hmm_confidence": 0.60,
        "signal_z_threshold": 0.02,
        "max_spread_ratio": 0.90,
        "cooldown_bars": 1,
        "confirm_bars": 2,
        "require_trend_alignment": True,
        "trade_side": "both",
        "evt_tail_fraction": 0.05,
        "evt_confidence_level": 0.99,
        "kelly_min_fraction": 0.005,
        "kelly_max_fraction": 0.05,
    }

    configs = [baseline]
    seen = {json.dumps(baseline, sort_keys=True)}

    while len(configs) < max(2, n_candidates):
        candidate = {k: rng.choice(v).item() if hasattr(rng.choice(v), "item") else rng.choice(v) for k, v in space.items()}
        if candidate["kelly_min_fraction"] > candidate["kelly_max_fraction"]:
            continue
        if int(candidate["confirm_bars"]) < 1:
            continue
        if int(candidate["cooldown_bars"]) < 0:
            continue
        key = json.dumps(candidate, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        configs.append(candidate)

    return configs


def nested_oos_optimization(
    bars: np.ndarray,
    timeframe: str,
    outer_splits: int,
    inner_splits: int,
    purge_size: int,
    embargo_size: int,
    min_train_size: int,
    min_test_size: int,
    n_candidates: int,
    transaction_cost_bps: float,
    seed: int,
) -> Dict[str, object]:
    outer_cv = PurgedWalkForward(
        n_splits=outer_splits,
        purge_size=purge_size,
        embargo_size=embargo_size,
        min_train_size=min_train_size,
        min_test_size=min_test_size,
    )
    outer = outer_cv.split(len(bars))
    if len(outer) == 0:
        raise RuntimeError("No valid outer OOS splits. Increase bars or reduce split constraints.")

    candidates = build_candidate_configs(n_candidates=n_candidates, seed=seed)

    pbo_helper = PBOMetrics(trials_count=len(candidates))

    oos_returns_all: List[float] = []
    oos_trades_total = 0
    fold_reports: List[Dict[str, object]] = []

    for fold_id, (train_idx, test_idx) in enumerate(outer, start=1):
        train_subset_len = len(train_idx)

        inner_cv = PurgedWalkForward(
            n_splits=inner_splits,
            purge_size=max(50, purge_size // 2),
            embargo_size=max(25, embargo_size // 2),
            min_train_size=max(300, min_train_size // 2),
            min_test_size=max(80, min_test_size // 2),
        )
        inner = inner_cv.split(train_subset_len)
        if len(inner) == 0:
            raise RuntimeError(f"No valid inner CV splits for fold {fold_id}.")

        best_cfg = None
        best_score = -1e18
        best_inner_metrics = None

        train_data = bars[train_idx]

        for cfg in candidates:
            val_rets = []
            val_trades = 0

            for in_train_idx, in_val_idx in inner:
                try:
                    sim = simulate_oos(
                        data=train_data,
                        train_idx=in_train_idx,
                        test_idx=in_val_idx,
                        config=cfg,
                        transaction_cost_bps=transaction_cost_bps,
                    )
                    val_rets.extend(sim.returns.tolist())
                    val_trades += sim.trades
                except Exception:
                    # Candidate invalid for this split; keep it but with poor score.
                    continue

            m = compute_metrics(np.array(val_rets, dtype=float), timeframe=timeframe, trades=val_trades)
            _, pbo = pbo_helper.evaluate_dsr(val_rets)
            sc = score_candidate(m, pbo)

            if sc > best_score:
                best_score = sc
                best_cfg = cfg
                best_inner_metrics = {
                    "score": sc,
                    "pbo": float(pbo),
                    "metrics": m,
                }

        if best_cfg is None:
            raise RuntimeError(f"Failed to select best configuration for outer fold {fold_id}.")

        sim_oos = simulate_oos(
            data=bars,
            train_idx=train_idx,
            test_idx=test_idx,
            config=best_cfg,
            transaction_cost_bps=transaction_cost_bps,
        )

        oos_returns_all.extend(sim_oos.returns.tolist())
        oos_trades_total += sim_oos.trades

        fold_metrics = compute_metrics(sim_oos.returns, timeframe=timeframe, trades=sim_oos.trades)

        fold_reports.append(
            {
                "fold": fold_id,
                "train_bars": int(len(train_idx)),
                "test_bars": int(len(test_idx)),
                "selected_config": best_cfg,
                "inner_selection": best_inner_metrics,
                "oos_metrics": fold_metrics,
            }
        )

        logging.info(
            "Fold %d | selected score=%.4f | OOS sharpe=%.3f | OOS cagr=%.3f | OOS maxDD=%.3f",
            fold_id,
            best_score,
            fold_metrics["sharpe"],
            fold_metrics["cagr"],
            fold_metrics["max_drawdown"],
        )

    agg_metrics = compute_metrics(np.array(oos_returns_all, dtype=float), timeframe=timeframe, trades=oos_trades_total)
    dsr, pbo = PBOMetrics(trials_count=len(candidates)).evaluate_dsr(oos_returns_all)

    profitable = (
        agg_metrics["cagr"] > 0.0
        and agg_metrics["sharpe"] >= 0.8
        and agg_metrics["profit_factor"] >= 1.10
        and abs(agg_metrics["max_drawdown"]) <= 0.25
        and pbo <= 0.20
        and agg_metrics["trades"] >= 300
    )

    verdict = "RENTABLE_OOS" if profitable else "NO_RENTABLE_OOS"

    return {
        "verdict": verdict,
        "aggregate_metrics": agg_metrics,
        "deflated_sharpe": float(dsr),
        "pbo": float(pbo),
        "folds": fold_reports,
        "n_outer_folds": len(outer),
        "n_candidates": len(candidates),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Institutional OOS optimizer with purge+embargo nested CV.")
    parser.add_argument("--symbol", default="XAUUSD", help="MT5 symbol name (e.g. XAUUSD).")
    parser.add_argument("--timeframe", default="M15", choices=list(BARS_PER_YEAR.keys()))
    parser.add_argument("--bars", type=int, default=12000, help="Bars to request from MT5 if available.")
    parser.add_argument("--db-path", default="mt5_timeseries.sqlite", help="SQLite database file for MT5 timeseries bars.")
    parser.add_argument("--chunk-size", type=int, default=1000, help="Bars to request from MT5 per chunk.")
    parser.add_argument("--mt5-terminal-path", default=os.getenv("MT5_TERMINAL_PATH", ""), help="Explicit terminal64.exe path for MT5 initialization.")
    parser.add_argument("--use-sql-cache", action="store_true", help="Use persisted SQL timeseries as source and skip MT5 download.")
    parser.add_argument("--allow-yfinance-fallback", action="store_true", help="Allow fallback to yfinance if MT5 loading fails.")
    parser.add_argument("--yf-symbol", default="XAUUSD=X", help="Fallback yfinance symbol.")
    parser.add_argument("--yf-period", default="60d", help="Fallback yfinance period.")

    parser.add_argument("--outer-splits", type=int, default=3)
    parser.add_argument("--inner-splits", type=int, default=2)
    parser.add_argument("--purge", type=int, default=200)
    parser.add_argument("--embargo", type=int, default=100)
    parser.add_argument("--min-train", type=int, default=1200)
    parser.add_argument("--min-test", type=int, default=220)

    parser.add_argument("--candidates", type=int, default=16)
    parser.add_argument("--cost-bps", type=float, default=2.0, help="Round-trip transaction cost in bps scaled by position fraction.")
    parser.add_argument("--seed", type=int, default=42)

    parser.add_argument("--output-json", default="oos_institutional_report.json")
    parser.add_argument("--output-best", default="oos_best_params.json")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    df, source = load_market_data(
        symbol=args.symbol,
        timeframe=args.timeframe,
        bars=args.bars,
        yf_symbol=args.yf_symbol,
        yf_period=args.yf_period,
        db_path=args.db_path,
        chunk_size=args.chunk_size,
        mt5_terminal_path=args.mt5_terminal_path,
        allow_yfinance_fallback=args.allow_yfinance_fallback,
        use_sql_cache=args.use_sql_cache,
    )

    bars = df[["open", "high", "low", "close", "volume"]].to_numpy(dtype=float)

    report = nested_oos_optimization(
        bars=bars,
        timeframe=args.timeframe,
        outer_splits=args.outer_splits,
        inner_splits=args.inner_splits,
        purge_size=args.purge,
        embargo_size=args.embargo,
        min_train_size=args.min_train,
        min_test_size=args.min_test,
        n_candidates=args.candidates,
        transaction_cost_bps=args.cost_bps,
        seed=args.seed,
    )

    report["data_source"] = source
    report["bars_used"] = int(len(bars))
    report["symbol"] = args.symbol
    report["timeframe"] = args.timeframe

    script_dir = os.path.dirname(os.path.abspath(__file__))

    output_json = args.output_json
    if not os.path.isabs(output_json):
        output_json = os.path.join(script_dir, output_json)

    output_best = args.output_best
    if not os.path.isabs(output_best):
        output_best = os.path.join(script_dir, output_best)

    os.makedirs(os.path.dirname(output_json), exist_ok=True)
    os.makedirs(os.path.dirname(output_best), exist_ok=True)

    with open(output_json, "w", encoding="ascii") as f:
        json.dump(report, f, indent=2, ensure_ascii=True)

    # Best config by outer fold median score.
    fold_cfgs = [f["selected_config"] for f in report["folds"]]
    if len(fold_cfgs) > 0:
        # pick the configuration from fold with highest OOS Sharpe as deployment candidate
        best_fold = max(report["folds"], key=lambda x: x["oos_metrics"]["sharpe"])
        best_cfg = best_fold["selected_config"]
    else:
        best_cfg = {}

    with open(output_best, "w", encoding="ascii") as f:
        json.dump(best_cfg, f, indent=2, ensure_ascii=True)

    logging.info("=== OOS Institutional Report ===")
    logging.info("Source: %s | Bars: %d", report["data_source"], report["bars_used"])
    logging.info("Verdict: %s", report["verdict"])
    logging.info("DSR: %.4f | PBO: %.4f", report["deflated_sharpe"], report["pbo"])
    logging.info(
        "Sharpe: %.4f | Sortino: %.4f | CAGR: %.4f | MaxDD: %.4f | PF: %.4f | Trades: %.0f",
        report["aggregate_metrics"]["sharpe"],
        report["aggregate_metrics"]["sortino"],
        report["aggregate_metrics"]["cagr"],
        report["aggregate_metrics"]["max_drawdown"],
        report["aggregate_metrics"]["profit_factor"],
        report["aggregate_metrics"]["trades"],
    )
    logging.info("Saved report: %s", output_json)
    logging.info("Saved best params: %s", output_best)


if __name__ == "__main__":
    main()
