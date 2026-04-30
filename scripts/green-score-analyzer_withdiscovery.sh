#!/usr/bin/env bash
###############################################################################
#  Green Score Analyzer WITH DISCOVERY (Fully Dynamic)
#  ====================================================
#  All endpoint measurements are discovered from the OpenAPI/Swagger spec.
#  No hardcoded endpoints — works with any API.
#
#  This script is a thin wrapper around green-api-auto-discover.py which
#  handles all discovery, measurement, scoring, and reporting.
#
#  Port layout:
#    - API target:     8080  (default, configurable via OPTIMIZED_PORT)
#    - SonarQube:      9100  (Creedengo analysis, separate script)
#
#  Authentication:
#    If your API requires a Bearer token, pass it via:
#      BEARER_TOKEN=xxx bash green-score-analyzer_withdiscovery.sh
#    or via the calling script (start.sh --bearer <token>)
#
#  Usage:
#    bash green-score-analyzer_withdiscovery.sh
#    bash green-score-analyzer_withdiscovery.sh --debug
#    OPTIMIZED_PORT=8080 bash green-score-analyzer_withdiscovery.sh
#    SWAGGER_URL=http://localhost:8080/v3/api-docs bash green-score-analyzer_withdiscovery.sh
#    BEARER_TOKEN=xxx bash green-score-analyzer_withdiscovery.sh
#
#  Multi-target mode — analyze several APIs in a single run.
#  Pass a comma-separated list to TARGET_URL (and optionally SWAGGER_URL):
#    TARGET_URL="http://localhost:8080,http://localhost:8082" \
#      bash green-score-analyzer_withdiscovery.sh
#    TARGET_URL="http://api1:8080,http://api2:8080" \
#      SWAGGER_URL="http://api1:8080/v3/api-docs,http://api2:8080/v3/api-docs" \
#      bash green-score-analyzer_withdiscovery.sh
#  All discovered specs are merged into a single discovery resource
#  (reports/discovered-openapi.json) and analyzed together.
###############################################################################
set -euo pipefail

# ── Parse options ──
DEBUG_MODE=false
SKIP_DASHBOARD=false
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG_MODE=true ;;
    --skip-dashboard) SKIP_DASHBOARD=true ;;
    *) EXTRA_ARGS+=("$arg") ;;
  esac
done

# ── Configuration (env vars with defaults) ──
OPTIMIZED_PORT=${OPTIMIZED_PORT:-${BASELINE_PORT:-8081}}
# TARGET_URL / SWAGGER_URL accept a single value or a comma-separated list of
# several APIs (multi-target mode).  All discovered specs are merged into one
# discovery resource and analyzed together.
TARGET_URL=${TARGET_URL:-"http://localhost:${OPTIMIZED_PORT}"}
SWAGGER_URL=${SWAGGER_URL:-""}
BEARER_TOKEN=${BEARER_TOKEN:-""}
REPEAT=${REPEAT:-3}
SKIP_SPECTRAL=${SKIP_SPECTRAL:-true}
APPNAME=${APPNAME:-$(basename "$(cd "$(dirname "$0")/.." && pwd)")}


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$GREEN_DIR/.." && pwd)"
OUTPUT_DIR="${GREEN_DIR}/reports"
AUTODISCOVER_PY="${SCRIPT_DIR}/green-api-auto-discover.py"

# ── Colors ──
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  🌿 Green API Score Analyzer — Fully Dynamic Discovery     ║${NC}"
echo -e "${CYAN}║  Devoxx France 2026 — Green Architecture                   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

###############################################################################
# Pre-flight checks
###############################################################################

# Verify Python 3 is available
if ! command -v python3 &>/dev/null; then
  echo -e "${RED}❌ python3 is required but not found${NC}"
  exit 1
fi

# Verify the auto-discover script exists
if [ ! -f "$AUTODISCOVER_PY" ]; then
  echo -e "${RED}❌ green-api-auto-discover.py not found at: $AUTODISCOVER_PY${NC}"
  exit 1
fi

# Wait for the target API(s) to be available — supports comma-separated list.
# Tries several common health paths so the script is portable across stacks
# (Spring Boot, plain HTTP, /healthz, etc.) instead of assuming /actuator/health.
echo -e "${YELLOW}━━━ ⏳ Waiting for API(s): ${TARGET_URL} ━━━${NC}"
MAX_WAIT=90
HEALTH_PATHS=("/actuator/health" "/health" "/healthz" "/ping" "/")
IFS=',' read -r -a TARGET_LIST <<< "$TARGET_URL"

probe_target() {
  local base="$1"
  local p
  for p in "${HEALTH_PATHS[@]}"; do
    if curl -s -o /dev/null -w '' --max-time 3 "${base%/}${p}" 2>/dev/null; then
      # curl with -w '' returns 0 if the server responded at all; that's enough
      # to consider the target reachable. We don't require 200 since some APIs
      # return 401/403 on / when auth is required.
      return 0
    fi
  done
  return 1
}

for raw_url in "${TARGET_LIST[@]}"; do
  url="$(echo "$raw_url" | xargs)"   # trim
  [ -z "$url" ] && continue
  echo -e "  → checking ${url}..."
  ready=false
  for i in $(seq 1 $MAX_WAIT); do
    if probe_target "$url"; then
      echo -e "  ${GREEN}✓ ${url} is up${NC}"
      ready=true
      break
    fi
    sleep 1
  done
  if [ "$ready" = false ]; then
    echo -e "  ${YELLOW}⚠ ${url} did not respond within ${MAX_WAIT}s — will still try${NC}"
  fi
done
echo ""

###############################################################################
# Bearer token (optional — passed via BEARER_TOKEN env var or calling script)
###############################################################################
if [ -n "$BEARER_TOKEN" ]; then
  echo -e "${GREEN}🔐 Bearer token provided — authenticated endpoints will be tested${NC}"
else
  echo -e "${YELLOW}ℹ️  No bearer token — endpoints requiring auth will return 401${NC}"
  echo -e "${YELLOW}   💡 Pass BEARER_TOKEN=xxx or use start.sh --bearer <token>${NC}"
fi
echo ""

###############################################################################
# Run the fully dynamic Python analyzer
###############################################################################

echo -e "${YELLOW}━━━ 🔍 Running Auto-Discover Analyzer ━━━${NC}"
echo -e "  Target:   ${CYAN}${TARGET_URL}${NC}"
echo -e "  Repeat:   ${CYAN}${REPEAT}${NC}"
if [ -n "$SWAGGER_URL" ]; then
  echo -e "  Swagger:  ${CYAN}${SWAGGER_URL}${NC}"
fi
if [ -n "$BEARER_TOKEN" ]; then
  echo -e "  Auth:     ${CYAN}Bearer ****${NC}"
fi
echo ""

# Build the command — pass every target / swagger separately (multi-target).
CMD=(python3 "$AUTODISCOVER_PY"
  --repeat "$REPEAT"
  --appname "$APPNAME"
)

IFS=',' read -r -a TARGET_LIST <<< "$TARGET_URL"
for t in "${TARGET_LIST[@]}"; do
  t_trim="$(echo "$t" | xargs)"
  [ -n "$t_trim" ] && CMD+=(--target "$t_trim")
done

if [ -n "$SWAGGER_URL" ]; then
  IFS=',' read -r -a SWAGGER_LIST <<< "$SWAGGER_URL"
  for s in "${SWAGGER_LIST[@]}"; do
    s_trim="$(echo "$s" | xargs)"
    [ -n "$s_trim" ] && CMD+=(--swagger "$s_trim")
  done
fi

if [ -n "$BEARER_TOKEN" ]; then
  CMD+=(--bearer "$BEARER_TOKEN")
fi

# AR02 / AR04 / AR05 forwarding (driven by start.sh exports or CI env).
# SOURCE_DIR  → Phase 2 (AR04 IaC + AR01 broker-deps)
# CONSUMER_REGION + ENABLE_GEOIP → AR02 Phase 3 (anycast / distance)
# CLOUD_FOOTPRINT_CONFIRMED → AR05 dashboard validation
if [ -n "${SOURCE_DIR:-}" ]; then
  CMD+=(--source-dir "$SOURCE_DIR")
fi
if [ -n "${CONSUMER_REGION:-}" ]; then
  CMD+=(--consumer-region "$CONSUMER_REGION")
fi
if [ "${ENABLE_GEOIP:-false}" = "true" ]; then
  CMD+=(--enable-geoip)
fi
if [ "${CLOUD_FOOTPRINT_CONFIRMED:-false}" = "true" ]; then
  CMD+=(--cloud-footprint-confirmed)
fi

if [ "$SKIP_SPECTRAL" = true ]; then
  CMD+=(--skip-spectral)
fi

# Pass any extra args through
if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

# Execute
"${CMD[@]}"
ANALYZER_EXIT=$?

if [ $ANALYZER_EXIT -ne 0 ]; then
  echo -e "${RED}❌ Analyzer exited with code $ANALYZER_EXIT${NC}"
  exit $ANALYZER_EXIT
fi

echo ""

###############################################################################
# Post-processing: Badge + Dashboard + Summary
###############################################################################

LATEST_REPORT="${OUTPUT_DIR}/latest-report.json"

if [ ! -f "$LATEST_REPORT" ]; then
  echo -e "${RED}❌ Report not generated: $LATEST_REPORT${NC}"
  exit 1
fi

# Generate badge
if [ -f "$GREEN_DIR/scripts/generate-badge.sh" ]; then
  echo -e "${YELLOW}━━━ 🏷️  Generating Badge ━━━${NC}"
  bash "$GREEN_DIR/scripts/generate-badge.sh" "$LATEST_REPORT" "$GREEN_DIR/badges/green-score.svg" || true
fi

# Generate dashboard (skipped when --skip-dashboard is set, e.g. when orchestrated by start.sh)
if [ "$SKIP_DASHBOARD" = false ] && [ -f "$GREEN_DIR/scripts/generate-dashboard.sh" ]; then
  echo -e "${YELLOW}━━━ 📊 Generating Dashboard ━━━${NC}"
  bash "$GREEN_DIR/scripts/generate-dashboard.sh" "$LATEST_REPORT" "$GREEN_DIR/dashboard/index.save.html" "$GREEN_DIR/dashboard/index.html" || true
elif [ "$SKIP_DASHBOARD" = true ]; then
  echo -e "${YELLOW}ℹ️  Dashboard generation skipped (--skip-dashboard) — will be generated after all analyses${NC}"
fi

# ── Display summary ──
# Use sys.argv[1] to pass the path instead of embedding it in Python string
# (avoids Windows backslash issues when $LATEST_REPORT contains \ characters)
echo ""
TOTAL=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));r=d.get('report',d);print(r['green_score']['total'])" "$LATEST_REPORT" 2>/dev/null || echo "?")
GRADE=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));r=d.get('report',d);print(r['green_score']['grade'])" "$LATEST_REPORT" 2>/dev/null || echo "?")
EP_DISC=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));r=d.get('report',d);print(r.get('auto_discovery',{}).get('endpoints_discovered',0))" "$LATEST_REPORT" 2>/dev/null || echo "0")
EP_MEAS=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));r=d.get('report',d);print(r.get('auto_discovery',{}).get('endpoints_measured',0))" "$LATEST_REPORT" 2>/dev/null || echo "0")
APP_DISPLAY=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('appname','unknown'))" "$LATEST_REPORT" 2>/dev/null || echo "$APPNAME")

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📄 Report: ${LATEST_REPORT}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  📦 APP: ${GREEN}${APP_DISPLAY}${CYAN}                                        ║${NC}"
echo -e "${CYAN}║  🌿 GREEN SCORE:  ${GREEN}${TOTAL}/100${CYAN}   Grade: ${GREEN}${GRADE}${CYAN}                    ║${NC}"
echo -e "${CYAN}║  🔍 Endpoints discovered: ${GREEN}${EP_DISC}${CYAN}  measured: ${GREEN}${EP_MEAS}${CYAN}              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$DEBUG_MODE" = true ]; then
  echo -e "${YELLOW}━━━ 🐛 DEBUG: Score breakdown ━━━${NC}"
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
r = d.get('report', d)
gs = r['green_score']
print(f'  App:   {d.get(\"appname\", \"unknown\")}')
print(f'  Total: {gs[\"total\"]}/{gs[\"max\"]}  Grade: {gs[\"grade\"]}')
print()
for rule, score in gs.get('breakdown', {}).items():
    detail = gs.get('details', {}).get(rule, {}).get('note', '')
    icon = '+' if score > 0 else '-'
    print(f'  [{icon}] {rule:25s} {score:5}  {detail}')
print()
disc = r.get('auto_discovery', {})
for ep in disc.get('discovered_endpoints', [])[:20]:
    print(f'    {ep[\"method\"]:6s} {ep[\"path\"]:50s} {ep.get(\"http_code\",0):3d}  {ep.get(\"size_download\",0):>8} B  {ep.get(\"time_total\",0):.3f}s')
" "$LATEST_REPORT" 2>/dev/null || true
fi

# Canonical assets live under the analyzer's own folder ($GREEN_DIR).
# When the analyzer is installed inside a host project (installer.sh layout:
# <host>/greenanalyzer/...), we ALSO mirror the dashboard / badges / latest
# report at the host project root for convenience. Otherwise (standalone use),
# we only refresh the canonical copies.
mkdir -p "$GREEN_DIR/reports"
cp "$LATEST_REPORT" "$GREEN_DIR/reports/last-report.json" || true

DASHBOARD_PATH="$GREEN_DIR/dashboard/index.html"
if [ -n "${ROOT_DIR:-}" ] && [ "$ROOT_DIR" != "$GREEN_DIR" ] && [ -d "$ROOT_DIR" ]; then
  mkdir -p "$ROOT_DIR/dashboard" "$ROOT_DIR/badges" "$ROOT_DIR/reports"
  cp -r "$GREEN_DIR/dashboard/." "$ROOT_DIR/dashboard/" 2>/dev/null || true
  cp -r "$GREEN_DIR/badges/."    "$ROOT_DIR/badges/"    2>/dev/null || true
  cp    "$LATEST_REPORT"         "$ROOT_DIR/reports/last-report.json" 2>/dev/null || true
  DASHBOARD_PATH="$ROOT_DIR/dashboard/index.html"
fi

echo -e "Open the dashboard: ${YELLOW}open ${DASHBOARD_PATH}${NC}"
