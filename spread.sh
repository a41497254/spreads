#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPACEX_SPREAD_ENV:-$HOME/.config/spacex-spread.env}"
[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
DATA_JSON="${SCRIPT_DIR}/docs/data.json"
STATE_FILE="${HOME}/.cache/spacex-spread.alarm"
mkdir -p "$(dirname "$STATE_FILE")"

HL=$(mktemp); PSJ=$(mktemp); PSH=$(mktemp); CHUNK=$(mktemp)
BVNTL=$(mktemp); BPRE=$(mktemp); OKX=$(mktemp)
trap 'rm -f "$HL" "$PSJ" "$PSH" "$CHUNK" "$BVNTL" "$BPRE" "$OKX"' EXIT

curl -sSf -X POST https://api.hyperliquid.xyz/info \
  -H 'Content-Type: application/json' \
  -d '{"type":"metaAndAssetCtxs","dex":"vntl"}' -o "$HL" &
curl -sSf https://prestocks.com/api/metrics -H 'Accept: application/json' -o "$PSJ" &
curl -sSf -A 'Mozilla/5.0' -L https://prestocks.com/spacex -o "$PSH" &
curl -sS --max-time 8 -G "https://open-api.bingx.com/openApi/swap/v1/ticker/price" \
  --data-urlencode "symbol=NCSKSPACEXV2USD-USDT" -o "$BVNTL" &
curl -sS --max-time 8 -G "https://open-api.bingx.com/openApi/swap/v1/ticker/price" \
  --data-urlencode "symbol=NCSKSPACEXP2USD-USDT" -o "$BPRE" &
curl -sS --max-time 8 "https://www.okx.com/api/v5/market/ticker?instId=SPACEX-USDT-SWAP" -o "$OKX" &
wait

# PreStocks baseline is hardcoded in a JS chunk (id 170, hashed). Find it from HTML.
CHUNK_PATH=$(grep -oE '/_next/static/chunks/170-[a-f0-9]+\.js' "$PSH" | head -1)
if [[ -z "$CHUNK_PATH" ]]; then
  echo "ERR: baseline chunk url not found in /spacex HTML" >&2; exit 1
fi
curl -sSf "https://prestocks.com${CHUNK_PATH}" -o "$CHUNK"

REPORT=$(python3 - "$HL" "$PSJ" "$CHUNK" "$DATA_JSON" "$BVNTL" "$BPRE" "$OKX" <<'PY'
import json, re, sys, datetime, os
hl_f, ps_j, chunk_f, data_f, bvntl_f, bpre_f, okx_f = sys.argv[1:]

def safe_load(p):
    try: return json.load(open(p))
    except (json.JSONDecodeError, OSError): return None

def bingx_price(d):
    if d and d.get("code") == 0 and d.get("data", {}).get("price"):
        return float(d["data"]["price"])
    return None

def okx_price(d):
    if d and d.get("code") == "0" and d.get("data"):
        return float(d["data"][0]["last"])
    return None

bvntl = bingx_price(safe_load(bvntl_f))
bpre  = bingx_price(safe_load(bpre_f))
okx   = okx_price(safe_load(okx_f))

meta, ctxs = json.load(open(hl_f))
idx = next(i for i, u in enumerate(meta["universe"]) if u["name"] == "vntl:SPACEX")
vmark = float(ctxs[idx]["markPx"])
vorac = float(ctxs[idx].get("oraclePx") or vmark)

ps = json.load(open(ps_j))
pp  = float(next(m for m in ps["metrics"] if m["symbol"] == "SPACEX")["tokenPrice"])

chunk = open(chunk_f).read()
m = re.search(r'"symbol":"SPACEX"[\s\S]*?"baselinePrice":([0-9.]+)[\s\S]*?"baselineValuationBillions":([0-9.]+)', chunk)
if not m:
    sys.exit("ERR: baselinePrice/baselineValuationBillions not found in chunk")
bp, bv = float(m.group(1)), float(m.group(2))

vval = vmark * 1e9
pval = pp / bp * bv * 1e9
spread = (vval - pval) / pval * 100

ts = int(datetime.datetime.now(datetime.UTC).timestamp())
os.makedirs(os.path.dirname(data_f), exist_ok=True)
hist = []
if os.path.exists(data_f):
    try: hist = json.load(open(data_f))
    except json.JSONDecodeError: hist = []
hist.append({"ts": ts, "vmark": vmark, "vorac": vorac, "pp": pp, "bp": bp, "bv": bv,
             "vval": round(vval), "pval": round(pval), "spread": round(spread, 4),
             "bvntl": bvntl, "bpre": bpre, "okx": okx})
with open(data_f, "w") as f: json.dump(hist, f, separators=(",", ":"))

def fmt(v):
    if v >= 1e12: return f"${v/1e12:.3f}T"
    if v >= 1e9:  return f"${v/1e9:.3f}B"
    return f"${v/1e6:.2f}M"

now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%FT%T")
print(f"\nSPACEX implied valuation (GMT+8 {now})\n")
print(f"{'Source':<22} {'Price':<22} Implied Val")
print(f"{'-'*22} {'-'*14} {'-'*11}")
print(f"{'VNTL mark (HL perp)':<22} {f'{vmark} B':<22} {fmt(vval)}")
print(f"{'VNTL oracle':<22} {f'{vorac} B':<22} -")
print(f"{'PreStocks token':<22} {f'${pp:.2f}/tok':<22} {fmt(pval)}")
print(f"{'BingX VNTL perp':<22} {f'{bvntl} USDT' if bvntl else 'n/a':<22} -")
print(f"{'BingX PreStocks perp':<22} {f'{bpre} USDT' if bpre else 'PAUSED':<22} -")
print(f"{'OKX SPACEX-USDT-SWAP':<22} {f'{okx} USDT' if okx else 'n/a':<22} -")
print(f"\nBaseline : ${bp:.3f}/tok = ${bv:g}B  (implied {bv/bp*pp:.2f}B from current price)")
print(f"Spread   : {spread:+.3f}%  (VNTL vs PreStocks)")
print(f"SPREAD_PCT={spread:.4f}")
PY
)

SPREAD_PCT=$(printf "%s\n" "$REPORT" | grep -oE 'SPREAD_PCT=-?[0-9.]+' | tail -1 | cut -d= -f2)
REPORT_TEXT=$(printf "%s\n" "$REPORT" | grep -v '^SPREAD_PCT=')
printf "%s\n" "$REPORT_TEXT"

THRESHOLD="${ALARM_THRESHOLD_PCT:-10}"
COOLDOWN_SEC="${ALARM_COOLDOWN_SEC:-3600}"

ZONE=$(awk -v s="$SPREAD_PCT" -v t="$THRESHOLD" 'BEGIN{
  if (s >= t) print "SELL"
  else if (s <= -t) print "BUY"
  else if (s >= 0) print "SELL_NEUTRAL"
  else print "BUY_NEUTRAL"
}')

NOW=$(date +%s)
PREV_LINE=$(cat "$STATE_FILE" 2>/dev/null || echo "0 NONE")
PREV_TS=$(echo "$PREV_LINE" | awk '{print $1}')
PREV_ZONE=$(echo "$PREV_LINE" | awk '{print $2}')
SINCE=$((NOW - PREV_TS))

ALARM=0; REASON=""
if [[ "$ZONE" != "$PREV_ZONE" ]]; then
  ALARM=1; REASON="${PREV_ZONE}->${ZONE}"
elif [[ "$ZONE" == "SELL" || "$ZONE" == "BUY" ]] && (( SINCE >= COOLDOWN_SEC )); then
  ALARM=1; REASON="${ZONE} cooldown"
fi

NEW_TS="$PREV_TS"
if [[ "$ALARM" == "1" && -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  for CID in "${TELEGRAM_CHAT_ID}" "1097513088"; do
    curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${CID}" \
      --data-urlencode "parse_mode=HTML" \
      --data-urlencode "text=ALARM ${ZONE} spread=${SPREAD_PCT}% (${REASON})
<pre>${REPORT_TEXT}</pre>" \
      >/dev/null
  done
  NEW_TS="$NOW"
elif [[ "$ALARM" == "1" ]]; then
  echo "ALARM ${REASON} but TG not configured" >&2
elif [[ "$ZONE" == "SELL" || "$ZONE" == "BUY" ]]; then
  echo "ALARM suppressed ${ZONE} (cooldown ${SINCE}s < ${COOLDOWN_SEC}s)" >&2
fi
echo "$NEW_TS $ZONE" > "$STATE_FILE"

