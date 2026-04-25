#!/usr/bin/env bash
###############################################################################
#  Start baseline + optimized (local dev)
#  Usage: bash scripts/start.sh [--analyze] [--debug] [--appname <name>]
#                                [--bearer <token>] [--creedengo]
#                                [--target <url>]... [--swagger <url|file>]...
#
#  Options:
#    --bearer <token>   Optional Bearer token for authenticated API endpoints
#    --debug            Enable debug output in the analyzer
#    --appname <name>   Override the application name in reports
#    --creedengo        Also run Creedengo eco-design code analysis
#    --target  <url>          One API base URL to analyze. Repeat the flag to
#                              add several APIs.
#    --targets <csv>           Same as --target but accepts a comma-separated
#                              list, e.g. --targets http://a:8080,http://b:8082
#    --swagger  <url|file>     Explicit OpenAPI spec, paired with --target.
#                              Repeat or use --swaggers <csv>.
#    --swaggers <csv>          Comma-separated list of OpenAPI specs.
#
#    All discovered swaggers are merged into a single discovery resource and
#    analyzed in one run.
#
#  You can also pass the token via the BEARER_TOKEN env var:
#    BEARER_TOKEN=xxx bash scripts/start.sh
#
#  Multi-target example:
#    bash scripts/start.sh --targets http://localhost:8080,http://localhost:8082
#    bash scripts/start.sh --target http://localhost:8080 \
#                          --target http://localhost:8082
###############################################################################
set -uo pipefail   # pas de -e : on gère les erreurs manuellement
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Parse options
DEBUG_FLAG=""
APPNAME="${APPNAME:-}"
BEARER_TOKEN="${BEARER_TOKEN:-}"
RUN_CREEDENGO=false
TARGETS=()      # one or many --target <url>  (or comma-separated)
SWAGGERS=()     # one or many --swagger <url|file>
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
    --target|--targets)
      # Consume every following token until the next --flag, then split by
      # comma. This makes all of the following equivalent:
      #   --targets http://a:8080,http://b:8081
      #   --targets http://a:8080, http://b:8081, http://c:8082
      #   --target http://a:8080 --target http://b:8081
      raw=""
      while [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" != --* ]]; do
        i=$((i + 1))
        raw="${raw}${args[$i]} "
      done
      # Replace any whitespace right after a comma so the IFS split is clean
      raw="$(echo "$raw" | tr -s ' ')"
      IFS=',' read -r -a _t <<< "$raw"
      for v in "${_t[@]}"; do
        v_trim="$(echo "$v" | xargs)"   # trim leading/trailing whitespace
        [ -n "$v_trim" ] && TARGETS+=("$v_trim")
      done
      ;;
    --swagger|--swaggers)
      raw=""
      while [ $((i + 1)) -lt ${#args[@]} ] && [[ "${args[$((i + 1))]}" != --* ]]; do
        i=$((i + 1))
        raw="${raw}${args[$i]} "
      done
      raw="$(echo "$raw" | tr -s ' ')"
      IFS=',' read -r -a _s <<< "$raw"
      for v in "${_s[@]}"; do
        v_trim="$(echo "$v" | xargs)"
        [ -n "$v_trim" ] && SWAGGERS+=("$v_trim")
      done
      ;;
  esac
  i=$((i + 1))
done

# Default APPNAME = root folder basename
APPNAME="${APPNAME:-$(basename "$ROOT")}"
export APPNAME

# Détection automatique : docker ou podman ?
source "$ROOT/scripts/_container-runtime.sh"

# Suppress Podman "Executing external compose provider" warning (ignoré si docker)
export PODMAN_COMPOSE_WARNING_LOGS=false

# Force kill + remove all existing containers
# Use test profile overlay: H2 in-memory DB, stubs for Stripe/Twilio/Email,
# GreenScoreTestController provides scenario data for the analyzer.
#COMPOSE_CMD="$CONTAINER_COMPOSE -f ../docker-compose.yml"

#$COMPOSE_CMD down --remove-orphans --timeout 5 2>/dev/null || true
#$CONTAINER_RT rm -f $($CONTAINER_RT ps -aq) 2>/dev/null || true

#echo "⏳ Attente de 15s pour laisser les ports se libérer..."
#sleep 15
#echo "⏳ Attention nous allons ouvrir un terminal à coté pour lancer le compose, ne fermez pas ce terminal sauf à la fin en faisant Ctrl + C!"

#if [[ "$(uname -s)" == Darwin ]]; then
  # macOS : ouvrir un nouveau Terminal.app via osascript
 # osascript -e "tell application \"Terminal\" to do script \"cd '$ROOT' && $COMPOSE_CMD up --build --force-recreate\""
#else
  # Windows (Git Bash / mintty) : ouvrir un nouveau terminal mintty
 # mintty --title "Container Compose" -e bash -c "cd '$ROOT' && $COMPOSE_CMD up --build --force-recreate; read -p 'Appuyez sur Entrée pour fermer...'" &
#fi

echo "⏳ Attente du démarrage des services 20s..."
sleep 20

ANALYZE=false
if [[ "${1:-}" == "--analyze" ]] || [[ "${2:-}" == "--analyze" ]]; then
  ANALYZE=true
fi

# --- Attente du démarrage des services (max TIMEOUT s) ---
echo ""

# Si l'utilisateur a passé --targets, on attend exactement ces URL.
# Sinon, on retombe sur les ports historiques (8080 et/ou 8081).
WAIT_URLS=()
if [ ${#TARGETS[@]} -gt 0 ]; then
  WAIT_URLS=("${TARGETS[@]}")
else
  WAIT_URLS=("http://localhost:8080" "http://localhost:8081")
fi

echo "⏳ Attente du démarrage des services (max ${TIMEOUT:-120}s) — ${#WAIT_URLS[@]} cible(s):"
for u in "${WAIT_URLS[@]}"; do echo "    • $u"; done
echo ""

# Tableau parallèle des états « prêt » par cible
READY_FLAGS=()
for _u in "${WAIT_URLS[@]}"; do READY_FLAGS+=("false"); done

TIMEOUT=120
ELAPSED=0
ALL_READY=false

# Endpoints de health-check à essayer (ordre de préférence)
HEALTH_PATHS=("/actuator/health" "/health" "/healthz" "/ping" "/")

probe_url() {
  local base="$1"
  for p in "${HEALTH_PATHS[@]}"; do
    if curl -sf -o /dev/null --max-time 3 "${base%/}${p}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  ALL_READY=true
  for idx in "${!WAIT_URLS[@]}"; do
    if [ "${READY_FLAGS[$idx]}" = "false" ]; then
      if probe_url "${WAIT_URLS[$idx]}"; then
        READY_FLAGS[$idx]="true"
        echo "  ✅ ${WAIT_URLS[$idx]} prêt après ${ELAPSED}s"
      else
        ALL_READY=false
      fi
    fi
  done
  if $ALL_READY; then
    echo "🚀 Toutes les cibles sont démarrées !"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if ! $ALL_READY; then
  echo ""
  echo "⚠️  Timeout (${TIMEOUT}s) — cibles non prêtes :"
  for idx in "${!WAIT_URLS[@]}"; do
    if [ "${READY_FLAGS[$idx]}" = "false" ]; then
      echo "    ❌ ${WAIT_URLS[$idx]} non disponible"
    fi
  done
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

# ── Multi-target / multi-swagger propagation ──
# Pass any --target / --swagger collected from the CLI as comma-separated
# values to the wrapper script (which forwards each one to the Python analyzer).
if [ ${#TARGETS[@]} -gt 0 ]; then
  TARGET_URL_JOINED=$(IFS=','; echo "${TARGETS[*]}")
  export TARGET_URL="$TARGET_URL_JOINED"
  echo "🎯 Cibles à analyser (${#TARGETS[@]}): $TARGET_URL"
fi
if [ ${#SWAGGERS[@]} -gt 0 ]; then
  SWAGGER_URL_JOINED=$(IFS=','; echo "${SWAGGERS[*]}")
  export SWAGGER_URL="$SWAGGER_URL_JOINED"
  echo "📜 Swaggers fournis (${#SWAGGERS[@]}): $SWAGGER_URL"
fi
echo ""

echo "Running Green Score analyzer..."
if [ "$RUN_CREEDENGO" = true ]; then
  bash "$ROOT/scripts/green-score-analyzer_withdiscovery.sh" $DEBUG_FLAG --skip-dashboard || true
else
  bash "$ROOT/scripts/green-score-analyzer_withdiscovery.sh" $DEBUG_FLAG || true
fi

# ── Creedengo eco-design analysis (optional, requires Docker) ──
if [ "$RUN_CREEDENGO" = true ]; then
  echo ""
  echo "Running Creedengo eco-design code analyzer..."
  bash "$ROOT/scripts/creedengo-analyzer.sh" $DEBUG_FLAG --skip-build --no-cleanup --skip-dashboard || true
else
  echo ""
  echo "💡 Tip: run with --creedengo to also run Creedengo eco-design code analysis"
fi

###############################################################################
# Dashboard generation — AFTER all analyses (green-score + creedengo)
###############################################################################
echo ""
echo "━━━ 📊 Generating final Dashboard ━━━"
LATEST_REPORT="$ROOT/reports/latest-report.json"
CREEDENGO_REPORT="$ROOT/reports/creedengo-report.json"

if [ -f "$ROOT/scripts/generate-dashboard.sh" ] && [ -f "$LATEST_REPORT" ]; then
  DASHBOARD_ARGS=("$LATEST_REPORT" "$ROOT/dashboard/index.save.html" "$ROOT/dashboard/index.html")
  if [ -f "$CREEDENGO_REPORT" ]; then
    DASHBOARD_ARGS+=("$CREEDENGO_REPORT")
  fi
  bash "$ROOT/scripts/generate-dashboard.sh" "${DASHBOARD_ARGS[@]}" || true
  echo "✅ Dashboard generated: greenanalyzer/dashboard/index.html"
else
  echo "⚠️  No report found — dashboard not generated"
fi

# ── Attente de 10 minutes ou Ctrl+C avant nettoyage ──
SONAR_CONTAINER_FILE="$ROOT/.creedengo/.sonar-container-name"
if [ "$RUN_CREEDENGO" = true ] && [ -f "$SONAR_CONTAINER_FILE" ]; then
  SONAR_CONTAINER=$(cat "$SONAR_CONTAINER_FILE" 2>/dev/null)
  SONAR_PORT=${SONAR_PORT:-9100}
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  🌱 SonarQube Creedengo est accessible sur :"
  echo "     👉  http://localhost:${SONAR_PORT}"
  echo ""
  echo "  ⏳ Le serveur reste disponible pendant 10 minutes."
  echo "     Appuyez sur Ctrl+C pour arrêter immédiatement."
  echo "═══════════════════════════════════════════════════════════════"
  echo ""

  # Détection du runtime container
  source "$ROOT/scripts/_container-runtime.sh"

  cleanup_sonar() {
    echo ""
    echo "🧹 Nettoyage du container SonarQube..."
    if [ -n "${SONAR_CONTAINER:-}" ]; then
      $CONTAINER_RT rm -f "$SONAR_CONTAINER" 2>/dev/null || true
    fi
    # Nettoie aussi tout container creedengo-sonar résiduel
    for cid in $($CONTAINER_RT ps -aq --filter "name=creedengo-sonar" 2>/dev/null); do
      $CONTAINER_RT rm -f "$cid" 2>/dev/null || true
    done
    rm -f "$SONAR_CONTAINER_FILE" 2>/dev/null || true
    echo "✅ Containers SonarQube nettoyés."
  }

  trap cleanup_sonar EXIT INT TERM

  # Attente : 5 minutes (500 secondes) avec countdown
  WAIT_TOTAL=300
  WAIT_ELAPSED=0
  while [ "$WAIT_ELAPSED" -lt "$WAIT_TOTAL" ]; do
    REMAINING=$(( (WAIT_TOTAL - WAIT_ELAPSED) / 60 ))
    REMAINING_S=$(( (WAIT_TOTAL - WAIT_ELAPSED) % 60 ))
    printf "\r  ⏱️  Temps restant : %02d:%02d — Ctrl+C pour arrêter maintenant " "$REMAINING" "$REMAINING_S"
    sleep 5
    WAIT_ELAPSED=$((WAIT_ELAPSED + 5))
  done
  echo ""
  echo "⏰ Délai de 5 minutes écoulé."
else
  echo "Press Ctrl+C to stop."
  trap - EXIT    # désactive le cleanup auto, on attend manuellement
  wait
fi
