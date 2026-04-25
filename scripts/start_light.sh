#!/usr/bin/env bash
###############################################################################
#  Start baseline + optimized (local dev — lightweight version)
#  Usage: bash greenanalyzer/scripts/start_light.sh [--analyze] [--debug]
#                                                    [--appname <name>]
#                                                    [--bearer <token>]
#                                                    [--creedengo]
#
#  Options:
#    --bearer <token>  Optional Bearer token for authenticated API endpoints
#    --debug           Enable debug output in the analyzer
#    --appname <name>  Override the application name in reports
#    --creedengo       Also run Creedengo eco-design code analysis
#
#  You can also pass the token via the BEARER_TOKEN env var:
#    BEARER_TOKEN=xxx bash greenanalyzer/scripts/start_light.sh
###############################################################################
set -uo pipefail   # pas de -e : on gère les erreurs manuellement
GREEN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$GREEN_DIR/.." && pwd)"

# Parse options
DEBUG_FLAG=""
APPNAME="${APPNAME:-}"
BEARER_TOKEN="${BEARER_TOKEN:-}"
RUN_CREEDENGO=false
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --debug) DEBUG_FLAG="--debug" ;;
    --creedengo) RUN_CREEDENGO=true ;;
    --appname)
      i=$((i + 1))
      APPNAME="${args[$i]:-}"
      ;;
    --bearer)
      i=$((i + 1))
      BEARER_TOKEN="${args[$i]:-}"
      ;;
  esac
  i=$((i + 1))
done

# Default APPNAME = root folder basename
APPNAME="${APPNAME:-$(basename "$ROOT")}"
export APPNAME

# Détection automatique : docker ou podman ?
source "$GREEN_DIR/scripts/_container-runtime.sh"

# Suppress Podman "Executing external compose provider" warning (ignoré si docker)
export PODMAN_COMPOSE_WARNING_LOGS=false

# (Optionnel) Décommenter pour lancer compose depuis ce script :
# Use test profile overlay for Green Score: H2, stubs, GreenScoreTestController
# COMPOSE_CMD="$CONTAINER_COMPOSE -f docker-compose.yml -f docker-compose.test.yml"
# $COMPOSE_CMD down --remove-orphans --timeout 5 2>/dev/null || true
# if [[ "$(uname -s)" == Darwin ]]; then
#   osascript -e "tell application \"Terminal\" to do script \"cd '$ROOT' && $COMPOSE_CMD up --build --force-recreate backend frontend\""
# else
#   mintty --title "Container Compose" -e bash -c "cd '$ROOT' && $COMPOSE_CMD up --build --force-recreate backend frontend; read -p 'Appuyez sur Entrée pour fermer...'" &
# fi

echo "⏳ Attente du démarrage des services 20s..."
sleep 20

ANALYZE=false
if [[ "${1:-}" == "--analyze" ]] || [[ "${2:-}" == "--analyze" ]]; then
  ANALYZE=true
fi

# --- Attente du démarrage des 2 services (max 30s) ---
echo ""
echo "⏳ Attente du démarrage des services (max 30s)..."
TIMEOUT=30
ELAPSED=0
BASE_READY=false
OPT_READY=false

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  # Vérifier que les processus tournent encore

  if ! $BASE_READY; then
    if curl -sf http://localhost:8080/actuator/health >/dev/null 2>&1; then
      BASE_READY=true
      echo "  ✅ Baseline (8080) prêt après ${ELAPSED}s"
    fi
  fi

  if $BASE_READY; then
    echo "🚀 Les services sont démarrés !"
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if ! $BASE_READY; then
  echo ""
  echo "⚠️  Timeout (${TIMEOUT}s) — services non prêts :"
  $BASE_READY || echo "    ❌ Baseline (8080) non disponible"
  $OPT_READY || echo "    ❌ Optimized (8081) non disponible"
  echo ""
  echo "🛑 Arrêt — l'analyse ne sera pas lancée."
  exit 1
fi
echo ""

# --- Bearer token (optional, passed via --bearer or BEARER_TOKEN env var) ---
if [ -n "$BEARER_TOKEN" ]; then
  echo "🔐 Bearer token fourni — les endpoints protégés seront authentifiés"
else
  echo "ℹ️  Aucun bearer token fourni (--bearer <token> ou BEARER_TOKEN=xxx)"
  echo "   Les endpoints protégés retourneront 401 si l'API requiert une authentification"
fi
export BEARER_TOKEN
echo ""

echo "Running Green Score analyzer..."
if [ "$RUN_CREEDENGO" = true ]; then
  bash "$GREEN_DIR/scripts/green-score-analyzer_withdiscovery.sh" $DEBUG_FLAG --skip-dashboard || true
else
  bash "$GREEN_DIR/scripts/green-score-analyzer_withdiscovery.sh" $DEBUG_FLAG || true
fi

# ── Creedengo eco-design analysis (optional, requires Docker) ──
if [ "$RUN_CREEDENGO" = true ]; then
  echo ""
  echo "Running Creedengo eco-design code analyzer..."
  bash "$GREEN_DIR/scripts/creedengo-analyzer.sh" $DEBUG_FLAG --skip-build --skip-dashboard || true
else
  echo ""
  echo "💡 Tip: run with --creedengo to also run Creedengo eco-design code analysis"
fi

###############################################################################
# Dashboard generation — AFTER all analyses (green-score + creedengo)
###############################################################################
echo ""
echo "━━━ 📊 Generating final Dashboard ━━━"
LATEST_REPORT="$GREEN_DIR/reports/latest-report.json"
CREEDENGO_REPORT="$GREEN_DIR/reports/creedengo-report.json"

if [ -f "$GREEN_DIR/scripts/generate-dashboard.sh" ] && [ -f "$LATEST_REPORT" ]; then
  DASHBOARD_ARGS=("$LATEST_REPORT" "$GREEN_DIR/dashboard/index.save.html" "$GREEN_DIR/dashboard/index.html")
  if [ -f "$CREEDENGO_REPORT" ]; then
    DASHBOARD_ARGS+=("$CREEDENGO_REPORT")
  fi
  bash "$GREEN_DIR/scripts/generate-dashboard.sh" "${DASHBOARD_ARGS[@]}" || true
  echo "✅ Dashboard generated: $GREEN_DIR/dashboard/index.html"
else
  echo "⚠️  No report found — dashboard not generated"
fi

echo "Press Ctrl+C to stop."
trap - EXIT    # désactive le cleanup auto, on attend manuellement
wait

