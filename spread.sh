#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPACEX_SPREAD_ENV:-$HOME/.config/spacex-spread.env}"
[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
DATA_JSON="${SCRIPT_DIR}/docs/data.json"

HL=$(mktemp); PSJ=$(mktemp); PSH=$(mktemp); CHUNK=$(mktemp)
trap 'rm -f "$HL" "$PSJ" "$PSH" "$CHUNK"' EXIT

curl -sSf -X POST https://api.hyperliquid.xyz/info \
  -H 'Content-Type: application/json' \
  -d '{"type":"metaAndAssetCtxs","dex":"vntl"}' -o "$HL" &
curl -sSf https://prestocks.com/api/metrics -H 'Accept: application/json' -o "$PSJ" &
curl -sSf -A 'Mozilla/5.0' -L https://prestocks.com/spacex -o "$PSH" &
wait

# PreStocks baseline is hardcoded in a JS chunk (id 170, hashed). Find it from HTML.
CHUNK_PATH=$(grep -oE '/_next/static/chunks/170-[a-f0-9]+\.js' "$PSH" | head -1)
if [[ -z "$CHUNK_PATH" ]]; then
  echo "ERR: baseline chunk url not found in /spacex HTML" >&2; exit 1
fi
curl -sSf "https://prestocks.com${CHUNK_PATH}" -o "$CHUNK"

REPORT=$(python3 - "$HL" "$PSJ" "$CHUNK" "$DATA_JSON" <<'PY'
import json, re, sys, datetime, os
hl_f, ps_j, chunk_f, data_f = sys.argv[1:]

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
             "vval": round(vval), "pval": round(pval), "spread": round(spread, 4)})
with open(data_f, "w") as f: json.dump(hist, f, separators=(",", ":"))

def fmt(v):
    if v >= 1e12: return f"${v/1e12:.3f}T"
    if v >= 1e9:  return f"${v/1e9:.3f}B"
    return f"${v/1e6:.2f}M"

now = datetime.datetime.now(datetime.UTC).strftime("%FT%TZ")
print(f"\nSPACEX implied valuation (UTC {now})\n")
print(f"{'Source':<22} {'Price':<22} Implied Val")
print(f"{'-'*22} {'-'*22} {'-'*11}")
print(f"{'VNTL mark (HL perp)':<22} {f'{vmark} B':<22} {fmt(vval)}")
print(f"{'VNTL oracle':<22} {f'{vorac} B':<22} -")
print(f"{'PreStocks token':<22} {f'${pp:.2f}/tok':<22} {fmt(pval)}")
print(f"\nBaseline : ${bp:.3f}/tok = ${bv:g}B  (implied {bv/bp*pp:.2f}B from current price)")
print(f"Spread   : {spread:+.3f}%  (VNTL vs PreStocks)")
print(f"SPREAD_PCT={spread:.4f}")
PY
)

SPREAD_PCT=$(printf "%s\n" "$REPORT" | grep -oE 'SPREAD_PCT=-?[0-9.]+' | tail -1 | cut -d= -f2)
REPORT_TEXT=$(printf "%s\n" "$REPORT" | grep -v '^SPREAD_PCT=')
printf "%s\n" "$REPORT_TEXT"

THRESHOLD="${ALARM_THRESHOLD_PCT:-10}"
ABS=$(awk -v s="$SPREAD_PCT" 'BEGIN{print (s<0)?-s:s}')
ALARM=$(awk -v a="$ABS" -v t="$THRESHOLD" 'BEGIN{print (a>=t)?1:0}')

if [[ "$ALARM" == "1" && -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=ALARM |spread|=${ABS}% >= ${THRESHOLD}%
<pre>${REPORT_TEXT}</pre>" \
    >/dev/null
fi

