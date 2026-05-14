import json
import numpy as np

from quant_server import QuantEngine


def _synthetic_bars(n=1200):
    np.random.seed(42)
    closes = [2000.0]
    for _ in range(n - 1):
        closes.append(closes[-1] * float(np.exp(np.random.normal(0, 0.0008))))

    bars = []
    for c in closes:
        bars.append([c - 0.2, c + 0.4, c - 0.4, c, 100])
    return bars


def main():
    engine = QuantEngine()
    bars = _synthetic_bars(1200)
    engine.warmup(bars)
    out = engine.process_tick(*bars[-1])

    ok = out.get("action") == "execute"
    report = {
        "preflight": "ok" if ok else "fail",
        "direction": out.get("direction", "NEUTRAL"),
        "optimal_f": out.get("optimal_f", 0.0),
        "stop_loss_dist": out.get("stop_loss_dist", 0.0),
    }
    print(json.dumps(report, ensure_ascii=True))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
