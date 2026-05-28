---
name: spacex-spread
description: Compare SPACEX implied valuation between Ventuals (Hyperliquid perp dex=vntl, coin=vntl:SPACEX) and PreStocks (token symbol=SPACEX). Prints prices, implied valuations, and spread%. Use when user asks about SPACEX VNTL vs PreStocks price difference, implied valuation arbitrage, or pre-IPO valuation spread.
---

# spacex-spread

Compare SPACEX implied valuation across two markets and report spread%.

## Sources

| Market | Endpoint | Field |
|--------|----------|-------|
| Ventuals (Hyperliquid) | `POST https://api.hyperliquid.xyz/info` body `{"type":"metaAndAssetCtxs","dex":"vntl"}` | `ctxs[i].markPx` where `meta.universe[i].name=="vntl:SPACEX"`. Unit: USD billions (scaleFactor=1e9). |
| PreStocks token price | `GET https://prestocks.com/api/metrics` | `metrics[].symbol=="SPACEX" .tokenPrice` (USD per token). |
| PreStocks baseline | `GET https://prestocks.com/spacex` (HTML, regex SSR payload) | `baselinePrice`, `baselineValuationBillions`. |

## Formulas

```
vntl_implied_val      = markPx * 1e9
prestocks_implied_val = tokenPrice / baselinePrice * baselineValuationBillions * 1e9
spread_pct            = (vntl - prestocks) / prestocks * 100
```

## Run

```bash
bash .claude/skills/spacex-spread/spread.sh
```

No args. Plain-text table output.

**Deps**: `curl`, `python3` (stdlib only). No `jq`.

**Network**: Requires reachability to `api.hyperliquid.xyz` and `prestocks.com`. HL is SNI-filtered in some networks (e.g. GFW) — run from a location with reachability (overseas VM).

## Env vars (optional, all loaded from `~/.config/spacex-spread.env` or `$SPACEX_SPREAD_ENV`)

| Var | Purpose |
|-----|---------|
| `TELEGRAM_TOKEN` / `TELEGRAM_CHAT_ID` | Push report to Telegram when `\|spread\|` ≥ threshold |
| `ALARM_THRESHOLD_PCT` | Threshold for TG alarm (default `10`) |

## History + dashboard

Each run appends a sample to `docs/data.json`. `docs/index.html` renders a Plotly dashboard reading `data.json` — host the `docs/` dir via any static web server (e.g. nginx serving `~/apps/spacex-spread/docs/`).
