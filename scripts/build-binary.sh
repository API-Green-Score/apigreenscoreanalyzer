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
mkdir -p "$STAGE/bundle"

# Scripts (analyzer + helpers)
mkdir -p "$STAGE/bundle/scripts"
cp "$GREEN_DIR/scripts/green-api-auto-discover.py"            "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/green-score-analyzer_withdiscovery.sh" "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/creedengo-analyzer.sh"                 "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/creedengo-detect-stack.py"             "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/creedengo-extract-results.py"          "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/_container-runtime.sh"                 "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/generate-badge.sh"                     "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/generate-dashboard.sh"                 "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/generate-dashboard.py"                 "$STAGE/bundle/scripts/"
cp "$GREEN_DIR/scripts/start.sh"                              "$STAGE/bundle/scripts/"
[ -f "$GREEN_DIR/scripts/requirements.txt" ] && \
  cp "$GREEN_DIR/scripts/requirements.txt"                    "$STAGE/bundle/scripts/"

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

show_help() {
  cat <<'HELP'

  ╔══════════════════════════════════════════════════════════════╗
  ║          🌿  Green Analyzer — API Eco-Scoring CLI            ║
  ║          Single-binary edition                               ║
  ╚══════════════════════════════════════════════════════════════╝

  Measures the eco-design quality of any REST API and produces
  a Green Score out of 100 (badge + HTML dashboard + JSON report).

  USAGE
    greenanalyzer [OPTIONS]

  CORE OPTIONS
    --target  URL              Base URL of the API (repeat or use --targets CSV)
    --targets URL,URL,...      Comma-separated list of base URLs
    --swagger URL|FILE         OpenAPI/Swagger spec (URL or local file)
    --swaggers CSV             Comma-separated list of specs
    --bearer  TOKEN            Bearer token for authenticated APIs
                               (or env BEARER_TOKEN=…)
    --appname NAME             Application name in reports
    --repeat  N                Measurement repetitions (default: 3)
    --output-dir DIR           Where reports/dashboard/badges land
                               (default: $PWD/greenanalyzer-output)
    --debug                    Verbose analyzer output
    --version                  Print version and exit
    --help, -h                 This help

  ECO-DESIGN CODE ANALYSIS (optional, requires Docker/Podman)
    --creedengo                Also run Creedengo static analysis
    --git-repo  URL            Clone a remote repo for Creedengo
    --git-branch BRANCH        Branch/tag for --git-repo
    --git-subdir DIR           Sub-folder inside the cloned repo
    --git-keep                 Keep the cloned working copy after analysis
    --root PATH                Local project to analyze (instead of CWD)

  EXAMPLES
    greenanalyzer --target http://localhost:8080
    greenanalyzer --targets http://api1:8080,http://api2:8080
    greenanalyzer --target http://my-api:8080 --bearer "eyJhb..." --repeat 5
    greenanalyzer --creedengo --git-repo https://github.com/owner/repo.git \
                  --git-branch develop

  OUTPUT (under --output-dir, default ./greenanalyzer-output/)
    reports/latest-report.json   Machine-readable Green Score report
    dashboard/index.html         Interactive HTML dashboard
    badges/green-score.svg       Score badge for README

HELP
}

VERSION="1.0.0"

# Parse only flags that influence the runtime; everything else is passed
# through to start.sh (which already accepts the same vocabulary).
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

# Prepare user-visible output tree.
mkdir -p "$OUTPUT_DIR/reports" "$OUTPUT_DIR/dashboard" "$OUTPUT_DIR/badges"

# Make the bundle writable (some scripts copy reports next to themselves).
# We mirror reports/dashboard/badges into the user's $OUTPUT_DIR via env
# overrides so the binary appears stateless.
export APPNAME="${APPNAME:-greenanalyzer-cli}"
export BEARER_TOKEN="${BEARER_TOKEN:-}"

# Symlink the bundle's reports/dashboard/badges to the user's output dir so
# every script in the bundle that writes to "$GREEN_DIR/reports/..." actually
# writes into the user's chosen folder.
mkdir -p "$BUNDLE_DIR/reports" "$BUNDLE_DIR/dashboard" "$BUNDLE_DIR/badges"
# Overwrite with the user dir
rm -rf "$BUNDLE_DIR/reports" "$BUNDLE_DIR/badges"
ln -s "$OUTPUT_DIR/reports"   "$BUNDLE_DIR/reports"
ln -s "$OUTPUT_DIR/badges"    "$BUNDLE_DIR/badges"
# Dashboard: copy templates first (index.save.html), then point output dir
cp -n "$BUNDLE_DIR/dashboard/index.save.html" "$OUTPUT_DIR/dashboard/" 2>/dev/null || true

echo ""
echo "  🌿  Green Analyzer — running…"
echo "  ────────────────────────────"
echo "  Output: $OUTPUT_DIR"
echo ""

# Forward to start.sh which already understands every CLI flag.
chmod +x "$SCRIPTS/"*.sh 2>/dev/null || true
exec bash "$SCRIPTS/start.sh" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
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

