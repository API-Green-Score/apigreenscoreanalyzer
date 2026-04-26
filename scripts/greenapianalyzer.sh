#!/usr/bin/env bash
###############################################################################
#  greenapianalyzer.sh
#  ───────────────────
#  Non-interactive runner used by the interactive dashboard
#  (dashboard/interactive.html → scripts/greenapianalyzer-server.py).
#
#  Mirrors the FULL pipeline of `start.sh` (the canonical local runner) but
#  stripped of the parts that don't make sense from a UI:
#    – no docker / podman compose
#    – no creedengo (kept opt-in)
#    – no Ctrl+C wait at the end
#
#  Pipeline (same order & same scripts as start.sh):
#    1. Parse --targets / --swaggers / --bearer / --appname / --repeat …
#    2. Wait for every target on a health-check path
#       (/actuator/health, /health, /healthz, /ping, /).
#    3. Export TARGET_URL / SWAGGER_URL / BEARER_TOKEN / APPNAME / REPEAT
#       and delegate to scripts/green-score-analyzer_withdiscovery.sh
#       (which itself drives green-api-auto-discover.py — exactly what
#       start.sh does).
#    4. Re-generate badge + dashboard via scripts/generate-*.sh.
#
#  Options:
#    --targets   <csv>      Comma-separated list of API base URLs (required)
#    --swaggers  <csv>      Optional comma-separated OpenAPI specs
#    --bearer    <token>    Optional Bearer token for protected endpoints
#    --appname   <name>     App name embedded in the report
#    --repeat    <n>        Number of repetitions per endpoint (default: 3)
#    --methods   <csv>      HTTP methods to measure (kept for CLI compat)
#    --output-dir <dir>     Where to write reports (default: <root>/reports)
#    --skip-wait            Don't wait for targets
#    --skip-dashboard       Don't regenerate dashboard/index.html at the end
#    --debug                Verbose output
###############################################################################
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TARGETS=""
SWAGGERS=""
BEARER=""
APPNAME=""
REPEAT="3"
METHODS="get,post,put,patch,delete"
OUTPUT_DIR="$ROOT/reports"
DEBUG=""
SKIP_WAIT=false
SKIP_DASHBOARD=false

while [ $# -gt 0 ]; do
  case "$1" in
    --targets)        TARGETS="${2:-}";    shift 2 ;;
    --swaggers)       SWAGGERS="${2:-}";   shift 2 ;;
    --bearer)         BEARER="${2:-}";     shift 2 ;;
    --appname)        APPNAME="${2:-}";    shift 2 ;;
    --repeat)         REPEAT="${2:-3}";    shift 2 ;;
    --methods)        METHODS="${2:-}";    shift 2 ;;
    --output-dir)     OUTPUT_DIR="${2:-}"; shift 2 ;;
    --skip-wait)      SKIP_WAIT=true;      shift ;;
    --skip-dashboard) SKIP_DASHBOARD=true; shift ;;
    --debug)          DEBUG="--debug";     shift ;;
    -h|--help)        sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$TARGETS" ]; then
  echo "❌ --targets is required (comma-separated list of API base URLs)" >&2
  exit 2
fi

APPNAME="${APPNAME:-$(basename "$ROOT")}"
mkdir -p "$OUTPUT_DIR"

ANALYZER_WRAPPER="$ROOT/scripts/green-score-analyzer_withdiscovery.sh"
AUTODISCOVER_PY="$ROOT/scripts/green-api-auto-discover.py"
GENERATE_DASH="$ROOT/scripts/generate-dashboard.sh"
GENERATE_BADGE="$ROOT/scripts/generate-badge.sh"

if [ ! -f "$ANALYZER_WRAPPER" ]; then
  echo "❌ green-score-analyzer_withdiscovery.sh not found at: $ANALYZER_WRAPPER" >&2
  exit 1
fi
if [ ! -f "$AUTODISCOVER_PY" ]; then
  echo "❌ green-api-auto-discover.py not found at: $AUTODISCOVER_PY" >&2
  exit 1
fi

# ── Parse comma-separated lists into arrays (trim whitespace) ──
TARGET_ARR=()
IFS=',' read -r -a _t <<< "$TARGETS"
for v in "${_t[@]}"; do
  v_trim="$(echo "$v" | xargs)"
  [ -n "$v_trim" ] && TARGET_ARR+=("$v_trim")
done

SWAGGER_ARR=()
if [ -n "$SWAGGERS" ]; then
  IFS=',' read -r -a _s <<< "$SWAGGERS"
  for v in "${_s[@]}"; do
    v_trim="$(echo "$v" | xargs)"
    [ -n "$v_trim" ] && SWAGGER_ARR+=("$v_trim")
  done
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  🌿 Green API Score Analyzer (interactive bridge wrapper)   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "   • targets : ${TARGETS}"
if [ -n "$SWAGGERS" ]; then
  echo "   • swaggers: ${SWAGGERS}"
else
  echo "   • swaggers: <auto>"
fi
echo "   • appname : ${APPNAME}"
echo "   • repeat  : ${REPEAT}"
echo "   • output  : ${OUTPUT_DIR}"
echo ""

###############################################################################
# 1) Wait for every target to be reachable (mirrors start.sh)
###############################################################################
if [ "$SKIP_WAIT" = false ] && [ ${#TARGET_ARR[@]} -gt 0 ]; then
  TIMEOUT=120
  ELAPSED=0
  HEALTH_PATHS=("/actuator/health" "/health" "/healthz" "/ping" "/")
  READY_FLAGS=()
  for _ in "${TARGET_ARR[@]}"; do READY_FLAGS+=("false"); done

  echo "⏳ Waiting for ${#TARGET_ARR[@]} target(s) (max ${TIMEOUT}s)..."
  for u in "${TARGET_ARR[@]}"; do echo "    • $u"; done

  probe_url() {
    local base="$1"
    local p
    for p in "${HEALTH_PATHS[@]}"; do
      if curl -sf -o /dev/null --max-time 3 "${base%/}${p}" 2>/dev/null; then
        return 0
      fi
    done
    return 1
  }

  ALL_READY=false
  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    ALL_READY=true
    for idx in "${!TARGET_ARR[@]}"; do
      if [ "${READY_FLAGS[$idx]}" = "false" ]; then
        if probe_url "${TARGET_ARR[$idx]}"; then
          READY_FLAGS[$idx]="true"
          echo "  ✅ ${TARGET_ARR[$idx]} ready after ${ELAPSED}s"
        else
          ALL_READY=false
        fi
      fi
    done
    $ALL_READY && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done

  if ! $ALL_READY; then
    echo ""
    echo "⚠️  Some targets did not respond within ${TIMEOUT}s — analysis will still try them:"
    for idx in "${!TARGET_ARR[@]}"; do
      [ "${READY_FLAGS[$idx]}" = "false" ] && echo "    ❌ ${TARGET_ARR[$idx]}"
    done
  else
    echo "🚀 All targets ready."
  fi
  echo ""
fi

###############################################################################
# 2) Run the canonical analyzer wrapper (same one used by start.sh)
###############################################################################
TARGET_URL_JOINED="$(IFS=','; echo "${TARGET_ARR[*]}")"
export TARGET_URL="$TARGET_URL_JOINED"
if [ ${#SWAGGER_ARR[@]} -gt 0 ]; then
  SWAGGER_URL_JOINED="$(IFS=','; echo "${SWAGGER_ARR[*]}")"
  export SWAGGER_URL="$SWAGGER_URL_JOINED"
fi
export BEARER_TOKEN="$BEARER"
export APPNAME
export REPEAT
export SKIP_SPECTRAL=true

# Tell the wrapper to skip its own dashboard step — we always re-generate
# the dashboard ourselves at step 3 (mirrors start.sh's orchestration).
WRAPPER_ARGS=("--skip-dashboard")
[ -n "$DEBUG" ] && WRAPPER_ARGS=("--debug" "${WRAPPER_ARGS[@]}")

echo "━━━ 🔍 Running Green Score analyzer (delegating to green-score-analyzer_withdiscovery.sh) ━━━"
bash "$ANALYZER_WRAPPER" "${WRAPPER_ARGS[@]}"
EXIT=$?

LATEST="$OUTPUT_DIR/latest-report.json"
if [ $EXIT -ne 0 ] || [ ! -f "$LATEST" ]; then
  echo "❌ Analyzer failed (exit=$EXIT, report=$LATEST)" >&2
  [ -f "$LATEST" ] || exit 1
  exit $EXIT
fi

###############################################################################
# 3) Re-generate badge + dashboard (same step that start.sh runs at the end)
###############################################################################
if [ -f "$GENERATE_BADGE" ]; then
  echo ""
  echo "━━━ 🏷️  Generating badge ━━━"
  bash "$GENERATE_BADGE" "$LATEST" "$ROOT/badges/green-score.svg" || true
fi

if [ "$SKIP_DASHBOARD" = false ] && [ -f "$GENERATE_DASH" ]; then
  echo ""
  echo "━━━ 📊 Generating dashboard ━━━"
  CREEDENGO_REPORT="$ROOT/reports/creedengo-report.json"
  DASHBOARD_ARGS=("$LATEST" "$ROOT/dashboard/index.save.html" "$ROOT/dashboard/index.html")
  [ -f "$CREEDENGO_REPORT" ] && DASHBOARD_ARGS+=("$CREEDENGO_REPORT")
  bash "$GENERATE_DASH" "${DASHBOARD_ARGS[@]}" || true
  echo "✅ Dashboard refreshed: $ROOT/dashboard/index.html"
fi

echo ""
echo "✅ Report ready: $LATEST"

