#!/usr/bin/env bash
###############################################################################
#  Build a single self-extracting executable that bundles the full Green
#  Analyzer (scripts + dashboard + badges + thresholds) and exposes ONLY a
#  clean CLI to the end-user.
#
#  Output:
#    dist/greenanalyzer        ← single-file executable (chmod +x)
#
#  Usage:
#    bash scripts/build-binary.sh
#    bash scripts/build-binary.sh --output ./greenanalyzer-1.0
#
#  How it works:
#    1. Stage the runtime files to a temp dir (only what's needed at runtime).
#    2. tar + gzip + base64-encode the bundle.
#    3. Wrap in a self-extracting bash header that, at run time:
#         - extracts to $TMPDIR/greenanalyzer-<pid>
#         - invokes the embedded CLI entrypoint with the user's args
#         - cleans up on exit
#    4. Append the encoded payload after a __PAYLOAD__ marker.
#
#  The end-user runs `./greenanalyzer --help` and never sees the scripts.
###############################################################################
set -euo pipefail

GREEN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$GREEN_DIR/dist/greenanalyzer"

# ── Parse args ──
while [ $# -gt 0 ]; do
  case "$1" in
    --output|-o) OUTPUT="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$(dirname "$OUTPUT")"

# ── Stage runtime files ──
STAGE="$(mktemp -d)"
trap "rm -rf '$STAGE'" EXIT

echo "📦 Staging runtime files into $STAGE ..."
mkdir -p "$STAGE/bundle/scripts"

# ── Auto-discover the runtime scripts ──
# Copy every .py and .sh under scripts/ EXCEPT this builder. Avoids the
# error-prone hardcoded list that used to drift every time a new helper
# was introduced (e.g. architecture_rules.py, build-interactive-config.py,
# greenapianalyzer-server.py, etc.).
for src in "$GREEN_DIR/scripts/"*.py "$GREEN_DIR/scripts/"*.sh; do
  [ -f "$src" ] || continue
  base="$(basename "$src")"
  case "$base" in
    build-binary.sh) continue ;;            # don't ship the builder itself
    *) cp "$src" "$STAGE/bundle/scripts/" ;;
  esac
done
[ -f "$GREEN_DIR/scripts/requirements.txt" ] && \
  cp "$GREEN_DIR/scripts/requirements.txt"                    "$STAGE/bundle/scripts/"

# Spectral ruleset (used by the offline linter mode)
[ -f "$GREEN_DIR/.spectral.yml"  ] && cp "$GREEN_DIR/.spectral.yml"  "$STAGE/bundle/" || true
[ -f "$GREEN_DIR/.spectral.yaml" ] && cp "$GREEN_DIR/.spectral.yaml" "$STAGE/bundle/" || true

# Templates / static
mkdir -p "$STAGE/bundle/dashboard" "$STAGE/bundle/badges"
cp -r "$GREEN_DIR/dashboard/"* "$STAGE/bundle/dashboard/" 2>/dev/null || true
cp -r "$GREEN_DIR/badges/"*    "$STAGE/bundle/badges/"    2>/dev/null || true

# Threshold config
[ -f "$GREEN_DIR/green-score-threshold.json" ] && \
  cp "$GREEN_DIR/green-score-threshold.json" "$STAGE/bundle/"

# ── CLI entrypoint inside the bundle ──
# This is the ONLY thing the user-facing layer talks to. It exposes a clean
# CLI and forwards to the underlying scripts. Implementation details (paths,
# helper scripts) stay opaque to the end user.
cat > "$STAGE/bundle/__entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -uo pipefail
# $BUNDLE_DIR is exported by the outer self-extracting wrapper.
: "${BUNDLE_DIR:=$(cd "$(dirname "$0")" && pwd)}"
SCRIPTS="$BUNDLE_DIR/scripts"
VERSION="1.1.0"

show_help() {
  cat <<'HELP'

  ╔══════════════════════════════════════════════════════════════╗
  ║          🌿  Green Analyzer — API Eco-Scoring CLI            ║
  ║          Single-binary edition                               ║
  ╚══════════════════════════════════════════════════════════════╝

  Measures the eco-design quality of any REST API and produces
  a Green Score (badge + HTML dashboard + JSON report) — including
  Architecture & Infra rules (AR01..AR05, +23 pts).

  USAGE
    greenanalyzer [SUBCOMMAND] [OPTIONS]

  SUBCOMMANDS (default: analyze)
    analyze                    Run the full Green Score (live API, badge,
                               dashboard). This is the default when no
                               subcommand is given.
    lint   <openapi-file>      Offline lint of an OpenAPI spec — no live
                               API needed. Outputs JSON or text findings.
    serve                      Start the interactive web dashboard
                               (http://127.0.0.1:8765 by default).
    version                    Print the binary version.
    help, --help, -h           This help.

  ANALYZE OPTIONS  (greenanalyzer analyze ...)
    --target  URL              Base URL of the API (repeat or use --targets)
    --targets URL,URL,...      Comma-separated list of base URLs
    --swagger URL|FILE         OpenAPI spec (URL or local file)
    --swaggers CSV             Comma-separated list of specs
    --bearer  TOKEN            Bearer token (or env BEARER_TOKEN=…)
    --appname NAME             Application name in reports
    --repeat  N                Measurement repetitions (default: 3)
    --output-dir DIR           Where reports/dashboard/badges land
                               (default: $PWD/greenanalyzer-output)
    --consumer-region XX       ISO-3166 region code for AR02
    --enable-geoip             AR02 anycast/ASN cross-check (ipinfo.io)
    --cloud-footprint-confirmed Validate AR05 (cloud dashboard attestation)
    --debug                    Verbose analyzer output

  ECO-DESIGN CODE ANALYSIS (optional, requires Docker/Podman)
    --creedengo                Also run Creedengo static analysis
    --git-repo  URL            Clone a remote repo for Creedengo
    --git-branch BRANCH        Branch/tag for --git-repo
    --git-subdir DIR           Sub-folder inside the cloned repo
    --git-keep                 Keep the cloned working copy after analysis

  LINT OPTIONS  (greenanalyzer lint <spec> ...)
    --format text|json|sarif   Output format (default: text)
    --fail-on-warn             Exit non-zero if any finding is emitted

  SERVE OPTIONS  (greenanalyzer serve ...)
    --host HOST                Bind host (default: 127.0.0.1)
    --port N                   Bind port (default: 8765)
    --open                     Open the dashboard in a browser

  EXAMPLES
    greenanalyzer analyze --target http://localhost:8080
    greenanalyzer analyze --targets http://api1:8080,http://api2:8080 \
                          --consumer-region FR --enable-geoip
    greenanalyzer lint   ./openapi.yaml --format json
    greenanalyzer serve  --open

HELP
}

# ── Subcommand dispatch ──
SUB="analyze"
if [ $# -gt 0 ]; then
  case "$1" in
    analyze|lint|serve|version|help) SUB="$1"; shift ;;
    --help|-h)        show_help; exit 0 ;;
    --version)        echo "greenanalyzer $VERSION"; exit 0 ;;
  esac
fi

case "$SUB" in
  help)              show_help; exit 0 ;;
  version)           echo "greenanalyzer $VERSION"; exit 0 ;;

  # ── Offline OpenAPI linter ──
  lint)
    chmod +x "$SCRIPTS/"*.sh 2>/dev/null || true
    exec python3 "$SCRIPTS/green-api-lint.py" "$@"
    ;;

  # ── Interactive web dashboard ──
  serve)
    chmod +x "$SCRIPTS/"*.sh 2>/dev/null || true
    # The bridge expects to find dashboard/ next to scripts/, which is the
    # case inside the bundle.
    cd "$BUNDLE_DIR"
    exec python3 "$SCRIPTS/greenapianalyzer-server.py" "$@"
    ;;

  # ── Live Green Score analysis (default) ──
  analyze)
    PASSTHROUGH=()
    OUTPUT_DIR="${GREEN_OUTPUT_DIR:-$PWD/greenanalyzer-output}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --help|-h)        show_help; exit 0 ;;
        --version)        echo "greenanalyzer $VERSION"; exit 0 ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2; continue ;;
        *)                PASSTHROUGH+=("$1"); shift ;;
      esac
    done

    mkdir -p "$OUTPUT_DIR/reports" "$OUTPUT_DIR/dashboard" "$OUTPUT_DIR/badges"
    export APPNAME="${APPNAME:-greenanalyzer-cli}"
    export BEARER_TOKEN="${BEARER_TOKEN:-}"

    # Wire the bundle's reports/badges to the user-chosen output dir so
    # every embedded script appears stateless from the outside.
    mkdir -p "$BUNDLE_DIR/reports" "$BUNDLE_DIR/dashboard" "$BUNDLE_DIR/badges"
    rm -rf "$BUNDLE_DIR/reports" "$BUNDLE_DIR/badges"
    ln -s "$OUTPUT_DIR/reports"   "$BUNDLE_DIR/reports"
    ln -s "$OUTPUT_DIR/badges"    "$BUNDLE_DIR/badges"
    cp -n "$BUNDLE_DIR/dashboard/index.save.html" "$OUTPUT_DIR/dashboard/" 2>/dev/null || true

    echo ""
    echo "  🌿  Green Analyzer — running…"
    echo "  ────────────────────────────"
    echo "  Output: $OUTPUT_DIR"
    echo ""

    chmod +x "$SCRIPTS/"*.sh 2>/dev/null || true
    exec bash "$SCRIPTS/start.sh" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
    ;;

  *) echo "Unknown subcommand: $SUB" >&2; show_help; exit 2 ;;
esac
ENTRYPOINT
chmod +x "$STAGE/bundle/__entrypoint.sh"

# ── Pack the bundle ──
echo "🗜️  Packing bundle..."
( cd "$STAGE" && tar -czf bundle.tar.gz -C bundle . )
PAYLOAD_SIZE=$(wc -c < "$STAGE/bundle.tar.gz" | tr -d ' ')

# ── Write the self-extracting binary ──
echo "🛠️  Writing self-extracting binary → $OUTPUT"
cat > "$OUTPUT" <<'WRAPPER'
#!/usr/bin/env bash
###############################################################################
#  greenanalyzer — single-file binary.  Implementation is bundled below.
#  DO NOT edit. Rebuild with: bash scripts/build-binary.sh
###############################################################################
set -uo pipefail

# Resolve self path (handles symlinks).
__SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$__SELF" ]; do __SELF="$(readlink "$__SELF")"; done
__SELF="$(cd "$(dirname "$__SELF")" && pwd)/$(basename "$__SELF")"

# Extract the embedded bundle to a temp dir and run the CLI entrypoint.
__TMP="$(mktemp -d -t greenanalyzer.XXXXXX)"
__KEEP="${GREENANALYZER_KEEP_TMP:-0}"
cleanup() {
  if [ "$__KEEP" != "1" ]; then
    rm -rf "$__TMP" 2>/dev/null || true
  else
    echo "🪣  Bundle preserved at: $__TMP" >&2
  fi
}
trap cleanup EXIT INT TERM

# Locate the payload marker in this very file.
__PAYLOAD_LINE=$(awk '/^__GREENANALYZER_PAYLOAD__$/ {print NR + 1; exit 0}' "$__SELF")
if [ -z "${__PAYLOAD_LINE:-}" ]; then
  echo "❌ Internal error: payload marker not found in $__SELF" >&2
  exit 2
fi

# Decode + extract.
tail -n "+${__PAYLOAD_LINE}" "$__SELF" | base64 -d 2>/dev/null | tar -xzf - -C "$__TMP" \
  || { echo "❌ Failed to extract embedded bundle." >&2; exit 2; }

export BUNDLE_DIR="$__TMP"
exec bash "$__TMP/__entrypoint.sh" "$@"

__GREENANALYZER_PAYLOAD__
WRAPPER

# Append the base64-encoded tar.gz right after the marker line.
base64 < "$STAGE/bundle.tar.gz" >> "$OUTPUT"

chmod +x "$OUTPUT"

BIN_SIZE=$(wc -c < "$OUTPUT" | tr -d ' ')
echo ""
echo "✅  Built: $OUTPUT"
echo "    Payload (compressed): ${PAYLOAD_SIZE} bytes"
echo "    Final binary:         ${BIN_SIZE} bytes"
echo ""
echo "Try it:"
echo "    $OUTPUT --help"
echo "    $OUTPUT --target http://localhost:8080"

