#!/usr/bin/env bash
###############################################################################
#  build.sh — one-shot builder for the IntelliJ "API Green Score" plugin.
#
#  No prerequisites beyond `java` (JDK 17+) and `curl`. Downloads a portable
#  copy of Gradle on first run into ~/.cache/greenanalyzer-gradle/ and uses it
#  to produce the installable plugin zip:
#
#      build/distributions/green-api-intellij-plugin-<version>.zip
#
#  Usage:
#      bash build.sh                # builds the plugin
#      bash build.sh runIde         # opens a sandbox IDE with the plugin
#      bash build.sh clean build    # any gradle args are passed through
###############################################################################
set -euo pipefail

GRADLE_VERSION="8.10.2"
CACHE_DIR="${GREENANALYZER_GRADLE_CACHE:-$HOME/.cache/greenanalyzer-gradle}"
GRADLE_HOME="$CACHE_DIR/gradle-$GRADLE_VERSION"
GRADLE_BIN="$GRADLE_HOME/bin/gradle"
GRADLE_URL="https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"

cd "$(dirname "$0")"

# ── Java check ───────────────────────────────────────────────────────────────
if ! command -v java >/dev/null 2>&1; then
  echo "❌ Java (JDK 17+) is required. Install Temurin/Adoptium or 'brew install openjdk@17'." >&2
  exit 1
fi

# ── Bootstrap Gradle (only once) ─────────────────────────────────────────────
if [ ! -x "$GRADLE_BIN" ]; then
  echo "⬇️  Downloading Gradle $GRADLE_VERSION (one-time, ~140 MB) …"
  mkdir -p "$CACHE_DIR"
  TMP_ZIP="$CACHE_DIR/gradle.zip"
  curl -fL --retry 3 -o "$TMP_ZIP" "$GRADLE_URL"
  ( cd "$CACHE_DIR" && unzip -q -o gradle.zip )
  rm -f "$TMP_ZIP"
  echo "   ✓ Gradle ready at $GRADLE_HOME"
fi

# ── Run ──────────────────────────────────────────────────────────────────────
ARGS=("$@")
if [ ${#ARGS[@]} -eq 0 ]; then
  ARGS=(buildPlugin)
fi

echo "🛠   gradle ${ARGS[*]}"
exec "$GRADLE_BIN" --no-daemon "${ARGS[@]}"

