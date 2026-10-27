#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TS_DIR="$ROOT/scriptc"
OUT="$TS_DIR/build/bench"
RUNS="${RUNS:-50}"
rm -rf "$OUT"
mkdir -p "$OUT"
export LANG=en_US.UTF-8

ZIG_BIN="$OUT/zig/bin/popzlip"
TS_BIN="$TS_DIR/build/popzlip"

seconds() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

echo "== build (clean)"
t0=$(seconds)
(cd "$ROOT" && zig build -Doptimize=ReleaseFast --prefix "$OUT/zig" --cache-dir "$OUT/zig-cache" >/dev/null)
t1=$(seconds)
(cd "$TS_DIR" && rm -rf build/popzlip build/libpopzlip_shim.a build/PopzlipTS.app && ./build.sh >/dev/null)
t2=$(seconds)
zig_build=$(echo "$t1 - $t0" | bc)
ts_build=$(echo "$t2 - $t1" | bc)
zig_size=$(stat -f %z "$ZIG_BIN")
ts_size=$(stat -f %z "$TS_BIN")

echo "== hyperfine: CLI startup (config get)"
hyperfine -N --warmup 5 --runs "$RUNS" --export-json "$OUT/startup.json" \
  -n zig "$ZIG_BIN config get search_engine" \
  -n scriptc "$TS_BIN config get search_engine"

MCP_ZIG="$OUT/mcp-zig.jsonl"
MCP_TS="$OUT/mcp-ts.jsonl"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_actions","arguments":{"text":"https://github.com/vercel-labs/scriptc"}}}' \
  >"$MCP_ZIG"
cp "$MCP_ZIG" "$MCP_TS"

echo "== hyperfine: MCP session (initialize, tools/list, list_actions)"
hyperfine -N --input "$MCP_ZIG" --warmup 5 --runs "$RUNS" --export-json "$OUT/mcp.json" \
  -n zig "$ZIG_BIN --mcp" \
  -n scriptc "$TS_BIN --mcp"

peak_rss_kb() { /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/maximum resident set size/ {printf "%d\n", $1 / 1024}'; }
popup_rss_kb() {
  "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep 1.5
  local rss
  rss=$(ps -o rss= -p "$pid" | tr -d ' ')
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "${rss:-0}"
}

echo "== memory"
zig_cli_rss=$(peak_rss_kb "$ZIG_BIN" config get search_engine)
ts_cli_rss=$(peak_rss_kb "$TS_BIN" config get search_engine)
zig_mcp_rss=$(peak_rss_kb sh -c "$ZIG_BIN --mcp < $MCP_ZIG")
ts_mcp_rss=$(peak_rss_kb sh -c "$TS_BIN --mcp < $MCP_TS")
zig_popup_rss=$(popup_rss_kb "$ZIG_BIN" --simulate "Initial Line")
ts_popup_rss=$(popup_rss_kb "$TS_BIN" --simulate "Initial Line" --exit-after 5000)

echo "== scriptc popup latency and engine"
popup_ms=()
for _ in 1 2 3 4 5; do
  popup_ms+=("$("$TS_BIN" --simulate "Initial Line" --trace --exit-after 200 2>&1 | awk '/startup to popup/ {print $5}')")
done
engine=$("$TS_BIN" bench-engine 200000 "https://github.com/vercel-labs/scriptc")

wall() { jq -r --arg n "$2" '.results[] | select(.name == $n) | .summary.time_wall_clock' "$1"; }
mean_ms() { wall "$1" "$2" | jq -r '"\(.mean * 1e5 | round / 100) ± \(.stddev * 1e5 | round / 100)"'; }
min_ms() { wall "$1" "$2" | jq -r '.min * 1e5 | round / 100'; }
minstr() { jq -r --arg n "$2" '.results[] | select(.name == $n) | .summary.instructions.mean / 1e4 | round / 100' "$1"; }

REPORT="$TS_DIR/bench/results.txt"
{
  echo "popzlip benchmark: Zig (ReleaseFast) vs scriptc"
  echo "date: $(date '+%Y-%m-%d %H:%M')  host: $(sysctl -n machdep.cpu.brand_string)  macOS $(sw_vers -productVersion)"
  echo "runs per hyperfine case: $RUNS"
  echo
  printf '%-34s %18s %18s\n' "metric" "zig" "scriptc"
  printf '%-34s %18s %18s\n' "build, warm toolchain cache (s)" "$zig_build" "$ts_build"
  printf '%-34s %18s %18s\n' "binary size (KB)" "$((zig_size / 1024))" "$((ts_size / 1024))"
  printf '%-34s %18s %18s\n' "CLI startup mean (ms)" "$(mean_ms "$OUT/startup.json" zig)" "$(mean_ms "$OUT/startup.json" scriptc)"
  printf '%-34s %18s %18s\n' "CLI startup min (ms)" "$(min_ms "$OUT/startup.json" zig)" "$(min_ms "$OUT/startup.json" scriptc)"
  printf '%-34s %18s %18s\n' "CLI startup instructions (M)" "$(minstr "$OUT/startup.json" zig)" "$(minstr "$OUT/startup.json" scriptc)"
  printf '%-34s %18s %18s\n' "MCP 3-request session mean (ms)" "$(mean_ms "$OUT/mcp.json" zig)" "$(mean_ms "$OUT/mcp.json" scriptc)"
  printf '%-34s %18s %18s\n' "MCP session instructions (M)" "$(minstr "$OUT/mcp.json" zig)" "$(minstr "$OUT/mcp.json" scriptc)"
  printf '%-34s %18s %18s\n' "CLI peak RSS (MB)" "$((zig_cli_rss / 1024))" "$((ts_cli_rss / 1024))"
  printf '%-34s %18s %18s\n' "MCP peak RSS (MB)" "$((zig_mcp_rss / 1024))" "$((ts_mcp_rss / 1024))"
  printf '%-34s %18s %18s\n' "popup shown, resident (MB)" "$((zig_popup_rss / 1024))" "$((ts_popup_rss / 1024))"
  echo
  echo "scriptc startup-to-popup (ms, 5 runs): ${popup_ms[*]}"
  echo "scriptc action engine: $engine"
  echo
  printf '%-34s %18s %18s\n' "feature" "zig" "scriptc"
  printf '%-34s %18s %18s\n' "append CLI writes the clipboard" "no (prints only)" "yes"
  printf '%-34s %18s %18s\n' "config set persists" "no" "yes"
  printf '%-34s %18s %18s\n' "MCP get_selection" "stub" "AX selection"
  printf '%-34s %18s %18s\n' "MCP replies JSON-escaped" "no" "yes"
  printf '%-34s %18s %18s\n' "search uses configured engine" "no" "yes"
  printf '%-34s %18s %18s\n' "popup trace and test hooks" "no" "--trace --press"
  printf '%-34s %18s %18s\n' "unit tests" "zig test" "bun test (43)"
} | tee "$REPORT"
