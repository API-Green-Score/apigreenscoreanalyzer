#!/usr/bin/env bash
###############################################################################
#  Build a small self-contained `green-api-lint` binary.
#
#  This is a *lightweight* counterpart to `greenanalyzer`: it ships ONLY the
#  offline OpenAPI linter (no live HTTP probing, no dashboard, no badges) so
#  it's tiny (≈ 20 KB) and trivially deployable on dev laptops, pre-commit
#  hooks, CI workers and IDE plugins.
#
#  Output:
#    dist/green-api-lint        ← single-file executable (chmod +x)
#
#  Usage:
#    bash scripts/build-lint-binary.sh
#    bash scripts/build-lint-binary.sh --output ./green-api-lint-1.1.0
###############################################################################
set -euo pipefail

GREEN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$GREEN_DIR/dist/green-api-lint"

while [ $# -gt 0 ]; do
  case "$1" in
    --output|-o) OUTPUT="$2"; shift 2 ;;
    --help|-h)   sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$(dirname "$OUTPUT")"

STAGE="$(mktemp -d)"
trap "rm -rf '$STAGE'" EXIT

mkdir -p "$STAGE/bundle"
cp "$GREEN_DIR/scripts/green-api-lint.py" "$STAGE/bundle/lint.py"

cat > "$STAGE/bundle/__entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -uo pipefail
: "${BUNDLE_DIR:=$(cd "$(dirname "$0")" && pwd)}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ python3 is required for green-api-lint." >&2
  exit 2
fi
exec python3 "$BUNDLE_DIR/lint.py" "$@"
ENTRYPOINT
chmod +x "$STAGE/bundle/__entrypoint.sh"

( cd "$STAGE" && tar -czf bundle.tar.gz -C bundle . )

cat > "$OUTPUT" <<'WRAPPER'
#!/usr/bin/env bash
###############################################################################
#  green-api-lint — single-file binary (offline OpenAPI Green linter).
#  Rebuild with: bash scripts/build-lint-binary.sh
###############################################################################
set -uo pipefail
__SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$__SELF" ]; do __SELF="$(readlink "$__SELF")"; done
__SELF="$(cd "$(dirname "$__SELF")" && pwd)/$(basename "$__SELF")"

__TMP="$(mktemp -d -t greenapilint.XXXXXX)"
trap 'rm -rf "$__TMP" 2>/dev/null || true' EXIT INT TERM

__PAYLOAD_LINE=$(awk '/^__GREEN_API_LINT_PAYLOAD__$/ {print NR + 1; exit 0}' "$__SELF")
[ -n "${__PAYLOAD_LINE:-}" ] || { echo "❌ payload marker missing" >&2; exit 2; }

tail -n "+${__PAYLOAD_LINE}" "$__SELF" | base64 -d 2>/dev/null | tar -xzf - -C "$__TMP" \
  || { echo "❌ Failed to extract bundle." >&2; exit 2; }

export BUNDLE_DIR="$__TMP"
exec bash "$__TMP/__entrypoint.sh" "$@"

__GREEN_API_LINT_PAYLOAD__
WRAPPER

base64 < "$STAGE/bundle.tar.gz" >> "$OUTPUT"
chmod +x "$OUTPUT"

echo "✅  Built: $OUTPUT  ($(wc -c < "$OUTPUT" | tr -d ' ') bytes)"
echo ""
echo "Try it:"
echo "    $OUTPUT path/to/openapi.yaml"
echo "    $OUTPUT path/to/openapi.yaml --format json"

