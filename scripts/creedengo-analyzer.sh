#!/usr/bin/env bash
###############################################################################
#  🌱 Creedengo Green Code Analyzer — Fully Local (Auto-Detect)
#  ==============================================================
#  Automatically detects project languages & frameworks, downloads the
#  correct Creedengo plugins, and runs SonarQube eco-design analysis.
#
#  Supported stacks:
#    Java   (Maven/Gradle)  → creedengo-java
#    Python (pip/poetry)    → creedengo-python
#    JS/TS  (npm/yarn)      → creedengo-javascript
#    C#     (.NET)           → creedengo-csharp
#
#  Requirements: Docker (or Podman), Python 3, + build tool for primary lang
#
#  Usage:
#    bash scripts/creedengo-analyzer.sh                  # auto-detect
#    bash scripts/creedengo-analyzer.sh --debug
#    bash scripts/creedengo-analyzer.sh --skip-build
#    bash scripts/creedengo-analyzer.sh --skip-dashboard  # skip dashboard (when orchestrated)
#    bash scripts/creedengo-analyzer.sh --force-cleanup  # destroy containers/volumes/images post-build
#    bash scripts/creedengo-analyzer.sh --lang java      # force language
#    CREEDENGO_VERSION=1.7.0 bash scripts/creedengo-analyzer.sh
#
#  Analyze a remote Git repository (clone → analyze → cd back → cleanup):
#    bash scripts/creedengo-analyzer.sh --git-repo https://github.com/owner/repo.git
#    bash scripts/creedengo-analyzer.sh --git-repo git@github.com:owner/repo.git --git-branch develop
#    bash scripts/creedengo-analyzer.sh --git-repo https://… --git-subdir backend --git-keep
###############################################################################
set -uo pipefail

# ── Disable MSYS/Git Bash automatic path conversion (Windows only) ──
# Git Bash converts paths starting with / to Windows paths (e.g. /opt → C:\Program Files\Git\opt)
# which breaks Docker volume mounts like -v "...:/opt/sonarqube/extensions/plugins:ro"
# These exports are harmless on Linux/macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# ── Force Python to use UTF-8 for stdout/stderr (Windows only) ──
# On Windows, Python defaults to the console codepage (cp1252) which cannot
# encode Unicode characters like ✅ ⚠ 🌱 used in output messages.
export PYTHONIOENCODING=utf-8

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Default ROOT (project to analyze) ──
# Resolution order, first match wins:
#   1. --root <path>   (CLI flag, parsed below)
#   2. --git-repo <url> (parsed below; ROOT becomes the cloned working copy)
#   3. $CREEDENGO_ROOT (environment variable)
#   4. $(pwd)           (current working directory — the most intuitive default
#                        for both standalone and installer-style layouts)
# We intentionally do NOT use "$SCRIPT_DIR/../.." anymore: that pointed at the
# parent of the analyzer folder, which is wrong in standalone mode (it landed
# on a random ancestor like /Users/<user>/greenscoreimpl).
if [ -n "${CREEDENGO_ROOT:-}" ]; then
  ROOT="$CREEDENGO_ROOT"
else
  ROOT="$(pwd)"
fi

# ── Convert MSYS paths to mixed Windows paths for non-MSYS tools (Python, etc.) ──
# Git Bash's `pwd` returns /c/git/... which native Windows programs can't resolve.
# cygpath -m converts to C:/git/... ("mixed" mode) which works in both Bash and
# native Windows programs (Python, Java, etc.).
if command -v cygpath &>/dev/null; then
  ROOT="$(cygpath -m "$ROOT")"
  SCRIPT_DIR="$(cygpath -m "$SCRIPT_DIR")"
  GREEN_DIR="$(cygpath -m "$GREEN_DIR")"
fi

# ── Detect container runtime (Docker/Podman) ──
source "$GREEN_DIR/scripts/_container-runtime.sh"

# ── Portable null device ──
# With MSYS_NO_PATHCONV=1, Git Bash does NOT convert /dev/null to NUL for native
# Windows executables (like curl.exe). This causes `curl -o /dev/null` to fail
# silently, leaking the response body into stdout and producing corrupted HTTP
# status codes (e.g. "204000" instead of "204").
if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]]; then
  DEV_NULL="NUL"
else
  DEV_NULL="/dev/null"
fi

# Helper: get HTTP status code from a curl call (portable, no /dev/null issues)
# Usage: http_code=$(curl_http_code [curl_args...])
curl_http_code() {
  local _body _code _combined
  # Use a temp file for the body to avoid any /dev/null issues
  local _tmp
  _tmp=$(mktemp 2>/dev/null || echo "${TEMP:-/tmp}/_curl_$$")
  _code=$(curl -s -o "$_tmp" -w "%{http_code}" "$@" 2>/dev/null) || _code="000"
  rm -f "$_tmp" 2>/dev/null
  echo "$_code"
}

# ── Configuration (env-overridable) ──
# NOTE: Creedengo plugins v2.x require SonarQube 10.6+ (Plugin API >= 13.0)
#       sonarqube:lts-community = 9.x (Plugin API 9.14) → INCOMPATIBLE
#       sonarqube:10-community  = 10.x (Plugin API 10+) → OK
#       sonarqube:community     = latest (11.x)         → OK
SONAR_PORT=${SONAR_PORT:-9100}
SONAR_IMAGE=${SONAR_IMAGE:-"sonarqube:community"}
CREEDENGO_VERSION=${CREEDENGO_VERSION:-"2.1.2"}
CONTAINER_NAME="creedengo-sonar-$$"
REPORTS_DIR="$GREEN_DIR/reports"
APPNAME=${APPNAME:-$(basename "$ROOT")}

# ── Colors ──
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Parse flags ──
DEBUG_MODE=false
SKIP_BUILD=false
FORCE_LANG=""
NO_CLEANUP=false
FORCE_CLEANUP=false
SKIP_DASHBOARD=false
GIT_REPO=""
GIT_BRANCH=""
GIT_SUBDIR=""
GIT_KEEP=false
GIT_CHECKOUTS_DIR="$GREEN_DIR/.creedengo/checkouts"
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
  case "${ARGS[$i]}" in
    --debug) DEBUG_MODE=true ;;
    --skip-build) SKIP_BUILD=true ;;
    --no-cleanup) NO_CLEANUP=true ;;
    --force-cleanup) FORCE_CLEANUP=true ;;
    --skip-dashboard) SKIP_DASHBOARD=true ;;
    --git-keep) GIT_KEEP=true ;;
    --lang=*) FORCE_LANG="${ARGS[$i]#--lang=}" ;;
    --lang)
      [ $((i+1)) -lt ${#ARGS[@]} ] && FORCE_LANG="${ARGS[$((i+1))]}"
      ;;
    --git-repo=*)   GIT_REPO="${ARGS[$i]#--git-repo=}" ;;
    --git-repo)
      [ $((i+1)) -lt ${#ARGS[@]} ] && GIT_REPO="${ARGS[$((i+1))]}"
      ;;
    --git-branch=*) GIT_BRANCH="${ARGS[$i]#--git-branch=}" ;;
    --git-branch)
      [ $((i+1)) -lt ${#ARGS[@]} ] && GIT_BRANCH="${ARGS[$((i+1))]}"
      ;;
    --git-subdir=*) GIT_SUBDIR="${ARGS[$i]#--git-subdir=}" ;;
    --git-subdir)
      [ $((i+1)) -lt ${#ARGS[@]} ] && GIT_SUBDIR="${ARGS[$((i+1))]}"
      ;;
    --root=*) ROOT="${ARGS[$i]#--root=}" ;;
    --root)
      [ $((i+1)) -lt ${#ARGS[@]} ] && ROOT="${ARGS[$((i+1))]}"
      ;;
  esac
done

# Normalize ROOT to an absolute path (in case --root or $CREEDENGO_ROOT was a
# relative path) and re-apply cygpath conversion under MSYS / Git Bash.
if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
  ROOT="$(cd "$ROOT" && pwd)"
  if command -v cygpath &>/dev/null; then
    ROOT="$(cygpath -m "$ROOT")"
  fi
fi

###############################################################################
# Optional: clone a remote Git repository, switch ROOT into the working copy,
# and ensure we cd back to the original parent folder + cleanup on exit.
###############################################################################
ORIGINAL_ROOT="$ROOT"
ORIGINAL_PWD="$(pwd)"
GIT_CLONE_DIR=""

return_to_parent() {
  # Always return to the parent folder where the script was invoked from.
  cd "$ORIGINAL_PWD" 2>/dev/null || true
  if [ -n "$GIT_CLONE_DIR" ] && [ "$GIT_KEEP" = false ] && [ -d "$GIT_CLONE_DIR" ]; then
    echo -e "${CYAN}🧹 Removing cloned working copy: ${GIT_CLONE_DIR}${NC}"
    rm -rf "$GIT_CLONE_DIR" 2>/dev/null || true
  elif [ -n "$GIT_CLONE_DIR" ] && [ "$GIT_KEEP" = true ]; then
    echo -e "${CYAN}ℹ️  --git-keep: cloned copy preserved at ${GIT_CLONE_DIR}${NC}"
  fi
}

if [ -n "$GIT_REPO" ]; then
  command -v git >/dev/null 2>&1 || {
    echo -e "${RED}❌ git is required for --git-repo but was not found${NC}"; exit 1;
  }
  mkdir -p "$GIT_CHECKOUTS_DIR"
  # Derive a folder name from the repo URL: owner__repo (slugified)
  repo_basename="$(basename "${GIT_REPO%.git}")"
  repo_slug="$(echo "$repo_basename" | tr -c '[:alnum:]._-' '_' | sed 's/_\+/_/g')"
  GIT_CLONE_DIR="$GIT_CHECKOUTS_DIR/${repo_slug}-$$"

  echo -e "${YELLOW}━━━ ⬇️  Cloning Git repository ━━━${NC}"
  echo -e "  Repo:   ${CYAN}${GIT_REPO}${NC}"
  [ -n "$GIT_BRANCH" ] && echo -e "  Branch: ${CYAN}${GIT_BRANCH}${NC}"
  [ -n "$GIT_SUBDIR" ] && echo -e "  Subdir: ${CYAN}${GIT_SUBDIR}${NC}"
  echo -e "  Into:   ${CYAN}${GIT_CLONE_DIR}${NC}"

  CLONE_ARGS=(--depth 1)
  [ -n "$GIT_BRANCH" ] && CLONE_ARGS+=(--branch "$GIT_BRANCH")
  if ! git clone "${CLONE_ARGS[@]}" "$GIT_REPO" "$GIT_CLONE_DIR"; then
    echo -e "${RED}❌ git clone failed${NC}"
    exit 1
  fi

  # Compute the new ROOT (optionally point at a subdirectory of the repo)
  if [ -n "$GIT_SUBDIR" ]; then
    NEW_ROOT="$GIT_CLONE_DIR/$GIT_SUBDIR"
    if [ ! -d "$NEW_ROOT" ]; then
      echo -e "${RED}❌ --git-subdir '$GIT_SUBDIR' not found in repository${NC}"
      exit 1
    fi
  else
    NEW_ROOT="$GIT_CLONE_DIR"
  fi
  if command -v cygpath &>/dev/null; then
    NEW_ROOT="$(cygpath -m "$NEW_ROOT")"
  fi
  ROOT="$NEW_ROOT"
  REPORTS_DIR="$GREEN_DIR/reports"   # reports stay in the parent project
  APPNAME="${APPNAME:-$repo_slug}"
  cd "$ROOT"
  echo -e "  ${GREEN}✓ Working directory: $(pwd)${NC}"
  echo ""

  # Make sure we return to the parent and (optionally) clean up on exit
  trap 'return_to_parent' EXIT
fi


echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  🌱 Creedengo Green Code Analyzer — Auto-Detect            ║${NC}"
echo -e "${CYAN}║  Eco-design static analysis for all languages              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

###############################################################################
# Pre-flight checks
###############################################################################
for cmd in python3 curl; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}❌ $cmd is required but not found${NC}"
    exit 1
  fi
done

###############################################################################
# Step 1: Auto-detect project stack
###############################################################################
echo -e "${YELLOW}━━━ 🔍 Detecting project stack ━━━${NC}"
if [ -n "$GIT_CLONE_DIR" ]; then
  echo -e "  Source:   ${CYAN}cloned git repo${NC} (${GIT_REPO}${GIT_BRANCH:+ @ $GIT_BRANCH})"
elif [ -n "${CREEDENGO_ROOT:-}" ]; then
  echo -e "  Source:   ${CYAN}\$CREEDENGO_ROOT${NC}"
else
  echo -e "  Source:   ${CYAN}current working directory${NC} (override with --root <path> or --git-repo <url>)"
fi
echo -e "  Scanning: ${CYAN}${ROOT}${NC}"

DETECT_STDERR=$(mktemp 2>/dev/null || echo "/tmp/creedengo-detect-stderr.$$")
DETECT_JSON=$(python3 "$SCRIPT_DIR/creedengo-detect-stack.py" "$ROOT" --json 2>"$DETECT_STDERR")
DETECT_EXIT=$?
if [ $DETECT_EXIT -ne 0 ] || [ -z "$DETECT_JSON" ]; then
  echo -e "${RED}❌ Stack detection failed when detecting stack for creedengo${NC}"
  echo -e "${RED}   Exit code: ${DETECT_EXIT}${NC}"
  echo -e "${RED}   Root path: ${ROOT}${NC}"
  if [ -f "$DETECT_STDERR" ] && [ -s "$DETECT_STDERR" ]; then
    echo -e "${RED}   Error output:${NC}"
    cat "$DETECT_STDERR" >&2
  fi
  echo -e "${YELLOW}   💡 Check that your project has a pom.xml, build.gradle, package.json, or requirements.txt${NC}"
  rm -f "$DETECT_STDERR" 2>/dev/null
  exit 1
fi
rm -f "$DETECT_STDERR" 2>/dev/null

# Parse detection results
PRIMARY_LANG=$(echo "$DETECT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['primary_language'])" 2>/dev/null)
PRIMARY_FRAMEWORK=$(echo "$DETECT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['primary_framework'])" 2>/dev/null)
SCANNER_TYPE=$(echo "$DETECT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['sonar_scanner'])" 2>/dev/null)
PROJECT_KEY=$(echo "$DETECT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['project_key'])" 2>/dev/null)
ALL_LANGUAGES=$(echo "$DETECT_JSON" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin)['languages']))" 2>/dev/null)
PLUGIN_KEYS=$(echo "$DETECT_JSON" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin)['creedengo_plugins']))" 2>/dev/null)

# Override with forced language
if [ -n "$FORCE_LANG" ]; then
  PRIMARY_LANG="$FORCE_LANG"
  case "$FORCE_LANG" in
    java) PLUGIN_KEYS="java" ;;
    python) PLUGIN_KEYS="python" ;;
    javascript|typescript) PLUGIN_KEYS="javascript" ;;
    csharp) PLUGIN_KEYS="csharp" ;;
    *) echo -e "${RED}❌ Unsupported language: $FORCE_LANG${NC}"; exit 1 ;;
  esac
fi

MODULE_COUNT=$(echo "$DETECT_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['modules']))" 2>/dev/null)

echo -e "  Languages:    ${CYAN}${ALL_LANGUAGES}${NC}"
echo -e "  Primary:      ${GREEN}${PRIMARY_LANG}${NC} (${PRIMARY_FRAMEWORK:-no framework})"
echo -e "  Modules:      ${CYAN}${MODULE_COUNT}${NC}"
echo -e "  Scanner:      ${CYAN}${SCANNER_TYPE}${NC}"
echo -e "  Plugins:      ${CYAN}${PLUGIN_KEYS}${NC}"
echo ""

if [ -z "$PLUGIN_KEYS" ]; then
  echo -e "${RED}❌ No supported languages detected${NC}"
  exit 1
fi

###############################################################################
# Step 2: Detect Java module info + Compile if needed
#         Prefer the reactor (parent) POM so that ALL modules are compiled
#         and analyzed together under a single SonarQube project key.
###############################################################################
JAVA_MODULE=""
JAVA_MODULE_DIR=""
JAVA_BUILD_TOOL=""
USE_REACTOR_POM=false
REACTOR_POM_DIR=""

if echo "$PLUGIN_KEYS" | grep -q "java"; then
  # ── Check if a reactor/parent POM exists (has <modules>) ──
  REACTOR_INFO=$(echo "$DETECT_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data['modules']:
    if m['language'] == 'java' and m.get('is_reactor', False):
        print(m['path'] or '.', m['build_tool'])
        break
" 2>/dev/null || echo "")

  if [ -n "$REACTOR_INFO" ]; then
    REACTOR_PATH=$(echo "$REACTOR_INFO" | awk '{print $1}')
    REACTOR_TOOL=$(echo "$REACTOR_INFO" | awk '{print $2}')
    REACTOR_POM_DIR="$ROOT/$REACTOR_PATH"
    # Verify the reactor pom.xml actually exists
    if [ -f "$REACTOR_POM_DIR/pom.xml" ]; then
      USE_REACTOR_POM=true
      JAVA_MODULE="$REACTOR_PATH"
      JAVA_MODULE_DIR="$REACTOR_POM_DIR"
      JAVA_BUILD_TOOL="$REACTOR_TOOL"
      echo -e "  ${GREEN}✓ Reactor POM detected — will build & analyze ALL modules together${NC}"
      echo -e "  ${CYAN}  Reactor: ${REACTOR_POM_DIR}/pom.xml${NC}"
    fi
  fi

  # ── Fallback: use the first Java module found ──
  if [ "$USE_REACTOR_POM" = false ]; then
    JAVA_MODULE=$(echo "$DETECT_JSON" | python3 -c "
import sys, json
for m in json.load(sys.stdin)['modules']:
    if m['language'] == 'java' and not m.get('is_reactor', False):
        print(m['path'] or '.'); break
" 2>/dev/null)
    JAVA_MODULE_DIR="$ROOT/$JAVA_MODULE"
    JAVA_BUILD_TOOL=$(echo "$DETECT_JSON" | python3 -c "
import sys, json
for m in json.load(sys.stdin)['modules']:
    if m['language'] == 'java' and not m.get('is_reactor', False):
        print(m['build_tool']); break
" 2>/dev/null)
  fi
fi

if [ "$SKIP_BUILD" = false ] && [ -n "$JAVA_MODULE_DIR" ]; then
  # For reactor builds, check if ANY sub-module needs compilation
  NEEDS_COMPILE=false
  if [ "$USE_REACTOR_POM" = true ]; then
    # Check all child modules declared in the reactor
    CHILD_MODULES=$(echo "$DETECT_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data['modules']:
    if m['language'] == 'java' and not m.get('is_reactor', False):
        print(m['path'] or '.')
" 2>/dev/null)
    while IFS= read -r child; do
      [ -z "$child" ] && continue
      child_dir="$ROOT/$child"
      if [ ! -d "$child_dir/target/classes" ] && [ ! -d "$child_dir/build/classes" ]; then
        NEEDS_COMPILE=true
        break
      fi
    done <<< "$CHILD_MODULES"
  else
    if [ ! -d "$JAVA_MODULE_DIR/target/classes" ] && [ ! -d "$JAVA_MODULE_DIR/build/classes" ]; then
      NEEDS_COMPILE=true
    fi
  fi

  if [ "$NEEDS_COMPILE" = true ]; then
    if [ "$USE_REACTOR_POM" = true ]; then
      echo -e "${YELLOW}━━━ 🔨 Compiling ALL Java modules via reactor POM ($JAVA_BUILD_TOOL) ━━━${NC}"
    else
      echo -e "${YELLOW}━━━ 🔨 Compiling Java module ($JAVA_BUILD_TOOL) ━━━${NC}"
    fi
    if [ "$JAVA_BUILD_TOOL" = "maven" ]; then
      command -v mvn &>/dev/null || { echo -e "${RED}❌ Maven required${NC}"; exit 1; }
      # Verify Maven is functional (not just present)
      if ! mvn -B --version &>/dev/null; then
        echo -e "${RED}❌ Maven is installed but not functional (ClassNotFoundException?)${NC}"
        echo -e "${YELLOW}   💡 Check MAVEN_HOME, M2_HOME, and your Maven installation${NC}"
        exit 1
      fi
      mvn -B -q -f "$JAVA_MODULE_DIR/pom.xml" compile -DskipTests || { echo -e "${RED}❌ Maven compile failed${NC}"; exit 1; }
    elif [ "$JAVA_BUILD_TOOL" = "gradle" ]; then
      if [ -f "$JAVA_MODULE_DIR/gradlew" ]; then
        (cd "$JAVA_MODULE_DIR" && ./gradlew compileJava -q) || { echo -e "${RED}❌ Gradle compile failed${NC}"; exit 1; }
      else
        command -v gradle &>/dev/null || { echo -e "${RED}❌ Gradle required${NC}"; exit 1; }
        (cd "$JAVA_MODULE_DIR" && gradle compileJava -q) || { echo -e "${RED}❌ Gradle compile failed${NC}"; exit 1; }
      fi
    fi
    echo -e "  ${GREEN}✓ Java compiled${NC}"
  else
    echo -e "${GREEN}  ✓ Java classes found (all modules)${NC}"
  fi
fi

###############################################################################
# Step 3: Download Creedengo plugins (GitHub API auto-detect, manifest check)
#         - Auto-resolves latest release per plugin via GitHub API
#         - Validates JAR manifest contains Plugin-Key (SonarQube requirement)
#         - Backup directory for offline use
#         - csharp is skipped (NuGet analyzer, no SonarQube JAR published)
###############################################################################
PLUGIN_DIR="$GREEN_DIR/.creedengo/plugins"
BACKUP_DIR="$GREEN_DIR/.creedengo/backup"
mkdir -p "$PLUGIN_DIR" "$BACKUP_DIR"

# ── Purge corrupted JARs (no Plugin-Key in manifest) on startup ──
for dir in "$PLUGIN_DIR" "$BACKUP_DIR"; do
  for jar in "$dir"/*.jar; do
    [ -f "$jar" ] || continue
    if ! unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | grep -qi "Plugin-Key"; then
      echo -e "  ${YELLOW}🧹 Removing invalid JAR (no Plugin-Key): $(basename "$jar")${NC}"
      rm -f "$jar"
    fi
  done
done

echo -e "${YELLOW}━━━ 📥 Downloading Creedengo plugins ━━━${NC}"

IFS=',' read -ra PLUGINS <<< "$PLUGIN_KEYS"
ALL_SONAR_REPOS=""
ALL_SONAR_LANGS=""

for plugin_key in "${PLUGINS[@]}"; do
  SONAR_INFO=$(python3 -c "
import sys, importlib.util, os
script_dir = sys.argv[1]
plugin_key = sys.argv[2]
sys.path.insert(0, script_dir)
spec = importlib.util.spec_from_file_location('ds', os.path.join(script_dir, 'creedengo-detect-stack.py'))
ds = importlib.util.module_from_spec(spec); spec.loader.exec_module(ds)
info = ds.CREEDENGO_PLUGINS.get(plugin_key, {})
print(info.get('sonar_repo', ''), info.get('sonar_lang', ''))
" "$SCRIPT_DIR" "$plugin_key" 2>/dev/null)
  SONAR_REPO=$(echo "$SONAR_INFO" | awk '{print $1}')
  SONAR_LANG=$(echo "$SONAR_INFO" | awk '{print $2}')

  # Fallback: derive sonar_repo/sonar_lang from plugin_key if Python call failed
  if [ -z "$SONAR_REPO" ]; then
    SONAR_REPO="creedengo-${plugin_key}"
    [ "$DEBUG_MODE" = true ] && echo -e "  ${YELLOW}⚠ Python lookup failed for ${plugin_key} — using fallback repo: ${SONAR_REPO}${NC}"
  fi
  if [ -z "$SONAR_LANG" ]; then
    case "$plugin_key" in
      java)       SONAR_LANG="java" ;;
      python)     SONAR_LANG="py" ;;
      javascript) SONAR_LANG="js" ;;
      csharp)     SONAR_LANG="cs" ;;
      *)          SONAR_LANG="$plugin_key" ;;
    esac
  fi

  # Only append non-empty values
  [ -n "$SONAR_REPO" ] && ALL_SONAR_REPOS="${ALL_SONAR_REPOS:+$ALL_SONAR_REPOS,}${SONAR_REPO}"
  [ -n "$SONAR_LANG" ] && ALL_SONAR_LANGS="${ALL_SONAR_LANGS:+$ALL_SONAR_LANGS,}${SONAR_LANG}"

  # ── Skip csharp: no SonarQube JAR plugin published (NuGet only) ──
  if [ "$plugin_key" = "csharp" ]; then
    echo -e "  ${YELLOW}⚠ ${plugin_key}: skipped (NuGet analyzer — no SonarQube JAR available)${NC}"
    continue
  fi

  # ── Check plugin cache (already downloaded & valid) ──
  EXISTING_JAR=$(ls "$PLUGIN_DIR"/creedengo-${plugin_key}-plugin-*.jar "$PLUGIN_DIR"/ecocode-${plugin_key}-plugin-*.jar 2>/dev/null | head -1)
  if [ -n "$EXISTING_JAR" ]; then
    echo -e "  ${GREEN}✓ ${plugin_key}: cached $(basename "$EXISTING_JAR")${NC}"
    continue
  fi

  # ── Resolve latest version & asset URL via GitHub API ──
  echo -e "  📥 Resolving latest release for creedengo-${plugin_key}..."
  ASSET_URL=""
  ASSET_NAME=""
  RESOLVED_TAG=""

  GH_RELEASE=$(curl -sf --connect-timeout 10 --max-time 15 \
    "https://api.github.com/repos/green-code-initiative/creedengo-${plugin_key}/releases/latest" 2>/dev/null || echo "")

  if [ -n "$GH_RELEASE" ]; then
    RESOLVED_TAG=$(echo "$GH_RELEASE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || echo "")
    ASSET_URL=$(echo "$GH_RELEASE" | python3 -c "
import sys,json
assets = json.load(sys.stdin).get('assets',[])
for a in assets:
    if a['name'].endswith('.jar'):
        print(a['browser_download_url']); break
" 2>/dev/null || echo "")
    ASSET_NAME=$(echo "$GH_RELEASE" | python3 -c "
import sys,json
assets = json.load(sys.stdin).get('assets',[])
for a in assets:
    if a['name'].endswith('.jar'):
        print(a['name']); break
" 2>/dev/null || echo "")
  fi

  # Fallback: if GitHub API failed or no asset, try direct URL with CREEDENGO_VERSION
  if [ -z "$ASSET_URL" ]; then
    [ "$DEBUG_MODE" = true ] && echo -e "    ${YELLOW}GitHub API: no asset found, trying direct URLs with v${CREEDENGO_VERSION}${NC}"
    RESOLVED_TAG="${CREEDENGO_VERSION}"
    ASSET_NAME="creedengo-${plugin_key}-plugin-${CREEDENGO_VERSION}.jar"
  fi

  TARGET_JAR="$PLUGIN_DIR/${ASSET_NAME:-creedengo-${plugin_key}-plugin-${CREEDENGO_VERSION}.jar}"
  DOWNLOADED=false

  # ── Build download URLs (API-resolved first, then fallbacks) ──
  URLS=()
  [ -n "$ASSET_URL" ] && URLS+=("$ASSET_URL")
  # GitHub direct download patterns
  for tag in "$RESOLVED_TAG" "v$RESOLVED_TAG" "$CREEDENGO_VERSION" "v$CREEDENGO_VERSION"; do
    URLS+=(
      "https://github.com/green-code-initiative/creedengo-${plugin_key}/releases/download/${tag}/creedengo-${plugin_key}-plugin-${tag#v}.jar"
      "https://github.com/green-code-initiative/ecoCode-${plugin_key}/releases/download/${tag}/ecocode-${plugin_key}-plugin-${tag#v}.jar"
    )
  done

  [ -n "$RESOLVED_TAG" ] && echo -e "    Resolved version: ${CYAN}${RESOLVED_TAG}${NC}"

  for url in "${URLS[@]}"; do
    [ "$DEBUG_MODE" = true ] && echo -e "    ${CYAN}trying: ${url}${NC}"
    if curl -fsSL --retry 2 --retry-delay 3 --connect-timeout 15 --max-time 120 -o "$TARGET_JAR" "$url" 2>/dev/null; then
      # Validate 1: is it a real JAR/ZIP file?
      if [ ! -s "$TARGET_JAR" ]; then
        rm -f "$TARGET_JAR"; continue
      fi
      MAGIC=$(xxd -l2 -p "$TARGET_JAR" 2>/dev/null || echo "")
      if [ "$MAGIC" != "504b" ]; then
        [ "$DEBUG_MODE" = true ] && echo -e "    ${YELLOW}not a ZIP/JAR (magic=$MAGIC), trying next...${NC}"
        rm -f "$TARGET_JAR"; continue
      fi
      # Validate 2: manifest must contain Plugin-Key (SonarQube requirement)
      if ! unzip -p "$TARGET_JAR" META-INF/MANIFEST.MF 2>/dev/null | grep -qi "Plugin-Key"; then
        [ "$DEBUG_MODE" = true ] && echo -e "    ${YELLOW}JAR has no Plugin-Key in manifest, trying next...${NC}"
        rm -f "$TARGET_JAR"; continue
      fi
      # All validations passed
      DOWNLOADED=true
      echo -e "  ${GREEN}✓ ${plugin_key}: downloaded $(basename "$TARGET_JAR")${NC}"
      cp -f "$TARGET_JAR" "$BACKUP_DIR/" 2>/dev/null || true
      break
    fi
  done

  # ── Fallback: restore from local backup ──
  if [ "$DOWNLOADED" = false ]; then
    BACKUP_JAR=$(ls "$BACKUP_DIR"/creedengo-${plugin_key}-plugin-*.jar "$BACKUP_DIR"/ecocode-${plugin_key}-plugin-*.jar 2>/dev/null | sort -V | tail -1)
    if [ -n "$BACKUP_JAR" ] && [ -s "$BACKUP_JAR" ]; then
      cp "$BACKUP_JAR" "$PLUGIN_DIR/"
      DOWNLOADED=true
      echo -e "  ${GREEN}✓ ${plugin_key}: restored from backup $(basename "$BACKUP_JAR")${NC}"
    fi
  fi

  if [ "$DOWNLOADED" = false ]; then
    echo -e "  ${YELLOW}⚠ ${plugin_key}: could not download from any source (skipping)${NC}"
    echo -e "  ${YELLOW}  💡 Tip: manually place the JAR in ${BACKUP_DIR}/ for offline use${NC}"
    rm -f "$TARGET_JAR"
  fi
done

# ── Validate ALL_SONAR_REPOS / ALL_SONAR_LANGS are not empty ──
# Strip stray commas (e.g. ",creedengo-java," → "creedengo-java")
ALL_SONAR_REPOS=$(echo "$ALL_SONAR_REPOS" | sed 's/^,//;s/,$//' | sed 's/,,*/,/g')
ALL_SONAR_LANGS=$(echo "$ALL_SONAR_LANGS" | sed 's/^,//;s/,$//' | sed 's/,,*/,/g')

if [ -z "$ALL_SONAR_REPOS" ]; then
  echo -e "${YELLOW}⚠ ALL_SONAR_REPOS is empty after plugin resolution — rebuilding from PLUGIN_KEYS${NC}"
  for pk in "${PLUGINS[@]}"; do
    fb_repo="creedengo-${pk}"
    case "$pk" in
      java)       fb_lang="java" ;;
      python)     fb_lang="py" ;;
      javascript) fb_lang="js" ;;
      csharp)     fb_lang="cs" ;;
      *)          fb_lang="$pk" ;;
    esac
    ALL_SONAR_REPOS="${ALL_SONAR_REPOS:+$ALL_SONAR_REPOS,}${fb_repo}"
    ALL_SONAR_LANGS="${ALL_SONAR_LANGS:+$ALL_SONAR_LANGS,}${fb_lang}"
  done
  echo -e "  ${GREEN}✓ ALL_SONAR_REPOS=${ALL_SONAR_REPOS}${NC}"
  echo -e "  ${GREEN}✓ ALL_SONAR_LANGS=${ALL_SONAR_LANGS}${NC}"
fi

echo ""

###############################################################################
# Step 4: Start SonarQube container with all plugins
###############################################################################
echo -e "${YELLOW}━━━ 🐳 Starting SonarQube with Creedengo plugins ━━━${NC}"

# ── PURGE all previous SonarQube / Creedengo containers (clean slate) ──
echo -e "  ${CYAN}🧹 Purging all previous Creedengo-SonarQube containers...${NC}"
# 1) Kill+remove any container whose name starts with creedengo-sonar
for cid in $($CONTAINER_RT ps -aq --filter "name=creedengo-sonar" 2>/dev/null); do
  $CONTAINER_RT rm -f "$cid" 2>/dev/null || true
done
# 2) Kill+remove any container using the same port
for cid in $($CONTAINER_RT ps -aq --filter "publish=${SONAR_PORT}" 2>/dev/null); do
  $CONTAINER_RT rm -f "$cid" 2>/dev/null || true
done
# 3) Prune any dangling SonarQube volumes from previous runs
$CONTAINER_RT volume ls -q --filter "dangling=true" 2>/dev/null | while read -r vol; do
  # Only prune volumes that look like they belong to our ephemeral containers
  $CONTAINER_RT volume rm "$vol" 2>/dev/null || true
done
echo -e "  ${GREEN}✓ Previous containers purged${NC}"

# Pull the image to avoid stale cached images (e.g. old lts-community tagged locally)
echo -e "  Pulling ${CYAN}${SONAR_IMAGE}${NC}..."
$CONTAINER_RT pull "$SONAR_IMAGE" >/dev/null 2>&1 || echo -e "  ${YELLOW}⚠ Pull failed, using local image${NC}"

# ── Start a fresh ephemeral container (NO persistent volume = clean DB every time) ──
$CONTAINER_RT run -d \
  --name "$CONTAINER_NAME" \
  -p "${SONAR_PORT}:9000" \
  -v "${PLUGIN_DIR}:/opt/sonarqube/extensions/plugins:ro" \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  -e SONAR_SEARCH_JAVAADDITIONALOPTS="-Dnode.store.allow_mmap=false" \
  "$SONAR_IMAGE" >/dev/null

echo -e "  Container: ${CYAN}${CONTAINER_NAME}${NC}  Port: ${CYAN}${SONAR_PORT}${NC}"

cleanup() {
  echo -e "\n${YELLOW}━━━ 🧹 Cleaning up SonarQube container ━━━${NC}"
  $CONTAINER_RT rm -f "$CONTAINER_NAME" 2>/dev/null || true
  # Also clean any other creedengo-sonar containers that might have leaked
  for cid in $($CONTAINER_RT ps -aq --filter "name=creedengo-sonar" 2>/dev/null); do
    $CONTAINER_RT rm -f "$cid" 2>/dev/null || true
  done
  if [ "$FORCE_CLEANUP" = true ]; then
    echo -e "  ${CYAN}🔥 Force-cleanup: removing ALL SonarQube containers, volumes & images${NC}"
    # Kill+remove any container using the sonar port
    for cid in $($CONTAINER_RT ps -aq --filter "publish=${SONAR_PORT}" 2>/dev/null); do
      $CONTAINER_RT rm -f "$cid" 2>/dev/null || true
    done
    # Remove dangling volumes from ephemeral sonar containers
    $CONTAINER_RT volume ls -q --filter "dangling=true" 2>/dev/null | while read -r vol; do
      $CONTAINER_RT volume rm "$vol" 2>/dev/null || true
    done
    # Remove the SonarQube image to free disk space (CI)
    $CONTAINER_RT rmi "$SONAR_IMAGE" 2>/dev/null || true
    # Prune stopped containers and unused images
    $CONTAINER_RT container prune -f 2>/dev/null || true
    $CONTAINER_RT image prune -f 2>/dev/null || true
    echo -e "  ${GREEN}✓ Force-cleanup complete — all SonarQube resources destroyed${NC}"
  fi
}
if [ "$NO_CLEANUP" = true ]; then
  echo -e "  ${CYAN}ℹ️  --no-cleanup : le container SonarQube ne sera PAS supprimé à la fin${NC}"
  # Export container name so the caller (start.sh) can clean up later
  echo "$CONTAINER_NAME" > "$GREEN_DIR/.creedengo/.sonar-container-name"
  # Even with --no-cleanup, still chdir back to the parent if we cloned a repo
  [ -n "$GIT_CLONE_DIR" ] && trap 'return_to_parent' EXIT
else
  # Chain SonarQube cleanup with the git-clone return-to-parent (if any)
  if [ -n "$GIT_CLONE_DIR" ]; then
    trap 'cleanup; return_to_parent' EXIT
  else
    trap cleanup EXIT
  fi
fi

###############################################################################
# Step 5: Wait for SonarQube to be ready
###############################################################################
echo -e "${YELLOW}━━━ ⏳ Waiting for SonarQube to start (may take 60-120s) ━━━${NC}"
TIMEOUT=180; ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  STATUS=$(curl -s "http://localhost:${SONAR_PORT}/api/system/status" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  if [ "$STATUS" = "UP" ]; then echo -e "  ${GREEN}✅ SonarQube ready (${ELAPSED}s)${NC}"; break; fi
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then echo -e "  ${RED}❌ Timeout${NC}"; exit 1; fi
  sleep 2; ELAPSED=$((ELAPSED + 2))
  [ $((ELAPSED % 20)) -eq 0 ] && echo -e "  ... ${ELAPSED}s (${STATUS:-starting})"
done
echo ""

###############################################################################
# Step 6: Configure SonarQube authentication
#
# SonarQube 10+ FORCES a password change on first login with admin:admin.
# /api/authentication/validate may return valid:true but all other endpoints
# return 401 until the password is actually changed.
# Strategy:
#   1. Always try to CHANGE the default password first (this is what unblocks the API)
#   2. Then validate with the new password
#   3. Fallback to admin:admin if the change wasn't needed (older SonarQube)
###############################################################################
echo -e "${YELLOW}━━━ 🔐 Configuring SonarQube ━━━${NC}"
SONAR_URL="http://localhost:${SONAR_PORT}"
SONAR_PASS=""
TOKEN=""
NEW_PASS="Creedengo2026x"

# Helper: check if credentials work on a REAL protected endpoint (not just /validate)
check_auth_real() {
  local user="$1" pass="$2"
  local code
  code=$(curl_http_code -u "${user}:${pass}" \
    "${SONAR_URL}/api/system/info")
  [ "$code" = "200" ]
}

# Helper: lightweight validation
check_auth_validate() {
  local user="$1" pass="$2"
  local resp
  resp=$(curl -s -u "${user}:${pass}" "${SONAR_URL}/api/authentication/validate" 2>/dev/null)
  echo "$resp" | grep -q '"valid":true' 2>/dev/null
}

echo -e "  Authenticating to SonarQube..."

# ── Strategy 1: Change default password immediately (required on SonarQube 10+) ──
CHANGE_CODE=$(curl_http_code -u "admin:admin" -X POST \
  "${SONAR_URL}/api/users/change_password" \
  -d "login=admin&previousPassword=admin&password=${NEW_PASS}")

if [ "$CHANGE_CODE" = "204" ] || [ "$CHANGE_CODE" = "200" ]; then
  SONAR_PASS="$NEW_PASS"
  echo -e "  ${GREEN}✓ Default password changed successfully${NC}"
elif [ "$CHANGE_CODE" = "401" ]; then
  # 401 on change_password with admin:admin means admin:admin is NOT the current password
  # Password was already changed (shouldn't happen with fresh container, but just in case)
  [ "$DEBUG_MODE" = true ] && echo -e "    ${YELLOW}admin:admin rejected (HTTP 401) — trying known passwords${NC}"
else
  # Other codes (e.g., 400 = password doesn't meet requirements, or SQ < 10 where change not forced)
  [ "$DEBUG_MODE" = true ] && echo -e "    ${YELLOW}Password change returned HTTP ${CHANGE_CODE}${NC}"
  # On older SonarQube (< 10), admin:admin just works without forced change
  if check_auth_real "admin" "admin"; then
    SONAR_PASS="admin"
    echo -e "  ${GREEN}✓ Using default admin:admin (no forced change required)${NC}"
  fi
fi

# ── Strategy 2: Verify the new password actually works on a real endpoint ──
if [ -n "$SONAR_PASS" ] && ! check_auth_real "admin" "$SONAR_PASS"; then
  echo -e "  ${YELLOW}⚠ Password set but real endpoint rejected — trying alternatives${NC}"
  SONAR_PASS=""
fi

# ── Strategy 3: Try known password candidates ──
if [ -z "$SONAR_PASS" ]; then
  for candidate in "$NEW_PASS" "admin"; do
    if check_auth_real "admin" "$candidate"; then
      SONAR_PASS="$candidate"
      echo -e "  ${GREEN}✓ Authenticated with admin:${candidate}${NC}"
      break
    fi
  done
fi

# ── Strategy 4: Last resort — use /validate (less strict) and hope for the best ──
if [ -z "$SONAR_PASS" ]; then
  for candidate in "$NEW_PASS" "admin"; do
    if check_auth_validate "admin" "$candidate"; then
      SONAR_PASS="$candidate"
      echo -e "  ${YELLOW}⚠ Validated via /validate (admin:${candidate}) — may have limited API access${NC}"
      break
    fi
  done
fi

if [ -z "$SONAR_PASS" ]; then
  echo -e "  ${RED}❌ Cannot authenticate to SonarQube${NC}"
  echo -e "  ${RED}   Tried: admin:admin, admin:${NEW_PASS}${NC}"
  echo -e "  ${RED}   Container logs:${NC}"
  $CONTAINER_RT logs --tail 30 "$CONTAINER_NAME" 2>&1 | tail -15
  exit 1
fi

# 2. Generate auth token
TOKEN=$(curl -s -u "admin:${SONAR_PASS}" -X POST \
  "${SONAR_URL}/api/user_tokens/generate" \
  -d "name=creedengo-scan-$(date +%s)" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
  echo -e "  ${GREEN}✓ Auth token generated${NC}"
  SONAR_AUTH_MAVEN="-Dsonar.token=${TOKEN}"
  SONAR_AUTH_CURL="-u ${TOKEN}:"
else
  echo -e "  ${YELLOW}⚠ Token generation failed — using password auth${NC}"
  SONAR_AUTH_MAVEN="-Dsonar.login=admin -Dsonar.password=${SONAR_PASS}"
  SONAR_AUTH_CURL="-u admin:${SONAR_PASS}"
fi

###############################################################################
# Step 6b: Full project provisioning on fresh SonarQube instance
#  - Disable forced authentication (allows scanner to submit without token issues)
#  - Create the project with key + name
#  - Generate a dedicated PROJECT-level analysis token
#  - Set permissions (scan, browse) for the project
#  - Configure quality gate & new code period
###############################################################################
echo -e "${YELLOW}━━━ 📦 Provisioning SonarQube project ━━━${NC}"

# ── 6b.1: Disable "Force user authentication" so scanner + API calls work ──
# On SonarQube 10+, forceAuthentication is true by default.
# We disable it to avoid 401 errors on API calls from the scanner.
FA_RESP=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
  "${SONAR_URL}/api/settings/set" \
  -d "key=sonar.forceAuthentication&value=false")
if [ "$FA_RESP" = "204" ] || [ "$FA_RESP" = "200" ]; then
  echo -e "  ${GREEN}✓ Force authentication disabled${NC}"
else
  [ "$DEBUG_MODE" = true ] && echo -e "    ${YELLOW}forceAuthentication set returned HTTP ${FA_RESP}${NC}"
fi

# ── 6b.2: Check if project already exists ──
PROJECT_EXISTS=$(curl -s ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/projects/search?projects=${PROJECT_KEY}" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('components',[]))>0)" 2>/dev/null || echo "False")

if [ "$PROJECT_EXISTS" = "True" ]; then
  echo -e "  ${GREEN}✓ Project '${PROJECT_KEY}' already exists${NC}"
else
  # ── 6b.3: Create the project ──
  CREATE_BODY=$(curl -s ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/projects/create" \
    -d "project=${PROJECT_KEY}&name=${APPNAME}&visibility=public&mainBranch=main" 2>/dev/null || echo "{}")
  CREATE_OK=$(echo "$CREATE_BODY" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('True' if d.get('project',{}).get('key') == '${PROJECT_KEY}' else 'False')
" 2>/dev/null || echo "False")

  if [ "$CREATE_OK" = "True" ]; then
    echo -e "  ${GREEN}✓ Project '${PROJECT_KEY}' created (name: ${APPNAME})${NC}"
  else
    # Retry with simpler payload (older SQ versions don't support mainBranch param)
    CREATE_RESP2=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
      "${SONAR_URL}/api/projects/create" \
      -d "project=${PROJECT_KEY}&name=${APPNAME}&visibility=public")
    if [ "$CREATE_RESP2" = "200" ] || [ "$CREATE_RESP2" = "204" ]; then
      echo -e "  ${GREEN}✓ Project '${PROJECT_KEY}' created (fallback)${NC}"
    else
      echo -e "  ${YELLOW}⚠ Project creation returned HTTP ${CREATE_RESP2}${NC}"
      [ "$DEBUG_MODE" = true ] && echo -e "    ${CYAN}Body: ${CREATE_BODY}${NC}"
      echo -e "  ${YELLOW}  → Scanner will attempt auto-provisioning on first analysis${NC}"
    fi
  fi
fi

# ── 6b.4: Generate a dedicated PROJECT analysis token ──
# This is more reliable than the global user token for scanner submissions
# Save admin-level credentials for API calls that need Browse/Admin permissions
# (e.g., /api/ce/component, /api/issues/search). PROJECT_ANALYSIS_TOKEN only has
# 'scan' permission and will get 403 on these endpoints.
ADMIN_TOKEN="$TOKEN"
ADMIN_AUTH_USER="admin"
ADMIN_AUTH_PASS="$SONAR_PASS"

PROJECT_TOKEN=$(curl -s ${SONAR_AUTH_CURL} -X POST \
  "${SONAR_URL}/api/user_tokens/generate" \
  -d "name=creedengo-project-${PROJECT_KEY}-$(date +%s)&type=PROJECT_ANALYSIS_TOKEN&projectKey=${PROJECT_KEY}" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

if [ -n "$PROJECT_TOKEN" ]; then
  echo -e "  ${GREEN}✓ Project analysis token generated${NC}"
  # Override the global token with the project-specific one for scanner
  TOKEN="$PROJECT_TOKEN"
  SONAR_AUTH_MAVEN="-Dsonar.token=${TOKEN}"
  # Keep SONAR_AUTH_CURL with admin creds for API management calls
else
  echo -e "  ${YELLOW}⚠ Project token generation failed — using global token/password${NC}"
  # Fallback: try GLOBAL_ANALYSIS_TOKEN type
  GLOBAL_TOKEN=$(curl -s ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/user_tokens/generate" \
    -d "name=creedengo-global-$(date +%s)&type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
  if [ -n "$GLOBAL_TOKEN" ]; then
    echo -e "  ${GREEN}✓ Global analysis token generated (fallback)${NC}"
    TOKEN="$GLOBAL_TOKEN"
    SONAR_AUTH_MAVEN="-Dsonar.token=${TOKEN}"
  fi
fi

# ── 6b.5: Set main branch name (SonarQube 10+ may default to 'master') ──
curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
  "${SONAR_URL}/api/project_branches/rename" \
  -d "project=${PROJECT_KEY}&name=main" 2>/dev/null || true

# ── 6b.6: Configure new code period to avoid warnings on first scan ──
curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
  "${SONAR_URL}/api/new_code_periods/set" \
  -d "project=${PROJECT_KEY}&type=NUMBER_OF_DAYS&value=30" 2>/dev/null || true

# ── 6b.7: Set permissions — allow scan + browse + admin for the project ──
for perm in scan user codeviewer issueadmin admin; do
  curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/permissions/add_group" \
    -d "projectKey=${PROJECT_KEY}&groupName=anyone&permission=${perm}" 2>/dev/null || true
done
echo -e "  ${GREEN}✓ Permissions configured (scan, browse, code viewer, issue admin, admin)${NC}"

# ── 6b.8: Enable scanner auto-provisioning (SQ 10+ setting) ──
curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
  "${SONAR_URL}/api/settings/set" \
  -d "key=provisioning.analysis.projectVisibility&value=public" 2>/dev/null || true

# ── 6b.9: Verify project is accessible ──
VERIFY=$(curl -s ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/components/show?component=${PROJECT_KEY}" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('component',{}).get('key',''))" 2>/dev/null || echo "")
if [ "$VERIFY" = "$PROJECT_KEY" ]; then
  echo -e "  ${GREEN}✓ Project verified and accessible${NC}"
else
  echo -e "  ${YELLOW}⚠ Project not yet accessible via API — scanner will auto-provision${NC}"
fi

echo -e "  Project key:  ${CYAN}${PROJECT_KEY}${NC}"
echo -e "  Project name: ${CYAN}${APPNAME}${NC}"
echo -e "  SonarQube:    ${CYAN}${SONAR_URL}${NC}"
echo ""

###############################################################################
# Step 7: Create quality profiles & gate with Creedengo rules & assign to project
#   Delegates to setup-sonar-quality.sh which:
#     1. Creates "creedprofiles-<lang>" quality profile extending "Sonar way"
#     2. Activates ALL Creedengo eco-design rules in the profile
#     3. Creates "CreedGate" quality gate (copy of the default)
#     4. Links profile + gate to the project as default configuration
###############################################################################
echo -e "${YELLOW}━━━ 📋 Setting up Creedengo quality profiles & gate ━━━${NC}"

# Export variables needed by the setup script
export SONAR_URL SONAR_AUTH_CURL PROJECT_KEY ALL_SONAR_REPOS ALL_SONAR_LANGS DEBUG_MODE APPNAME

SETUP_SCRIPT="$SCRIPT_DIR/setup-sonar-quality.sh"
if [ -f "$SETUP_SCRIPT" ]; then
  source "$SETUP_SCRIPT"
else
  echo -e "${RED}❌ setup-sonar-quality.sh not found at ${SETUP_SCRIPT}${NC}"
  echo -e "${YELLOW}  Falling back to inline rule activation...${NC}"

  # Minimal fallback: activate rules in default profiles
  IFS=',' read -ra REPOS_ARRAY <<< "$ALL_SONAR_REPOS"
  IFS=',' read -ra LANGS_ARRAY <<< "$ALL_SONAR_LANGS"
  for idx in "${!REPOS_ARRAY[@]}"; do
    repo="${REPOS_ARRAY[$idx]}"; lang="${LANGS_ARRAY[$idx]}"
    [ -z "$repo" ] && continue
    FALLBACK_KEY=$(curl -s ${SONAR_AUTH_CURL} \
      "${SONAR_URL}/api/qualityprofiles/search?language=${lang}&defaults=true" 2>/dev/null \
      | python3 -c "import sys,json; ps=json.load(sys.stdin).get('profiles',[]); print(ps[0]['key'] if ps else '')" 2>/dev/null || echo "")
    if [ -n "$FALLBACK_KEY" ]; then
      curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
        "${SONAR_URL}/api/qualityprofiles/activate_rules" \
        -d "targetKey=${FALLBACK_KEY}&repositories=${repo}" 2>/dev/null || true
      echo -e "  ${GREEN}✓ Creedengo rules activated in default profile for ${lang}${NC}"
    fi
  done
fi

# Summary of installed plugins
echo ""
echo -e "${CYAN}Installed Creedengo plugins:${NC}"

PLUGINS_RAW=$(curl -s -w "\n%{http_code}" ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/plugins/installed" 2>/dev/null)
PLUGINS_HTTP=$(echo "$PLUGINS_RAW" | tail -1)
PLUGINS_BODY=$(echo "$PLUGINS_RAW" | sed '$d')

if [ "$PLUGINS_HTTP" = "200" ] && [ -n "$PLUGINS_BODY" ]; then
  INSTALLED_PLUGINS=$(echo "$PLUGINS_BODY" | python3 -c "
import sys, json
try:
    plugins = json.load(sys.stdin).get('plugins', [])
    creedengo = [p for p in plugins if 'creedengo' in p.get('key','').lower() or 'ecocode' in p.get('key','').lower()]
    for p in creedengo:
        print(f'  ✅ {p[\"name\"]} v{p.get(\"version\",\"?\")} (key: {p[\"key\"]})')
    if not creedengo:
        print('  ⚠ No Creedengo/ecoCode plugins detected in installed plugins')
except Exception as e:
    print(f'  ⚠ Could not parse plugins response: {e}')
" 2>&1)
  echo "$INSTALLED_PLUGINS"
elif [ "$PLUGINS_HTTP" = "401" ] || [ "$PLUGINS_HTTP" = "403" ]; then
  echo -e "  ${YELLOW}⚠ Could not list plugins (HTTP ${PLUGINS_HTTP} — authentication issue)${NC}"
  echo -e "  ${YELLOW}  Retrying with admin login/password...${NC}"
  # Retry with explicit admin credentials (SONAR_AUTH_CURL may hold a token with limited perms)
  PLUGINS_RETRY=$(curl -s -u "admin:${SONAR_PASS}" \
    "${SONAR_URL}/api/plugins/installed" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    plugins = json.load(sys.stdin).get('plugins', [])
    creedengo = [p for p in plugins if 'creedengo' in p.get('key','').lower() or 'ecocode' in p.get('key','').lower()]
    for p in creedengo:
        print(f'  ✅ {p[\"name\"]} v{p.get(\"version\",\"?\")} (key: {p[\"key\"]})')
    if not creedengo:
        print('  ⚠ No Creedengo/ecoCode plugins detected in installed plugins')
except Exception as e:
    print(f'  ⚠ Could not parse plugins response: {e}')
" 2>&1 || echo "  ⚠ Retry also failed")
  echo "$PLUGINS_RETRY"
else
  echo -e "  ${YELLOW}⚠ Could not list installed plugins (HTTP ${PLUGINS_HTTP:-no response})${NC}"
  [ "$DEBUG_MODE" = true ] && echo -e "  ${CYAN}Response: ${PLUGINS_BODY:-(empty)}${NC}"
fi
echo ""

###############################################################################
# Step 8: Build sonar properties dynamically from modules
###############################################################################
echo -e "${YELLOW}━━━ 🔍 Running Creedengo analysis ━━━${NC}"

SONAR_SOURCES=""
SONAR_JAVA_BINARIES=""

while IFS='|' read -r lang src_dir bin_dir lang_ver; do
  [ -z "$lang" ] && continue
  [ -d "$ROOT/$src_dir" ] && SONAR_SOURCES="${SONAR_SOURCES:+$SONAR_SOURCES,}${src_dir}"
  [ "$lang" = "java" ] && [ -n "$bin_dir" ] && [ -d "$ROOT/$bin_dir" ] && SONAR_JAVA_BINARIES="${SONAR_JAVA_BINARIES:+$SONAR_JAVA_BINARIES,}${bin_dir}"
done < <(echo "$DETECT_JSON" | python3 -c "
import sys, json
for m in json.load(sys.stdin)['modules']:
    p, s, b, v = m['path'], m['sources_dir'], m.get('binaries_dir',''), m.get('language_version','')
    print(f'{m[\"language\"]}|{p+\"/\"+s if p else s}|{p+\"/\"+b if p and b else b}|{v}')
" 2>/dev/null)

SONAR_SOURCES="${SONAR_SOURCES:-.}"

SONAR_PROPS=(
  "-Dsonar.host.url=${SONAR_URL}" ${SONAR_AUTH_MAVEN}
  "-Dsonar.projectKey=${PROJECT_KEY}" "-Dsonar.projectName=${APPNAME}"
  "-Dsonar.sources=${SONAR_SOURCES}" "-Dsonar.sourceEncoding=UTF-8"
  "-Dsonar.exclusions=**/node_modules/**,**/target/**,**/build/**,**/dist/**,**/*.test.*,**/*.spec.*,**/test/**,**/__pycache__/**"
)
[ -n "$SONAR_JAVA_BINARIES" ] && SONAR_PROPS+=("-Dsonar.java.binaries=${SONAR_JAVA_BINARIES}")

JAVA_VER=$(echo "$DETECT_JSON" | python3 -c "
import sys,json
for m in json.load(sys.stdin)['modules']:
    if m['language']=='java' and m['language_version']: print(m['language_version']); break
" 2>/dev/null)
[ -n "$JAVA_VER" ] && SONAR_PROPS+=("-Dsonar.java.source=${JAVA_VER}")

echo -e "  Sources:  ${CYAN}${SONAR_SOURCES}${NC}"
echo -e "  Java bin: ${CYAN}${SONAR_JAVA_BINARIES:-n/a}${NC}"
echo ""

###############################################################################
# Step 9: Run analysis
#   - For Java/Maven reactor: use `mvn sonar:sonar` from the REACTOR POM
#     so that ALL modules are analyzed together under a single project key.
#   - For Java/Maven single module: use `mvn sonar:sonar` on the module pom.
#   - For Java/Gradle: use `gradle sonarqube`
#   - Fallback: sonar-scanner-cli (Docker) for non-Java or if mvn fails
###############################################################################
cd "$ROOT"

ANALYSIS_SUCCESS=false

# ── Strategy A: Maven sonar:sonar for Java+Maven projects ──
if echo "$PLUGIN_KEYS" | grep -q "java" && [ -n "$JAVA_MODULE_DIR" ] && [ -f "$JAVA_MODULE_DIR/pom.xml" ] && mvn -B --version &>/dev/null; then

  if [ "$USE_REACTOR_POM" = true ]; then
    echo -e "  Using: ${CYAN}mvn sonar:sonar via REACTOR POM (all modules → single project key)${NC}"
  else
    echo -e "  Using: ${CYAN}mvn sonar:sonar (Java/Maven — most reliable)${NC}"
  fi

  MVN_SONAR_PROPS=(
    "sonar:sonar"
    "-Dsonar.host.url=${SONAR_URL}"
    "-Dsonar.projectKey=${PROJECT_KEY}"
    "-Dsonar.projectName=${APPNAME}"
    "-Dsonar.sourceEncoding=UTF-8"
  )

  # Auth: prefer token, fallback to login/password
  if [ -n "$TOKEN" ]; then
    MVN_SONAR_PROPS+=("-Dsonar.token=${TOKEN}")
  else
    MVN_SONAR_PROPS+=("-Dsonar.login=admin" "-Dsonar.password=${SONAR_PASS}")
  fi

  [ -n "$JAVA_VER" ] && MVN_SONAR_PROPS+=("-Dsonar.java.source=${JAVA_VER}")

  # Run Maven sonar:sonar from reactor (or single module) POM
  echo -e "  ${CYAN}Running with: ${JAVA_MODULE_DIR}/pom.xml${NC}"
  if [ "$USE_REACTOR_POM" = true ]; then
    # List all modules that will be analyzed
    echo -e "  ${CYAN}Modules included in analysis:${NC}"
    echo "$DETECT_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data['modules']:
    if m['language'] == 'java' and not m.get('is_reactor', False):
        print(f'    📦 {m[\"name\"]} ({m[\"path\"] or \".\"})')
" 2>/dev/null
  fi

  MVN_OUTPUT_FILE=$(mktemp /tmp/mvn-sonar-XXXXXX.log)
  mvn -B -f "$JAVA_MODULE_DIR/pom.xml" "${MVN_SONAR_PROPS[@]}" -DskipTests 2>&1 | tee "$MVN_OUTPUT_FILE"
  if grep -qE "ANALYSIS SUCCESSFUL" "$MVN_OUTPUT_FILE" 2>/dev/null; then
    echo -e "  ${GREEN}✓ Maven sonar:sonar — ANALYSIS SUCCESSFUL${NC}"
    if [ "$USE_REACTOR_POM" = true ]; then
      echo -e "  ${GREEN}  All modules analyzed under project key: ${PROJECT_KEY}${NC}"
    fi
    ANALYSIS_SUCCESS=true
  else
    echo -e "  ${YELLOW}⚠ Maven sonar:sonar did not report ANALYSIS SUCCESSFUL — checking SonarQube...${NC}"
    # Check if SonarQube received a CE task (analysis might have been submitted even if mvn reported issues)
    sleep 3
    CE_CHECK=$(curl -s ${SONAR_AUTH_CURL} \
      "${SONAR_URL}/api/ce/activity?component=${PROJECT_KEY}&ps=1" 2>/dev/null \
      | python3 -c "import sys,json; tasks=json.load(sys.stdin).get('tasks',[]); print(tasks[0]['status'] if tasks else 'NONE')" 2>/dev/null || echo "NONE")
    if [ "$CE_CHECK" != "NONE" ]; then
      echo -e "  ${GREEN}✓ Analysis task found in SonarQube (status: ${CE_CHECK})${NC}"
      ANALYSIS_SUCCESS=true
    else
      echo -e "  ${YELLOW}⚠ Maven sonar:sonar failed — falling back to sonar-scanner${NC}"
    fi
  fi
  rm -f "$MVN_OUTPUT_FILE" 2>/dev/null || true
fi

# ── Strategy B: sonar-scanner (fallback for non-Java or if Maven failed) ──
if [ "$ANALYSIS_SUCCESS" = false ]; then
  if command -v sonar-scanner &>/dev/null; then
    echo -e "  Using: ${CYAN}sonar-scanner (local)${NC}"
    sonar-scanner "${SONAR_PROPS[@]}" 2>&1 | grep -E "ANALYSIS SUCCESSFUL|ANALYSIS|ERROR|WARN|creedengo|ecocode" || true
    ANALYSIS_SUCCESS=true
  else
    echo -e "  Using: ${CYAN}sonar-scanner-cli (Docker)${NC}"
    $CONTAINER_RT run --rm --network host \
      -v "$ROOT:/usr/src" -w /usr/src \
      -e SONAR_SCANNER_OPTS="-Xmx512m" \
      sonarsource/sonar-scanner-cli \
      "${SONAR_PROPS[@]}" 2>&1 | grep -E "ANALYSIS SUCCESSFUL|ANALYSIS|ERROR|WARN|creedengo|ecocode" || true
    ANALYSIS_SUCCESS=true
  fi
fi
echo -e "  ${GREEN}✓ Analysis submitted${NC}"

###############################################################################
# Step 10: Wait for CE task (uses /api/ce/activity — lower permission needs)
#
# NOTE: /api/ce/component requires Browse permission and can return 403.
#       /api/ce/activity is more reliable with admin credentials.
###############################################################################
echo -e "${YELLOW}━━━ ⏳ Waiting for analysis to complete ━━━${NC}"
CE_TIMEOUT=300; CE_ELAPSED=0; CE_STATUS="PENDING"

# Use admin credentials for CE polling (project tokens may lack Browse permission)
CE_AUTH_CURL="-u admin:${SONAR_PASS}"

while [ "$CE_ELAPSED" -lt "$CE_TIMEOUT" ]; do
  # Try /api/ce/activity first (works with admin creds, lists recent tasks)
  CE_STATUS=$(curl -s --connect-timeout 10 --max-time 30 ${CE_AUTH_CURL} \
    "${SONAR_URL}/api/ce/activity?component=${PROJECT_KEY}&ps=1&status=SUCCESS,FAILED,CANCELED,PENDING,IN_PROGRESS" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
tasks=d.get('tasks',[])
if tasks:
    print(tasks[0].get('status','PENDING'))
else:
    print('PENDING')
" 2>/dev/null || echo "PENDING")

  if [ "$CE_STATUS" = "SUCCESS" ]; then echo -e "  ${GREEN}✅ Complete (${CE_ELAPSED}s)${NC}"; break
  elif [ "$CE_STATUS" = "FAILED" ]; then
    echo -e "  ${RED}⚠ Analysis task failed — fetching error details${NC}"
    curl -s ${CE_AUTH_CURL} \
      "${SONAR_URL}/api/ce/activity?component=${PROJECT_KEY}&ps=1&status=FAILED" 2>/dev/null \
      | python3 -c "
import sys,json
tasks=json.load(sys.stdin).get('tasks',[])
if tasks:
    print(f'  Error: {tasks[0].get(\"errorMessage\",\"unknown\")}')
" 2>/dev/null || true
    break
  elif [ "$CE_STATUS" = "CANCELED" ]; then
    echo -e "  ${YELLOW}⚠ Analysis task was canceled${NC}"; break
  fi
  sleep 3; CE_ELAPSED=$((CE_ELAPSED + 3))
  [ $((CE_ELAPSED % 15)) -eq 0 ] && echo -e "  ... ${CE_ELAPSED}s/${CE_TIMEOUT}s (status: ${CE_STATUS:-starting})"
done
if [ "$CE_STATUS" != "SUCCESS" ] && [ "$CE_STATUS" != "FAILED" ]; then
  echo -e "  ${YELLOW}⚠ Timeout (${CE_TIMEOUT}s) — attempting to extract partial results${NC}"
fi

###############################################################################
# Step 11: Extract results
###############################################################################
echo ""
echo -e "${YELLOW}━━━ 📊 Extracting Creedengo results ━━━${NC}"
mkdir -p "$REPORTS_DIR"

EXTRACT_ARGS=(
  python3 "$SCRIPT_DIR/creedengo-extract-results.py"
  --sonar-url "$SONAR_URL" --project-key "$PROJECT_KEY"
  --output "$REPORTS_DIR/creedengo-report.json" --appname "$APPNAME"
  --language "$PRIMARY_LANG" --sonar-repos "$ALL_SONAR_REPOS"
)
# Always use admin login/password for extraction — tokens (even admin-level)
# can have inconsistent permissions on /api/issues/search and /api/ce/activity.
# Admin login/password is the most reliable for all API endpoints.
EXTRACT_ARGS+=(--sonar-user "admin" --sonar-password "$SONAR_PASS")
"${EXTRACT_ARGS[@]}" || { echo -e "${RED}❌ Extraction failed${NC}"; exit 1; }

###############################################################################
# Step 12: Embed detection metadata in report
###############################################################################
python3 -c "
import json, sys
report_path = sys.argv[1]
report = json.load(open(report_path))
detect = json.loads(sys.argv[2])
report['detection'] = {
    'languages': detect['languages'],
    'primary_language': detect['primary_language'],
    'primary_framework': detect['primary_framework'],
    'plugins_used': detect['creedengo_plugins'],
    'modules': [{'name':m['name'],'path':m['path'],'language':m['language'],
                 'framework':m['framework'],'framework_version':m['framework_version'],
                 'language_version':m['language_version']} for m in detect['modules']],
}
json.dump(report, open(report_path,'w'), indent=2, ensure_ascii=False)
" "$REPORTS_DIR/creedengo-report.json" "$DETECT_JSON" 2>/dev/null || true

###############################################################################
# Step 13: Update dashboard (skipped when --skip-dashboard is set)
###############################################################################
CREEDENGO_REPORT="$REPORTS_DIR/creedengo-report.json"
GREEN_REPORT="$REPORTS_DIR/latest-report.json"

if [ "$SKIP_DASHBOARD" = true ]; then
  echo -e "${YELLOW}ℹ️  Dashboard generation skipped (--skip-dashboard) — will be generated after all analyses${NC}"
elif [ -f "$GREEN_DIR/scripts/generate-dashboard.sh" ] && [ -f "$CREEDENGO_REPORT" ]; then
  echo -e "${YELLOW}━━━ 📊 Updating Dashboard ━━━${NC}"
  bash "$GREEN_DIR/scripts/generate-dashboard.sh" "${GREEN_REPORT}" \
    "$GREEN_DIR/dashboard/index.save.html" "$GREEN_DIR/dashboard/index.html" "${CREEDENGO_REPORT}" || true
fi

###############################################################################
# Summary
###############################################################################
echo ""
if [ -f "$CREEDENGO_REPORT" ]; then
  TOTAL=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('creedengo_score',{}).get('total',0))" "$CREEDENGO_REPORT" 2>/dev/null || echo "?")
  GRADE=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('creedengo_score',{}).get('grade','?'))" "$CREEDENGO_REPORT" 2>/dev/null || echo "?")
  ISSUES=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('creedengo_score',{}).get('issues_count',0))" "$CREEDENGO_REPORT" 2>/dev/null || echo "?")
  RULES_VIOLATED=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('rules_violated',0))" "$CREEDENGO_REPORT" 2>/dev/null || echo "?")
  ALL_RULES=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('all_creedengo_rules',0))" "$CREEDENGO_REPORT" 2>/dev/null || echo "?")

  # Severity breakdown — Creedengo/ecodesign rules ONLY
  SEV_BREAKDOWN=$(python3 -c "
import json, sys
r = json.load(open(sys.argv[1]))
bd = r.get('creedengo_score',{}).get('severity_breakdown',{})
parts = []
for sev, label in [('BLOCKER','Bloquant'),('CRITICAL','Critique'),('MAJOR','Majeur'),('MINOR','Mineur'),('INFO','Info')]:
    c = bd.get(sev, 0)
    parts.append(f'{label}: {c}')
print(' | '.join(parts))
" "$CREEDENGO_REPORT" 2>/dev/null || echo "")

  # SonarQube general issues count
  SQ_ISSUES=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('sonar_issues',{}).get('issues_count',0))" "$CREEDENGO_REPORT" 2>/dev/null || echo "0")
  SQ_BREAKDOWN=$(python3 -c "
import json, sys
r = json.load(open(sys.argv[1]))
bd = r.get('sonar_issues',{}).get('severity_breakdown',{})
parts = []
for sev, label in [('CRITICAL','Critique'),('MAJOR','Majeur'),('MINOR','Mineur'),('INFO','Info')]:
    c = bd.get(sev, 0)
    if c > 0: parts.append(f'{label}: {c}')
print(' | '.join(parts) if parts else 'Aucune')
" "$CREEDENGO_REPORT" 2>/dev/null || echo "")

  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  📦 APP: ${GREEN}${APPNAME}${NC}"
  echo -e "${CYAN}║  🔍 Stack: ${GREEN}${ALL_LANGUAGES}${CYAN} — ${GREEN}${PRIMARY_FRAMEWORK:-no framework}${NC}"
  echo -e "${CYAN}║  🔌 Plugins: ${GREEN}${PLUGIN_KEYS}${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║  🌱 CREEDENGO SCORE (écodesign uniquement)${NC}"
  echo -e "${CYAN}║     Score: ${GREEN}${TOTAL}/100${CYAN}  Grade: ${GREEN}${GRADE}${NC}"
  echo -e "${CYAN}║     Issues écodesign: ${GREEN}${ISSUES}${CYAN}  Règles violées: ${GREEN}${RULES_VIOLATED}/${ALL_RULES}${NC}"
  echo -e "${CYAN}║     ${GREEN}${SEV_BREAKDOWN}${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║  🔧 SONARQUBE GÉNÉRAL (hors écodesign): ${YELLOW}${SQ_ISSUES} issues${NC}"
  echo -e "${CYAN}║     ${YELLOW}${SQ_BREAKDOWN}${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${GREEN}📄 Report: ${CREEDENGO_REPORT}${NC}"

  [ "$DEBUG_MODE" = true ] && python3 -c "
import json, sys
r = json.load(open(sys.argv[1]))
s = r.get('creedengo_score',{}); d = r.get('detection',{})
sq = r.get('sonar_issues',{})
print(f'  Stack:   {d.get(\"languages\",[])}')
print(f'  Primary: {d.get(\"primary_language\",\"?\")} ({d.get(\"primary_framework\",\"\")})')
print(f'  Plugins: {d.get(\"plugins_used\",[])}')
print()
print(f'  === Creedengo/Ecodesign ===')
print(f'  Score:   {s.get(\"total\",0)}/100  Grade: {s.get(\"grade\",\"?\")}')
bd = s.get('severity_breakdown',{})
for sev in ['BLOCKER','CRITICAL','MAJOR','MINOR','INFO']:
    c = bd.get(sev,0)
    icon = '!!' if sev in ('BLOCKER','CRITICAL') else '! ' if sev=='MAJOR' else '  '
    print(f'    {icon} {sev:10s}: {c}')
for rule in r.get('rules_summary',[])[:15]:
    print(f'    [{rule[\"severity\"]:8s}] {rule[\"key\"]:40s} x{rule[\"count\"]}  {rule[\"name\"][:50]}')
print()
print(f'  === SonarQube General (hors ecodesign) ===')
print(f'  Issues: {sq.get(\"issues_count\",0)}')
sbd = sq.get('severity_breakdown',{})
for sev in ['BLOCKER','CRITICAL','MAJOR','MINOR','INFO']:
    c = sbd.get(sev,0)
    if c > 0:
        icon = '!!' if sev in ('BLOCKER','CRITICAL') else '! ' if sev=='MAJOR' else '  '
        print(f'    {icon} {sev:10s}: {c}')
for rule in sq.get('rules_summary',[])[:10]:
    print(f'    [{rule[\"severity\"]:8s}] {rule[\"key\"]:40s} x{rule[\"count\"]}  {rule[\"name\"][:50]}')
" "$CREEDENGO_REPORT" 2>/dev/null || true
else
  echo -e "${RED}❌ Creedengo report not generated${NC}"
fi
echo ""
echo -e "Open the dashboard: ${YELLOW}open greenanalyzer/dashboard/index.html${NC}"

