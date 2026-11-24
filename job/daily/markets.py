"""Index levels and Nifty 50 movers at the previous close.

Uses Yahoo Finance's public chart endpoint (no key, unofficial). Any failure
just leaves the numbers out.
"""
import json
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

CHART = "https://query1.finance.yahoo.com/v8/finance/chart/{}?range=5d&interval=1d"


def quote(fetcher, symbol):
    """-> {symbol, price, change, change_pct, time} or None."""
    try:
        r = fetcher.get(CHART.format(urllib.parse.quote(symbol, safe="")), accept="application/json")
        res = json.loads(r.body)["chart"]["result"][0]
        closes = [c for c in res["indicators"]["quote"][0]["close"] if c is not None]
        if len(closes) < 2:
            return None
        last, prev = closes[-1], closes[-2]
        return {
            "symbol": symbol,
            "price": round(last, 2),
            "change": round(last - prev, 2),
            "change_pct": round((last - prev) / prev * 100, 2),
            "time": res.get("meta", {}).get("regularMarketTime"),
        }
    except Exception:
        return None


def collect(fetcher, cfg):
    if not cfg:
        return None, "not configured"
    indices = []
    for ix in cfg.get("indices", []):
        q = quote(fetcher, ix["symbol"])
        if q:
            indices.append({"name": ix["name"], **q})
    universe = cfg.get("universe", [])
    if cfg.get("indices") and not indices:
        return None, "no market data (Yahoo endpoint unavailable?)"  # don't try 50 more
    with ThreadPoolExecutor(max_workers=4) as pool:
        quotes = [q for q in pool.map(lambda s: quote(fetcher, s + ".NS"), universe) if q]
    for q in quotes:
        q["name"] = q["symbol"].removesuffix(".NS")
    if not indices and not quotes:
        return None, "no market data (Yahoo endpoint unavailable?)"
    n = int(cfg.get("movers", 5))
    quotes.sort(key=lambda q: -q["change_pct"])
    times = [q["time"] for q in indices + quotes if q.get("time")]
    data = {
        "indices": indices,
        "gainers": [q for q in quotes[:n] if q["change_pct"] > 0],
        "losers": [q for q in reversed(quotes[-n:]) if q["change_pct"] < 0],
        "as_of": max(times) if times else None,
        "covered": f"{len(quotes)} of {len(universe)} Nifty 50 stocks",
        "missing": sorted(set(universe) - {q["name"] for q in quotes}),
    }
    return data, None
