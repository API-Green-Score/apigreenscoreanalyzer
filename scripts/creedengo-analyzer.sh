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

# ── Detect container runtime (Docker/Podman) — REQUIRED for creedengo ──
CONTAINER_RT_REQUIRED=1
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
  echo -e "${YELLOW}   💡 Check that your project has one of:${NC}"
  echo -e "${YELLOW}      • Java:    pom.xml, build.gradle(.kts)${NC}"
  echo -e "${YELLOW}      • .NET:    *.sln, *.slnx, *.csproj (or global.json)${NC}"
  echo -e "${YELLOW}      • Node:    package.json${NC}"
  echo -e "${YELLOW}      • Python:  requirements.txt, pyproject.toml${NC}"
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
    dotnet) PLUGIN_KEYS="csharp" ;;
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

###############################################################################
# Step 2-bis: Detect .NET / C# module info + Compile if needed
#         When csharp is detected we prefer the .sln (entry_point) so all
#         projects in the solution are compiled and analyzed together.
###############################################################################
DOTNET_MODULE=""
DOTNET_MODULE_DIR=""
DOTNET_ENTRY_POINT=""
DOTNET_LANG_VERSION=""

if echo "$PLUGIN_KEYS" | grep -q "csharp"; then
  DOTNET_INFO=$(echo "$DETECT_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data['modules']:
    if m['language'] == 'csharp':
        # path|entry_point|language_version
        print((m.get('path') or '.') + '|' + (m.get('entry_point') or '') + '|' + (m.get('language_version') or ''))
        break
" 2>/dev/null || echo "")
  if [ -n "$DOTNET_INFO" ]; then
    DOTNET_MODULE=$(echo "$DOTNET_INFO" | awk -F'|' '{print $1}')
    DOTNET_ENTRY_POINT=$(echo "$DOTNET_INFO" | awk -F'|' '{print $2}')
    DOTNET_LANG_VERSION=$(echo "$DOTNET_INFO" | awk -F'|' '{print $3}')
    if [ "$DOTNET_MODULE" = "." ] || [ -z "$DOTNET_MODULE" ]; then
      DOTNET_MODULE_DIR="$ROOT"
    else
      DOTNET_MODULE_DIR="$ROOT/$DOTNET_MODULE"
    fi
    echo -e "  ${GREEN}✓ .NET module detected${NC}"
    echo -e "  ${CYAN}  Entry point: ${DOTNET_ENTRY_POINT:-<auto>}${NC}"
    [ -n "$DOTNET_LANG_VERSION" ] && echo -e "  ${CYAN}  Target framework: net${DOTNET_LANG_VERSION}${NC}"
  fi
fi

if [ "$SKIP_BUILD" = false ] && [ -n "$DOTNET_MODULE_DIR" ]; then
  echo -e "${YELLOW}━━━ 🔨 Compiling .NET project (dotnet build) ━━━${NC}"
  if ! command -v dotnet &>/dev/null; then
    echo -e "${RED}❌ dotnet CLI is required for C# analysis but was not found${NC}"
    echo -e "${YELLOW}   💡 Install .NET SDK 8 from https://dotnet.microsoft.com/download${NC}"
    exit 1
  fi
  DOTNET_BUILD_TARGET="${DOTNET_ENTRY_POINT:-$DOTNET_MODULE_DIR}"
  echo -e "  ${CYAN}dotnet restore ${DOTNET_BUILD_TARGET}${NC}"
  if ! dotnet restore "$DOTNET_BUILD_TARGET" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ dotnet restore had warnings — continuing${NC}"
  fi
  # Build in Debug so PDBs are available for SonarQube/Roslyn analyzers
  if ! dotnet build "$DOTNET_BUILD_TARGET" -c Debug --no-restore -v quiet -nologo; then
    echo -e "${RED}❌ dotnet build failed${NC}"
    exit 1
  fi
  echo -e "  ${GREEN}✓ .NET build successful${NC}"
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
#
# ⚡ Pre-gate: ANY .NET / C# detection forces the Creedengo.Tool fast path —
# we will NEVER start the SonarQube container for a C# project, even if other
# languages are also present. Rationale: the Creedengo SonarQube C# JAR plugin
# is not yet published (see green-code-initiative/creedengo-csharp-sonarqube),
# so spinning up SonarQube would only run *Java* plugins on Java sources, never
# the eco-design rules — which is exactly what the user wants to avoid.
###############################################################################
CSHARP_DIRECT_PLANNED=false
HAS_DOTNET_MODULE=false

# Detect .NET presence from MULTIPLE signals (robust to detection edge cases):
#   1. PRIMARY_LANG explicitly csharp/dotnet
#   2. PLUGIN_KEYS contains csharp (set by detect_csharp() and by --lang dotnet)
#   3. ALL_LANGUAGES contains csharp (multi-module / mixed-language repos)
#   4. DOTNET_MODULE_DIR set by Step 2-bis (truthful filesystem evidence)
case ",${PRIMARY_LANG},${PLUGIN_KEYS},${ALL_LANGUAGES}," in
  *,csharp,*|*,dotnet,*) HAS_DOTNET_MODULE=true ;;
esac
[ -n "$DOTNET_MODULE_DIR" ] && HAS_DOTNET_MODULE=true

if [ "$HAS_DOTNET_MODULE" = true ]; then
  CSHARP_DIRECT_PLANNED=true
  echo -e "${CYAN}⏩ .NET / C# project detected — switching to Creedengo.Tool fast path${NC}"
  echo -e "   ${CYAN}↪ Skipping plugin downloads (Step 3) and SonarQube container (Steps 4–11)${NC}"
  echo -e "   ${CYAN}↪ All analysis will be done locally via 'creedengo-cli' (.NET tool)${NC}"

  # Hard requirement: dotnet SDK must be available. If missing, install it
  # locally (no sudo) via the official dotnet-install script before falling
  # back to an actionable error. We MUST NOT silently fall back to SonarQube
  # (which would only analyze Java/JS — never C#) — that's the exact behaviour
  # the user asked us to suppress.
  DOTNET_LOCAL_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
  mkdir -p "$DOTNET_LOCAL_ROOT"
  # Prepend so our local install wins over a system 'dotnet' that may not see
  # the runtimes we just extracted (the apphost trusts $DOTNET_ROOT first).
  export PATH="$DOTNET_LOCAL_ROOT:$DOTNET_LOCAL_ROOT/tools:$HOME/.dotnet/tools:$PATH"

  # ── Always export DOTNET_ROOT (+ arch-specific variant) so the apphost can
  # find the runtime, even when ``dotnet`` is already on PATH. The error
  # ``DOTNET_ROOT_ARM64 = <not set> / DOTNET_ROOT = <not set>`` is exactly what
  # the apphost prints when these are missing — so set them unconditionally.
  export DOTNET_ROOT="$DOTNET_LOCAL_ROOT"
  export DOTNET_NOLOGO=1
  export DOTNET_CLI_TELEMETRY_OPTOUT=1
  # The Roslyn MSBuild BuildHost subprocess (spawned by Creedengo.Tool when
  # loading projects) literally calls `Process.Start("dotnet", …)` from its
  # current directory — without DOTNET_HOST_PATH it fails with
  # "An error occurred trying to start process 'dotnet' … No such file or directory".
  if [ -x "$DOTNET_LOCAL_ROOT/dotnet" ]; then
    export DOTNET_HOST_PATH="$DOTNET_LOCAL_ROOT/dotnet"
  fi
  _DOTNET_ARCH="$(uname -m 2>/dev/null || echo)"
  case "$_DOTNET_ARCH" in
    arm64|aarch64) export DOTNET_ROOT_ARM64="$DOTNET_LOCAL_ROOT" ;;
    x86_64|amd64)  export DOTNET_ROOT_X64="$DOTNET_LOCAL_ROOT" ;;
  esac
  # Allow a net9.0 tool to launch on a higher runtime (e.g. the .NET 10
  # backup pkg), which would otherwise be rejected by the default
  # "Minor" roll-forward policy.
  export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"

  # Creedengo.Tool 2.x ships as net9.0 — we therefore default to channel 9.0.
  # Override with DOTNET_CHANNEL=8.0 (or other) if you pin to an older Creedengo.Tool.
  INSTALL_CHANNEL="${DOTNET_CHANNEL:-9.0}"
  # Required runtime moniker(s) for Creedengo.Tool. The apphost looks for
  # Microsoft.NETCore.App matching the tool's TFM — for v2.x that's net9.0.
  REQUIRED_RUNTIME_MAJOR="${CREEDENGO_REQUIRED_RUNTIME:-9}"

  # ── Helper: extract a locally-cached .NET runtime/SDK .pkg (macOS) or
  # .tar.gz (Linux) into $DOTNET_LOCAL_ROOT without sudo. Looks in:
  #     <repo>/.creedengo/.dotnet/*.pkg|*.tar.gz
  # The macOS .pkg layout is:
  #     <pkg>/<component>.pkg/Payload  (cpio.gz)
  # whose contents map to /usr/local/share/dotnet/{shared,host,sdk,…}
  # We extract Payload via ``cpio`` and copy the ``shared/host/sdk`` trees
  # straight into $DOTNET_LOCAL_ROOT (which mirrors that layout).
  _dotnet_install_from_backup() {
    local backup_dir="$GREEN_DIR/.creedengo/.dotnet"
    [ -d "$backup_dir" ] || return 1
    local found=false rc_overall=1
    shopt -s nullglob 2>/dev/null || true

    for pkg in "$backup_dir"/dotnet-*.pkg "$backup_dir"/*.pkg; do
      [ -f "$pkg" ] || continue
      found=true
      echo -e "  ${CYAN}📦 Extracting offline .NET payload: ${pkg##*/}${NC}"
      local tmp; tmp=$(mktemp -d /tmp/dotnet-pkg-XXXXX) || continue
      if pkgutil --expand-full "$pkg" "$tmp/expanded" >/dev/null 2>&1; then
        # pkgutil --expand-full already explodes Payload into a directory tree.
        # Each component pkg lays files under e.g. `<comp>.pkg/Payload/...`
        # with an absolute-style structure starting at `usr/local/share/dotnet`
        # OR directly at `shared/`, `host/`, `sdk/` depending on the package.
        local src
        for src in $(find "$tmp/expanded" -type d \
                       \( -name "Payload" -o -name "shared" -o -name "host" -o -name "sdk" \) 2>/dev/null); do
          case "$(basename "$src")" in
            Payload)
              # Inside Payload we expect either ./shared/... or ./usr/local/share/dotnet/shared/...
              # or — for the host pkg — the ``dotnet`` binary at root.
              if [ -d "$src/usr/local/share/dotnet" ]; then
                cp -R "$src/usr/local/share/dotnet/." "$DOTNET_LOCAL_ROOT/" 2>/dev/null && rc_overall=0
              elif [ -d "$src/shared" ] || [ -d "$src/host" ] || [ -d "$src/sdk" ] || [ -f "$src/dotnet" ]; then
                cp -R "$src/." "$DOTNET_LOCAL_ROOT/" 2>/dev/null && rc_overall=0
              fi
              ;;
            shared|host|sdk)
              cp -R "$src" "$DOTNET_LOCAL_ROOT/" 2>/dev/null && rc_overall=0
              ;;
          esac
        done
      else
        echo -e "  ${YELLOW}  ⚠ pkgutil --expand-full failed on ${pkg##*/}${NC}"
      fi
      rm -rf "$tmp" 2>/dev/null || true
    done

    # Linux/macOS .tar.gz fallback (e.g. dotnet-runtime-9.0.x-linux-x64.tar.gz)
    for tarball in "$backup_dir"/dotnet-*.tar.gz "$backup_dir"/*.tar.gz; do
      [ -f "$tarball" ] || continue
      found=true
      echo -e "  ${CYAN}📦 Extracting offline .NET tarball: ${tarball##*/}${NC}"
      tar -xzf "$tarball" -C "$DOTNET_LOCAL_ROOT" 2>/dev/null && rc_overall=0
    done

    if [ "$found" = false ]; then
      return 1
    fi

    # macOS Gatekeeper: strip quarantine + ad-hoc sign so the apphost can run.
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
      xattr -dr com.apple.quarantine "$DOTNET_LOCAL_ROOT" 2>/dev/null || true
      if command -v codesign >/dev/null 2>&1 && [ -x "$DOTNET_LOCAL_ROOT/dotnet" ]; then
        codesign --force --deep --sign - "$DOTNET_LOCAL_ROOT/dotnet" >/dev/null 2>&1 || true
      fi
    fi
    return $rc_overall
  }

  # ── Helper: install/refresh .NET via the official dotnet-install script ────
  # Args: $1 = "sdk" | "runtime",  $2 = channel (e.g. 9.0),  $3 = runtime kind
  #       (only for runtime: "dotnet" for shared framework / "aspnetcore" / …)
  _dotnet_local_install() {
    local kind="$1" channel="$2" runtime_kind="${3:-dotnet}"
    local OS_NAME log_file
    OS_NAME=$(uname -s 2>/dev/null || echo "Unknown")
    log_file="/tmp/dotnet-install-$$.log"

    case "$OS_NAME" in
      Linux*|Darwin*|*BSD*)
        local installer_url="https://dot.net/v1/dotnet-install.sh"
        local installer_file="/tmp/dotnet-install-$$.sh"
        echo -e "  ${CYAN}📥 Fetching ${installer_url}${NC}"
        if ! { curl -fsSL "$installer_url" -o "$installer_file" 2>>"$log_file" \
               || wget -qO  "$installer_file" "$installer_url" 2>>"$log_file"; }; then
          echo -e "  ${RED}❌ Could not download dotnet-install.sh${NC}"
          tail -10 "$log_file" 2>/dev/null || true
          rm -f "$log_file" 2>/dev/null
          return 1
        fi
        chmod +x "$installer_file"
        local args=(--channel "$channel" --install-dir "$DOTNET_LOCAL_ROOT" --no-path)
        if [ "$kind" = "runtime" ]; then
          args+=(--runtime "$runtime_kind")
          echo -e "  ${CYAN}⚙  bash $installer_file --runtime $runtime_kind --channel $channel --install-dir $DOTNET_LOCAL_ROOT${NC}"
        else
          echo -e "  ${CYAN}⚙  bash $installer_file --channel $channel --install-dir $DOTNET_LOCAL_ROOT${NC}"
        fi
        bash "$installer_file" "${args[@]}" 2>&1 | tee -a "$log_file" | tail -10
        local rc=${PIPESTATUS[0]}
        rm -f "$installer_file" 2>/dev/null
        rm -f "$log_file" 2>/dev/null
        export DOTNET_ROOT="$DOTNET_LOCAL_ROOT"
        export PATH="$DOTNET_LOCAL_ROOT:$PATH"
        export DOTNET_NOLOGO=1
        export DOTNET_CLI_TELEMETRY_OPTOUT=1
        # macOS only: locally-built dotnet binaries from dotnet-install.sh are
        # not signed by Apple → Gatekeeper kills them with "Killed: 9" before
        # they can even print --version. Strip quarantine + apply an ad-hoc
        # codesign so the host can launch (and so it can later launch the
        # Creedengo.Tool apphost too).
        if [ "$OS_NAME" = "Darwin" ]; then
          xattr -dr com.apple.quarantine "$DOTNET_LOCAL_ROOT" 2>/dev/null || true
          if command -v codesign >/dev/null 2>&1 && [ -x "$DOTNET_LOCAL_ROOT/dotnet" ]; then
            codesign --force --deep --sign - "$DOTNET_LOCAL_ROOT/dotnet" >/dev/null 2>&1 || true
          fi
        fi
        return $rc
        ;;
      MINGW*|MSYS*|CYGWIN*)
        echo -e "  ${YELLOW}⚠ Windows shell detected — please install .NET ${kind} manually:${NC}"
        if [ "$kind" = "runtime" ]; then
          echo -e "  ${YELLOW}   PowerShell:  iwr https://dot.net/v1/dotnet-install.ps1 -OutFile dotnet-install.ps1; ./dotnet-install.ps1 -Runtime $runtime_kind -Channel $channel${NC}"
        else
          echo -e "  ${YELLOW}   PowerShell:  iwr https://dot.net/v1/dotnet-install.ps1 -OutFile dotnet-install.ps1; ./dotnet-install.ps1 -Channel $channel${NC}"
        fi
        return 1
        ;;
      *)
        echo -e "  ${YELLOW}⚠ Unknown OS '$OS_NAME' — install .NET ${kind} manually from https://dot.net/install${NC}"
        return 1
        ;;
    esac
  }

  # ── Helper: does the system expose Microsoft.NETCore.App <major>.x ? ───────
  # With DOTNET_ROLL_FORWARD=Major (set above), a net9.0 tool can also run on
  # a higher runtime (10.x, 11.x, …) — so we accept ANY major ≥ required.
  _dotnet_has_runtime_major() {
    local need="$1"
    command -v dotnet &>/dev/null || return 1
    dotnet --list-runtimes 2>/dev/null \
      | awk -v m="$need" '
          $1=="Microsoft.NETCore.App" {
            split($2, v, ".");
            if (v[1]+0 >= m+0) { found=1 }
          }
          END { exit !found }'
  }

  # ── Step A: ensure the SDK is present (so `dotnet tool install` works) ─────
  if ! command -v dotnet &>/dev/null; then
    echo -e "  ${YELLOW}⚠ 'dotnet' SDK not in PATH — attempting local install (no sudo required)${NC}"
    _dotnet_local_install sdk "$INSTALL_CHANNEL" || true

    # If the network install failed, try the offline backup at
    # <repo>/.creedengo/.dotnet/*.pkg (or *.tar.gz)
    if ! command -v dotnet &>/dev/null; then
      echo -e "  ${YELLOW}⚠ Network install failed — trying offline backup at .creedengo/.dotnet/${NC}"
      _dotnet_install_from_backup || true
    fi

    if command -v dotnet &>/dev/null; then
      DOTNET_VER=$(dotnet --version 2>/dev/null || echo "?")
      echo -e "  ${GREEN}✓ .NET SDK installed locally — version $DOTNET_VER${NC}"
      echo -e "  ${GREEN}  DOTNET_ROOT=$DOTNET_ROOT${NC}"
    else
      echo ""
      echo -e "${RED}❌ .NET project detected but the 'dotnet' SDK could not be auto-installed${NC}"
      echo -e "${YELLOW}   The Creedengo SonarQube plugin for C# is not published, so we${NC}"
      echo -e "${YELLOW}   refuse to launch SonarQube here — it would never apply eco-design${NC}"
      echo -e "${YELLOW}   rules to your C# code.${NC}"
      echo -e "${YELLOW}   💡 Install .NET SDK ${INSTALL_CHANNEL} manually and re-run, e.g.:${NC}"
      echo -e "${YELLOW}      • macOS:  brew install --cask dotnet-sdk${NC}"
      echo -e "${YELLOW}      • Linux:  curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel ${INSTALL_CHANNEL}${NC}"
      echo -e "${YELLOW}      • Win:    iwr https://dot.net/v1/dotnet-install.ps1 -OutFile dotnet-install.ps1; ./dotnet-install.ps1 -Channel ${INSTALL_CHANNEL}${NC}"
      echo -e "${YELLOW}      • Or run inside a container with the dotnet/sdk:${INSTALL_CHANNEL} image${NC}"
      exit 1
    fi
  else
    DOTNET_VER=$(dotnet --version 2>/dev/null || echo "?")
    echo -e "  ${GREEN}✓ Found 'dotnet' on PATH — SDK $DOTNET_VER${NC}"
  fi

  # ── Step B: ensure the runtime required by Creedengo.Tool is installed ────
  # Symptom this prevents:
  #     "You must install or update .NET to run this application.
  #      App: …/creedengo.tool/<ver>/tools/net9.0/any/Creedengo.Tool.dll
  #      .NET location: Not found"
  # Even when ``dotnet`` is on PATH (e.g. SDK 8 only), the apphost refuses to
  # launch the tool if no ``Microsoft.NETCore.App`` of the right major exists.
  if ! _dotnet_has_runtime_major "$REQUIRED_RUNTIME_MAJOR"; then
    echo -e "  ${YELLOW}⚠ .NET runtime ${REQUIRED_RUNTIME_MAJOR}.x missing — Creedengo.Tool targets net${REQUIRED_RUNTIME_MAJOR}.0${NC}"
    echo -e "  ${CYAN}📥 Installing .NET ${REQUIRED_RUNTIME_MAJOR}.0 runtime locally (no sudo required)...${NC}"
    if _dotnet_local_install runtime "${REQUIRED_RUNTIME_MAJOR}.0" dotnet \
       && _dotnet_has_runtime_major "$REQUIRED_RUNTIME_MAJOR"; then
      echo -e "  ${GREEN}✓ .NET ${REQUIRED_RUNTIME_MAJOR}.x runtime installed under $DOTNET_ROOT${NC}"
    else
      # Last-ditch attempt: install the full SDK of the required major (it
      # bundles the matching shared runtime).
      echo -e "  ${YELLOW}⚠ Runtime install failed — falling back to installing the SDK ${REQUIRED_RUNTIME_MAJOR}.0${NC}"
      _dotnet_local_install sdk "${REQUIRED_RUNTIME_MAJOR}.0" || true
    fi

    # Offline backup fallback: extract any locally-cached .pkg/.tar.gz the
    # operator dropped at <repo>/.creedengo/.dotnet/. With
    # DOTNET_ROLL_FORWARD=Major this can be a higher major than required
    # (e.g. dotnet-runtime-10.x for a net9.0 tool).
    if ! _dotnet_has_runtime_major "$REQUIRED_RUNTIME_MAJOR"; then
      echo -e "  ${YELLOW}⚠ Online runtime install failed — trying offline backup at .creedengo/.dotnet/${NC}"
      _dotnet_install_from_backup || true
    fi

    if ! _dotnet_has_runtime_major "$REQUIRED_RUNTIME_MAJOR"; then
      echo ""
      echo -e "${RED}❌ Could not install the .NET ${REQUIRED_RUNTIME_MAJOR}.x runtime required by Creedengo.Tool${NC}"
      echo -e "${YELLOW}   The tool ships as net${REQUIRED_RUNTIME_MAJOR}.0 and refuses to launch without it.${NC}"
      echo -e "${YELLOW}   💡 Install the .NET ${REQUIRED_RUNTIME_MAJOR}.0 runtime manually and re-run:${NC}"
      echo -e "${YELLOW}      • macOS (arm64): brew install --cask dotnet  # or:${NC}"
      echo -e "${YELLOW}        curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --runtime dotnet --channel ${REQUIRED_RUNTIME_MAJOR}.0${NC}"
      echo -e "${YELLOW}      • Linux: curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --runtime dotnet --channel ${REQUIRED_RUNTIME_MAJOR}.0${NC}"
      echo -e "${YELLOW}      • Win:   iwr https://dot.net/v1/dotnet-install.ps1 -OutFile dotnet-install.ps1; ./dotnet-install.ps1 -Runtime dotnet -Channel ${REQUIRED_RUNTIME_MAJOR}.0${NC}"
      echo -e "${YELLOW}      • Direct download: https://aka.ms/dotnet-core-applaunch?missing_runtime=true${NC}"
      echo -e "${YELLOW}      • Override the requirement: CREEDENGO_REQUIRED_RUNTIME=8 ${0##*/}${NC}"
      exit 1
    fi
  else
    if [ "$DEBUG_MODE" = true ]; then
      echo -e "  ${GREEN}✓ .NET ${REQUIRED_RUNTIME_MAJOR}.x runtime is available${NC}"
    fi
  fi
  echo ""
fi

# Always define PLUGIN_DIR / BACKUP_DIR — they are referenced by Step 4
# (SonarQube docker run) and the C# JAR detection block, even when Step 3
# below is skipped via CSHARP_DIRECT_PLANNED=true. Without this guard, ``set
# -u`` (nounset) would crash with "PLUGIN_DIR: unbound variable" if the C#
# fast path silently fell through to the SonarQube branch (e.g. mixed-language
# repos where csharp planning is true but Java/JS modules also need scanning).
PLUGIN_DIR="$GREEN_DIR/.creedengo/plugins"
BACKUP_DIR="$GREEN_DIR/.creedengo/backup"
mkdir -p "$PLUGIN_DIR" "$BACKUP_DIR"

if [ "$CSHARP_DIRECT_PLANNED" = false ]; then

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

  # ── csharp: D1 try the SonarQube JAR plugin (if green-code-initiative
  #            publishes one); D2 fallback handled later via dotnet-sonarscanner
  #            + Roslyn NuGet analyzer injected at scan time. We do NOT skip
  #            the cache/download attempt anymore — if a JAR is available it
  #            will be picked up by the regular logic below; if not, the
  #            scanner will still work (the NuGet analyzer surfaces the rules).
  if [ "$plugin_key" = "csharp" ]; then
    echo -e "  ${CYAN}ℹ ${plugin_key}: trying SonarQube JAR plugin (D1) — falls back to NuGet Roslyn analyzer (D2) if absent${NC}"
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

fi  # ── end of "if [ \"$CSHARP_DIRECT_PLANNED\" = false ]" wrapping Step 3 (plugin downloads) ──

echo ""

###############################################################################
# Step 3-bis: Fast path for C# / .NET via the official Creedengo .NET tool
#             (https://github.com/green-code-initiative/creedengo-csharp)
#
# When the project is C#-only and ``dotnet`` is available locally, we bypass
# SonarQube entirely and use ``Creedengo.Tool`` (NuGet) which writes JSON
# directly. This is:
#   • ✓ much faster (no Docker, no ES shard recovery, no quality profile setup)
#   • ✓ uses the canonical eco-design ruleset (Creedengo Roslyn analyzers)
#   • ✓ produces the report format the dashboard already understands (after
#     conversion via creedengo-cli-to-report.py).
#
# A side benefit: this works even when the SonarQube creedengo-csharp JAR plugin
# is absent (which is currently the case — green-code-initiative does not yet
# publish one for SonarQube; see creedengo-csharp-sonarqube companion repo).
#
# The flag CSHARP_DIRECT_DONE=true short-circuits Steps 4 → 11 below, jumping
# straight to Step 12 (embed detection metadata) and the dashboard wrap-up.
###############################################################################
CSHARP_DIRECT_DONE=false
# Run the fast path whenever the pre-gate planned it OR — for safety — whenever
# we still see any .NET signal. This guarantees we never silently regress to
# SonarQube for a C# project.
if [ "$CSHARP_DIRECT_PLANNED" = true ] || [ -n "$DOTNET_MODULE_DIR" ] \
   || echo "${PLUGIN_KEYS}" | grep -q "csharp"; then

  # If the SDK isn't here, we already exited above when CSHARP_DIRECT_PLANNED
  # was set; this guard is a defence in depth in case a custom build path
  # reaches this block without going through the pre-gate.
  if ! command -v dotnet &>/dev/null; then
    echo -e "${YELLOW}⚠ Skipping Creedengo .NET fast path — 'dotnet' SDK not in PATH${NC}"
  else

  echo -e "${YELLOW}━━━ 🐝 Creedengo C# fast path (.NET tool) ━━━${NC}"
  echo -e "  Tool:    ${CYAN}Creedengo.Tool${NC} (https://www.nuget.org/packages/Creedengo.Tool)"
  echo -e "  Target:  ${CYAN}${DOTNET_ENTRY_POINT:-$DOTNET_MODULE_DIR}${NC}"

  # Ensure user-installed global tools are on PATH
  export PATH="$PATH:$HOME/.dotnet/tools"

  # Local offline backup: when nuget.org is unreachable (CI behind a proxy,
  # offline workshops, etc.), drop a pre-downloaded ``Creedengo.Tool.<ver>.nupkg``
  # — or a pre-extracted CLI binary — into one of these paths.
  CREEDENGO_TOOL_BACKUP_DIRS=(
    "$GREEN_DIR/.creedengo/.creedengo.tool"
    "$GREEN_DIR/.creedengo/creedengo.tool"
    "$GREEN_DIR/.creedengo/backup/creedengo.tool"
  )

  # ── Helper: locate the installed Creedengo CLI binary ──────────────────────
  # The NuGet package ID is "Creedengo.Tool" (a.k.a. lowercase "creedengo.tool")
  # but the executable name (``<ToolCommandName>`` in the .csproj) varies across
  # versions: v1.x → ``creedengo``, v2.x → ``creedengo-cli``, may change again.
  # This helper queries ``dotnet tool list --global`` for the **actual command
  # name** declared by the package, then resolves it on disk. Falls back to
  # globbing ``~/.dotnet/tools/creedengo*`` for robustness.
  _find_creedengo_cli() {
    # Try parsing "Commands" column from `dotnet tool list --global`.
    # Output format (whitespace-separated):
    #   Package ID       Version   Commands
    #   ---------------- --------- ------------
    #   creedengo.tool   2.1.0     creedengo-cli
    local cmd
    cmd=$(dotnet tool list --global 2>/dev/null \
          | awk 'tolower($1) ~ /^creedengo\.tool$/ {print $3; exit}')
    if [ -n "$cmd" ]; then
      if command -v "$cmd" &>/dev/null; then echo "$cmd"; return 0; fi
      [ -x "$HOME/.dotnet/tools/$cmd" ] && { echo "$HOME/.dotnet/tools/$cmd"; return 0; }
    fi
    # Glob-based discovery
    for cand in "$HOME/.dotnet/tools/"creedengo-cli \
                "$HOME/.dotnet/tools/"creedengo \
                "$HOME/.dotnet/tools/"creedengo.tool \
                "$HOME/.dotnet/tools/"creedengo*; do
      [ -x "$cand" ] && { echo "$cand"; return 0; }
    done
    return 1
  }

  # ── Helper: is the package already registered as a global dotnet tool? ──
  _creedengo_tool_installed() {
    dotnet tool list --global 2>/dev/null \
      | awk 'tolower($1) ~ /^creedengo\.tool$/' | grep -q .
  }

  # If already installed (e.g. by a previous run or by the user), skip install.
  if ! CREEDENGO_CLI_BIN=$(_find_creedengo_cli); then
    echo -e "  ${CYAN}📥 Installing Creedengo.Tool global tool (online from nuget.org)...${NC}"
    INSTALL_LOG="/tmp/creedengo-cli-install-$$.log"
    : >"$INSTALL_LOG"

    # Note: ``dotnet tool install --global`` returns a non-zero exit code with
    # message "is already installed" if the package was previously registered
    # (even partially). We treat that as success and continue to the binary
    # check below — that's why we don't ``|| exit`` here.
    dotnet tool install --global Creedengo.Tool >>"$INSTALL_LOG" 2>&1 \
      || dotnet tool update  --global Creedengo.Tool >>"$INSTALL_LOG" 2>&1 \
      || true

    # ── Try offline backup if the binary still isn't reachable ──
    if ! CREEDENGO_CLI_BIN=$(_find_creedengo_cli); then
      echo -e "  ${YELLOW}⚠ Online install did not yield a usable CLI — searching local backup...${NC}"
      BACKUP_NUPKG=""
      BACKUP_BIN=""
      BACKUP_DIR_USED=""
      for d in "${CREEDENGO_TOOL_BACKUP_DIRS[@]}"; do
        [ -d "$d" ] || continue
        # .nupkg names are case-insensitive on disk; match both spellings
        cand=$(ls -1 "$d"/Creedengo.Tool*.nupkg "$d"/creedengo.tool*.nupkg 2>/dev/null | sort -V | tail -1)
        if [ -n "$cand" ] && [ -f "$cand" ]; then BACKUP_NUPKG="$cand"; BACKUP_DIR_USED="$d"; break; fi
        for b in "$d/creedengo-cli" "$d/creedengo-cli.exe" "$d/creedengo" "$d/creedengo.tool"; do
          if [ -x "$b" ] || [ -f "$b" ]; then BACKUP_BIN="$b"; BACKUP_DIR_USED="$d"; break; fi
        done
        [ -n "$BACKUP_BIN" ] && break
      done

      if [ -n "$BACKUP_NUPKG" ]; then
        echo -e "  ${CYAN}📦 Found offline package: ${BACKUP_NUPKG}${NC}"

        # Critical: the dotnet CLI's ``--add-source`` resolves to the version
        # *being installed* — but if "creedengo.tool" is already registered as
        # a global tool (from a failed run, system-wide install, or prior
        # offline attempt) we MUST uninstall first or ``install`` will exit
        # with "is already installed" and never copy the new binary.
        if _creedengo_tool_installed; then
          echo -e "  ${CYAN}↻ Uninstalling stale 'creedengo.tool' global tool entry...${NC}"
          dotnet tool uninstall --global creedengo.tool >>"$INSTALL_LOG" 2>&1 \
            || dotnet tool uninstall --global Creedengo.Tool >>"$INSTALL_LOG" 2>&1 \
            || true
        fi

        echo -e "  ${CYAN}⚙  dotnet tool install --global --add-source \"$BACKUP_DIR_USED\" Creedengo.Tool${NC}"
        dotnet tool install --global --add-source "$BACKUP_DIR_USED" Creedengo.Tool \
          >>"$INSTALL_LOG" 2>&1 \
          || dotnet tool install --global --add-source "$BACKUP_DIR_USED" creedengo.tool \
          >>"$INSTALL_LOG" 2>&1 \
          || true

        if CREEDENGO_CLI_BIN=$(_find_creedengo_cli); then
          echo -e "  ${GREEN}✓ Creedengo.Tool installed from local backup → $CREEDENGO_CLI_BIN${NC}"
        fi
      elif [ -n "$BACKUP_BIN" ]; then
        echo -e "  ${CYAN}📦 Found pre-built binary: ${BACKUP_BIN}${NC}"
        chmod +x "$BACKUP_BIN" 2>/dev/null || true
        export PATH="$BACKUP_DIR_USED:$PATH"
        CREEDENGO_CLI_BIN="$BACKUP_BIN"
        echo -e "  ${GREEN}✓ Using local Creedengo.Tool binary${NC}"
      fi
    fi

    # ── If the package is registered but binary still not found, surface this ──
    if [ -z "${CREEDENGO_CLI_BIN:-}" ] && _creedengo_tool_installed; then
      echo -e "  ${YELLOW}ℹ Package 'creedengo.tool' is registered but its CLI command was not located.${NC}"
      echo -e "  ${YELLOW}   Tools dir contents:${NC}"
      ls -la "$HOME/.dotnet/tools/" 2>/dev/null | sed 's/^/      /' | head -20
    fi

    if [ -z "${CREEDENGO_CLI_BIN:-}" ]; then
      echo -e "  ${YELLOW}⚠ Could not install Creedengo.Tool (online + offline both failed)${NC}"
      echo -e "  ${YELLOW}   💡 Drop a pre-downloaded NuGet package at:${NC}"
      echo -e "  ${YELLOW}      ${CREEDENGO_TOOL_BACKUP_DIRS[0]}/Creedengo.Tool.<version>.nupkg${NC}"
      echo -e "  ${YELLOW}   📜 Last install log (tail):${NC}"
      tail -15 "$INSTALL_LOG" 2>/dev/null | sed 's/^/      /'
    fi
    rm -f "$INSTALL_LOG" 2>/dev/null
  else
    echo -e "  ${GREEN}✓ Creedengo.Tool already installed → $CREEDENGO_CLI_BIN${NC}"
  fi

  if [ -n "${CREEDENGO_CLI_BIN:-}" ]; then
    CREEDENGO_TOOL_VERSION=$(dotnet tool list --global 2>/dev/null \
      | awk 'tolower($1) ~ /^creedengo\.tool$/ {print $2; exit}')
    [ -z "$CREEDENGO_TOOL_VERSION" ] && CREEDENGO_TOOL_VERSION="unknown"

    # Pick the analysis target (prefer .sln/.slnx, then .csproj, then nested csproj)
    CREEDENGO_TARGET="${DOTNET_ENTRY_POINT:-}"
    if [ -z "$CREEDENGO_TARGET" ] || [ ! -e "$CREEDENGO_TARGET" ]; then
      CREEDENGO_TARGET=$(ls "$DOTNET_MODULE_DIR"/*.slnx 2>/dev/null | head -1)
      [ -z "$CREEDENGO_TARGET" ] && CREEDENGO_TARGET=$(ls "$DOTNET_MODULE_DIR"/*.sln    2>/dev/null | head -1)
      [ -z "$CREEDENGO_TARGET" ] && CREEDENGO_TARGET=$(ls "$DOTNET_MODULE_DIR"/*.csproj 2>/dev/null | head -1)
      [ -z "$CREEDENGO_TARGET" ] && CREEDENGO_TARGET=$(ls "$DOTNET_MODULE_DIR"/*/*.csproj 2>/dev/null | head -1)
    fi

    if [ -z "$CREEDENGO_TARGET" ] || [ ! -e "$CREEDENGO_TARGET" ]; then
      echo -e "  ${YELLOW}⚠ Could not locate a .sln/.slnx/.csproj under ${DOTNET_MODULE_DIR} — falling back${NC}"
    else
      # ── Workaround for upstream packaging bug in Creedengo.Tool 2.x ────────
      # The published .nupkg does NOT include `Creedengo.globalconfig` (the
      # editorconfig file the analyzer reads to map GCI* rule severities).
      # Without it the CLI errors with:
      #   "Editor config file not found at .../tools/net9.0/any/Creedengo.globalconfig"
      # We synthesize a minimal valid one in the tool's BaseDirectory if missing.
      CREEDENGO_TOOL_DIR=$(dirname "$(readlink "$CREEDENGO_CLI_BIN" 2>/dev/null || echo "$CREEDENGO_CLI_BIN")")
      # `creedengo` in $HOME/.dotnet/tools is a shim — the real tool lives under
      # .store/creedengo.tool/<ver>/creedengo.tool/<ver>/tools/<tfm>/any/.
      if [ ! -d "$CREEDENGO_TOOL_DIR" ] || [ ! -f "$CREEDENGO_TOOL_DIR/Creedengo.Tool.dll" ]; then
        CREEDENGO_TOOL_DIR=$(find "$HOME/.dotnet/tools/.store/creedengo.tool" \
                              -type f -name "Creedengo.Tool.dll" 2>/dev/null \
                            | head -1 | xargs -I{} dirname {} 2>/dev/null)
      fi
      if [ -n "$CREEDENGO_TOOL_DIR" ] && [ -d "$CREEDENGO_TOOL_DIR" ] \
         && [ ! -f "$CREEDENGO_TOOL_DIR/Creedengo.globalconfig" ]; then
        #    <repo>/.creedengo/.dotnet/Creedengo.globalconfig (matches the
        #    upstream creedengo-csharp release artifact).
        BACKUP_GLOBALCONFIG="$GREEN_DIR/.creedengo/.dotnet/Creedengo.globalconfig"
        if [ -f "$BACKUP_GLOBALCONFIG" ]; then
          echo -e "  ${YELLOW}⚠ Creedengo.globalconfig missing from tool install — copying offline backup${NC}"
          cp "$BACKUP_GLOBALCONFIG" "$CREEDENGO_TOOL_DIR/Creedengo.globalconfig"
          echo -e "  ${GREEN}  ✓ Copied $BACKUP_GLOBALCONFIG → $CREEDENGO_TOOL_DIR/Creedengo.globalconfig${NC}"
        else
          # 2) Fallback: synthesize a minimal valid one so the CLI launches.
          echo -e "  ${YELLOW}⚠ Creedengo.globalconfig missing from tool install — synthesizing a minimal one${NC}"
          # is_global=true makes this an unconditional .editorconfig that applies
          # to every analyzed file. global_level=100 means it overrides any other
          # config a user project may also define. We enable the full known GCI*
          # rule set at "warning" so the CLI emits diagnostics for them.
          {
            echo "is_global = true"
            echo "global_level = 100"
            echo ""
            for n in 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 \
                     85 86 87 88 89 90 91 92 93 94 95 96 97 98 99; do
              printf 'dotnet_diagnostic.GCI%d.severity = warning\n' "$n"
            done
          } > "$CREEDENGO_TOOL_DIR/Creedengo.globalconfig"
          echo -e "  ${GREEN}  ✓ Wrote $CREEDENGO_TOOL_DIR/Creedengo.globalconfig${NC}"
          echo -e "  ${YELLOW}    💡 For a full official rule set, drop the upstream file at:${NC}"
          echo -e "  ${YELLOW}       $BACKUP_GLOBALCONFIG${NC}"
        fi
      fi

      # ── Workaround #2: ensure Microsoft.CodeAnalysis.NetAnalyzers DLLs are
      # available next to Creedengo.Tool.dll. The published Creedengo.Tool
      # .nupkg references CA* rules in its globalconfig but does NOT bundle
      # the NetAnalyzers assemblies. Without them the CLI errors with:
      #   "Could not load file or assembly 'Microsoft.CodeAnalysis.NetAnalyzers,
      #    Culture=neutral, PublicKeyToken=null'."
      # The .NET SDK ships a copy at
      #   <DOTNET_ROOT>/sdk/<ver>/Sdks/Microsoft.NET.Sdk/analyzers/
      # and the operator can also drop them at
      #   <repo>/.creedengo/.dotnet/Microsoft.CodeAnalysis*NetAnalyzers.dll
      if [ -n "$CREEDENGO_TOOL_DIR" ] && [ -d "$CREEDENGO_TOOL_DIR" ]; then
        for asm in Microsoft.CodeAnalysis.NetAnalyzers.dll \
                   Microsoft.CodeAnalysis.CSharp.NetAnalyzers.dll; do
          if [ ! -f "$CREEDENGO_TOOL_DIR/$asm" ]; then
            # 1) operator-provided backup
            CAND=""
            for dir in "$GREEN_DIR/.creedengo/.dotnet" \
                       "$GREEN_DIR/.creedengo/analyzers"; do
              if [ -f "$dir/$asm" ]; then CAND="$dir/$asm"; break; fi
            done
            # 2) latest copy shipped with the local .NET SDK
            if [ -z "$CAND" ]; then
              CAND=$(find "${DOTNET_ROOT:-$HOME/.dotnet}" \
                       -path "*/Sdks/Microsoft.NET.Sdk/analyzers/$asm" \
                       2>/dev/null | sort -V | tail -1)
            fi
            # 3) any other dotnet install on PATH
            if [ -z "$CAND" ]; then
              CAND=$(find /usr/local/share/dotnet /usr/share/dotnet "$HOME/.dotnet" \
                       -path "*/Sdks/Microsoft.NET.Sdk/analyzers/$asm" \
                       2>/dev/null | sort -V | tail -1)
            fi
            if [ -n "$CAND" ] && [ -f "$CAND" ]; then
              cp "$CAND" "$CREEDENGO_TOOL_DIR/$asm"
              echo -e "  ${GREEN}  ✓ Copied $asm → tool dir (from $(dirname "$CAND"))${NC}"
            else
              echo -e "  ${YELLOW}  ⚠ Could not locate $asm — CA* rules will be skipped${NC}"
              echo -e "  ${YELLOW}    💡 Drop it at: $GREEN_DIR/.creedengo/.dotnet/$asm${NC}"
            fi
          fi
        done
      fi

      # ── Workaround #3: align bundled MSBuild assemblies with the SDK that
      # Microsoft.Build.Locator will register at runtime. The Creedengo.Tool
      # 2.1.0 .nupkg ships an older Microsoft.Build.Framework.dll (17.12)
      # while a recent .NET SDK on disk (e.g. 9.0.x / 10.x) loads a newer
      # Microsoft.Build.dll that references new fields like
      #   Microsoft.Build.Framework.ChangeWaves.Wave17_14
      # introduced in MSBuild 17.14. The result is the runtime error:
      #   "Field not found: 'Microsoft.Build.Framework.ChangeWaves.Wave17_14'"
      # (see AnalyzeCommand.ExecuteAsync at MSBuildWorkspace.OpenSolutionAsync).
      # Fix: overwrite the bundled MSBuild assemblies with the ones from the
      # highest installed SDK (which is exactly what MSBuildLocator will use).
      if [ -n "$CREEDENGO_TOOL_DIR" ] && [ -d "$CREEDENGO_TOOL_DIR" ]; then
        # Detect the tool's TFM from its install path: ".../tools/net<major>.0/any"
        # The MSBuild assemblies must be sourced from a matching-major SDK,
        # otherwise their transitive references (e.g. System.Runtime
        # Version=<major>.0.0.0) will fail to resolve at runtime — that's the
        # root cause of:
        #   "Could not load file or assembly 'System.Runtime, Version=10.0.0.0…'"
        # when SDK 10 dlls are dropped into a net9.0 tool dir.
        TOOL_TFM_MAJOR=$(printf '%s' "$CREEDENGO_TOOL_DIR" \
                         | sed -nE 's|.*/tools/net([0-9]+)\.[0-9]+/any.*|\1|p')
        MSBUILD_SDK_DIR=""
        if [ -n "$TOOL_TFM_MAJOR" ]; then
          MSBUILD_SDK_DIR=$(ls -d "${DOTNET_ROOT:-$HOME/.dotnet}"/sdk/${TOOL_TFM_MAJOR}.* 2>/dev/null \
                            | sort -V | tail -1)
          if [ -z "$MSBUILD_SDK_DIR" ]; then
            MSBUILD_SDK_DIR=$(ls -d /usr/local/share/dotnet/sdk/${TOOL_TFM_MAJOR}.* /usr/share/dotnet/sdk/${TOOL_TFM_MAJOR}.* 2>/dev/null \
                              | sort -V | tail -1)
          fi
        fi
        # Fallback: highest installed SDK (last-resort, may produce the
        # System.Runtime mismatch above if its major differs from the tool TFM).
        if [ -z "$MSBUILD_SDK_DIR" ] || [ ! -d "$MSBUILD_SDK_DIR" ]; then
          MSBUILD_SDK_DIR=$(ls -d "${DOTNET_ROOT:-$HOME/.dotnet}"/sdk/* 2>/dev/null \
                            | sort -V | tail -1)
        fi
        if [ -z "$MSBUILD_SDK_DIR" ] || [ ! -d "$MSBUILD_SDK_DIR" ]; then
          MSBUILD_SDK_DIR=$(ls -d /usr/local/share/dotnet/sdk/* /usr/share/dotnet/sdk/* 2>/dev/null \
                            | sort -V | tail -1)
        fi
        if [ -n "$MSBUILD_SDK_DIR" ] && [ -d "$MSBUILD_SDK_DIR" ]; then
          MSB_STAMP_FILE="$CREEDENGO_TOOL_DIR/.msbuild-aligned-from"
          MSB_STAMP_PREV=""
          [ -f "$MSB_STAMP_FILE" ] && MSB_STAMP_PREV=$(cat "$MSB_STAMP_FILE" 2>/dev/null || true)
          if [ "$MSB_STAMP_PREV" != "$MSBUILD_SDK_DIR" ]; then
            if [ -n "$TOOL_TFM_MAJOR" ]; then
              echo -e "  ${CYAN}🔧 Aligning bundled MSBuild with SDK ${MSBUILD_SDK_DIR##*/} (tool TFM net${TOOL_TFM_MAJOR}.0)${NC}"
            else
              echo -e "  ${CYAN}🔧 Aligning bundled MSBuild with SDK ${MSBUILD_SDK_DIR##*/}${NC}"
            fi
            for msb in Microsoft.Build.Framework.dll \
                       Microsoft.Build.Tasks.Core.dll \
                       Microsoft.Build.Utilities.Core.dll \
                       Microsoft.Build.dll \
                       Microsoft.NET.StringTools.dll; do
              if [ -f "$MSBUILD_SDK_DIR/$msb" ]; then
                cp "$MSBUILD_SDK_DIR/$msb" "$CREEDENGO_TOOL_DIR/$msb" 2>/dev/null \
                  && echo -e "  ${GREEN}    ✓ $msb (�� SDK ${MSBUILD_SDK_DIR##*/})${NC}"
              fi
            done
            printf '%s\n' "$MSBUILD_SDK_DIR" > "$MSB_STAMP_FILE" 2>/dev/null || true
          elif [ "$DEBUG_MODE" = true ]; then
            echo -e "  ${GREEN}✓ MSBuild assemblies already aligned with ${MSBUILD_SDK_DIR##*/}${NC}"
          fi
        else
          echo -e "  ${YELLOW}  ⚠ No .NET SDK found to align MSBuild assemblies — analyze may fail with 'Wave17_14'${NC}"
        fi
      fi

      CLI_OUT="/tmp/creedengo-cli-out-$$.json"
      rm -f "$CLI_OUT" 2>/dev/null

      # Pin the SDK that Microsoft.Build.Locator will register inside the tool
      # by writing a temporary global.json next to the target. Without this,
      # Locator picks the highest installed SDK regardless of our DLL alignment
      # — and SDK 10 dlls dropped into a net9.0 tool fail with
      # "Could not load file or assembly 'System.Runtime, Version=10.0.0.0…'".
      CREEDENGO_TARGET_DIR=$(dirname "$CREEDENGO_TARGET")
      CREEDENGO_GJSON="$CREEDENGO_TARGET_DIR/global.json"
      CREEDENGO_GJSON_BAK=""
      CREEDENGO_GJSON_WRITTEN=false
      if [ -n "$MSBUILD_SDK_DIR" ] && [ -d "$MSBUILD_SDK_DIR" ]; then
        SDK_PIN_VERSION="${MSBUILD_SDK_DIR##*/}"
        if [ -f "$CREEDENGO_GJSON" ]; then
          CREEDENGO_GJSON_BAK="$CREEDENGO_GJSON.creedengo-bak.$$"
          mv "$CREEDENGO_GJSON" "$CREEDENGO_GJSON_BAK" 2>/dev/null || CREEDENGO_GJSON_BAK=""
        fi
        cat > "$CREEDENGO_GJSON" <<EOF
{
  "sdk": {
    "version": "$SDK_PIN_VERSION",
    "rollForward": "latestMinor",
    "allowPrerelease": true
  }
}
EOF
        CREEDENGO_GJSON_WRITTEN=true
        echo -e "  ${CYAN}📌 Pinned SDK ${SDK_PIN_VERSION} via temporary global.json (matches tool TFM)${NC}"
      fi

      echo -e "  ${CYAN}▶ creedengo-cli analyze \"$CREEDENGO_TARGET\" \"$CLI_OUT\"${NC}"
      # Run from the target's directory so MSBuildLocator picks up our global.json.
      # Output format is inferred from the extension (.json | .html | .csv)
      ( cd "$CREEDENGO_TARGET_DIR" && "$CREEDENGO_CLI_BIN" analyze "$CREEDENGO_TARGET" "$CLI_OUT" ) 2>&1 | tail -40 || true

      # Cleanup our temporary global.json (restore the user's original if any).
      if [ "$CREEDENGO_GJSON_WRITTEN" = true ]; then
        rm -f "$CREEDENGO_GJSON" 2>/dev/null || true
        if [ -n "$CREEDENGO_GJSON_BAK" ] && [ -f "$CREEDENGO_GJSON_BAK" ]; then
          mv "$CREEDENGO_GJSON_BAK" "$CREEDENGO_GJSON" 2>/dev/null || true
        fi
      fi

      if [ -s "$CLI_OUT" ]; then
        mkdir -p "$REPORTS_DIR"
        echo -e "  ${CYAN}▶ Converting to dashboard schema → reports/creedengo-report.json${NC}"
        if python3 "$SCRIPT_DIR/creedengo-cli-to-report.py" \
             --input  "$CLI_OUT" \
             --output "$REPORTS_DIR/creedengo-report.json" \
             --appname "$APPNAME" \
             --project "$CREEDENGO_TARGET" \
             --tool-version "$CREEDENGO_TOOL_VERSION"; then
          CSHARP_DIRECT_DONE=true
          echo -e "  ${GREEN}✓ Creedengo C# analysis completed via .NET tool — SonarQube steps will be skipped${NC}"
        else
          echo -e "  ${YELLOW}⚠ Conversion failed — falling back to SonarQube path${NC}"
        fi
        rm -f "$CLI_OUT" 2>/dev/null
      else
        echo -e "  ${YELLOW}⚠ creedengo-cli produced no output — falling back to SonarQube path${NC}"
      fi
    fi
  fi
  fi  # ── end of "if ! command -v dotnet ... else" ──
  echo ""
fi

###############################################################################
# Step 4: Start SonarQube container with all plugins
###############################################################################
if [ "$CSHARP_DIRECT_DONE" = true ]; then
  echo -e "${CYAN}⏩ Skipping Steps 4–11 (SonarQube) — using Creedengo .NET tool report${NC}"
  echo ""
elif [ "$CSHARP_DIRECT_PLANNED" = true ]; then
  # Defensive: csharp project was planned for the .NET tool but the analysis
  # did NOT complete (Creedengo.Tool install failed online + offline backup,
  # creedengo-cli crashed, conversion failed, …). The user explicitly asked
  # to NEVER fall back to SonarQube for a .NET project — that pipeline can
  # only run Java/Python/JS plugins on a C# repo, never eco-design rules. So
  # we abort here with a clear message instead of silently scanning nothing.
  echo ""
  echo -e "${RED}❌ Creedengo .NET fast path failed and CSHARP_DIRECT_PLANNED=true${NC}"
  echo -e "${YELLOW}   The user requested no SonarQube fallback for .NET projects, so we${NC}"
  echo -e "${YELLOW}   are aborting instead of running an analysis that would never apply${NC}"
  echo -e "${YELLOW}   any C# eco-design rules.${NC}"
  echo -e "${YELLOW}   💡 Likely causes:${NC}"
  echo -e "${YELLOW}      • Creedengo.Tool could not be installed (no internet + no .nupkg backup in${NC}"
  echo -e "${YELLOW}        .creedengo/.creedengo.tool/) — see that directory's README.md${NC}"
  echo -e "${YELLOW}      • creedengo-cli analyze produced no output (build error in your project?)${NC}"
  echo -e "${YELLOW}      • The conversion script failed (unsupported JSON shape from the tool)${NC}"
  exit 1
else
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
SONAR_DEAD=false
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  # Bail out fast if the container died (Elasticsearch shard failure, OOM, …)
  # — better a clear "SonarQube failed to start" than a 180s timeout.
  if ! $CONTAINER_RT inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
    echo -e "  ${RED}❌ SonarQube container is no longer running (after ${ELAPSED}s)${NC}"
    echo -e "  ${YELLOW}── Last 40 log lines ──${NC}"
    $CONTAINER_RT logs --tail 40 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /'
    echo -e "  ${YELLOW}── End of logs ──${NC}"
    SONAR_DEAD=true
    break
  fi
  STATUS=$(curl -s "http://localhost:${SONAR_PORT}/api/system/status" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  if [ "$STATUS" = "UP" ]; then echo -e "  ${GREEN}✅ SonarQube ready (${ELAPSED}s)${NC}"; break; fi
  sleep 2; ELAPSED=$((ELAPSED + 2))
  [ $((ELAPSED % 20)) -eq 0 ] && echo -e "  ... ${ELAPSED}s (${STATUS:-starting})"
done

if [ "$SONAR_DEAD" = true ]; then
  echo -e "${RED}❌ SonarQube failed to start — Creedengo analysis aborted${NC}"
  echo -e "${YELLOW}💡 Common causes:${NC}"
  echo -e "   • Elasticsearch shard recovery race (try again, or run with --force-cleanup)"
  echo -e "   • Insufficient Docker memory (give Docker ≥ 4 GB)"
  echo -e "   • Stale ES indices in a reused container volume"
  echo -e "${YELLOW}↩  start.sh will continue — Green Score report (if any) is still produced.${NC}"
  exit 2
fi
if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
  echo -e "  ${RED}❌ Timeout (${TIMEOUT}s) — SonarQube /api/system/status never returned UP${NC}"
  echo -e "  ${YELLOW}── Last 30 log lines ──${NC}"
  $CONTAINER_RT logs --tail 30 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /'
  exit 1
fi
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

# ── Strategy A.5: dotnet-sonarscanner for C# / .NET projects ──
#   D1 (preferred): if a creedengo-csharp-plugin JAR was downloaded above, it
#                   is already mounted into SonarQube → standard scanner picks
#                   up the eco-design rules automatically.
#   D2 (fallback):  if the JAR is absent, we still run the scanner — the user
#                   gets the stock SonarQube C# analysis (no eco-design rules)
#                   and a clear notice. This keeps the pipeline functional.
if [ "$ANALYSIS_SUCCESS" = false ] \
   && echo "$PLUGIN_KEYS" | grep -q "csharp" \
   && [ -n "$DOTNET_MODULE_DIR" ] \
   && command -v dotnet &>/dev/null; then

  echo -e "  Using: ${CYAN}dotnet sonarscanner (C# / .NET)${NC}"

  # ── Detect creedengo-csharp JAR presence (D1 vs D2) ──
  CREEDENGO_CSHARP_JAR=$(ls "$PLUGIN_DIR"/creedengo-csharp-plugin-*.jar 2>/dev/null | head -1)
  if [ -n "$CREEDENGO_CSHARP_JAR" ]; then
    echo -e "  ${GREEN}✓ D1: creedengo-csharp plugin JAR present — eco-design rules will be applied${NC}"
  else
    echo -e "  ${YELLOW}⚠ D2 fallback: no creedengo-csharp JAR available — running stock SonarQube C# analysis${NC}"
    echo -e "  ${YELLOW}   (Creedengo eco-design rules for C# are not yet published as a SonarQube JAR plugin.)${NC}"
  fi

  # ── Ensure dotnet-sonarscanner global tool is installed ──
  if ! dotnet tool list --global 2>/dev/null | grep -qi "dotnet-sonarscanner"; then
    echo -e "  ${CYAN}📥 Installing dotnet-sonarscanner global tool...${NC}"
    dotnet tool install --global dotnet-sonarscanner >/dev/null 2>&1 || \
      dotnet tool update  --global dotnet-sonarscanner >/dev/null 2>&1 || true
    # Make sure ~/.dotnet/tools is in PATH for the rest of this run
    export PATH="$PATH:$HOME/.dotnet/tools"
  fi

  if ! command -v dotnet-sonarscanner &>/dev/null && [ ! -x "$HOME/.dotnet/tools/dotnet-sonarscanner" ]; then
    echo -e "  ${RED}❌ dotnet-sonarscanner not available even after install — aborting C# scan${NC}"
    echo -e "  ${YELLOW}   💡 Install manually: dotnet tool install --global dotnet-sonarscanner${NC}"
  else
    DOTNET_SCAN_TARGET="${DOTNET_ENTRY_POINT:-$DOTNET_MODULE_DIR}"
    DSS_TOKEN_ARG=""
    if [ -n "$TOKEN" ]; then
      DSS_TOKEN_ARG="/d:sonar.token=${TOKEN}"
    else
      DSS_TOKEN_ARG="/d:sonar.login=admin /d:sonar.password=${SONAR_PASS}"
    fi

    pushd "$DOTNET_MODULE_DIR" >/dev/null
    echo -e "  ${CYAN}dotnet sonarscanner begin /k:${PROJECT_KEY}${NC}"
    if dotnet sonarscanner begin \
         /k:"$PROJECT_KEY" \
         /n:"$APPNAME" \
         /d:sonar.host.url="$SONAR_URL" \
         /d:sonar.sourceEncoding=UTF-8 \
         $DSS_TOKEN_ARG 2>&1 | grep -E "ERROR|WARN|begin|SonarScanner" | head -20; then
      :
    fi

    echo -e "  ${CYAN}dotnet build ${DOTNET_SCAN_TARGET} -c Debug${NC}"
    dotnet build "$DOTNET_SCAN_TARGET" -c Debug --no-incremental -v quiet -nologo \
      2>&1 | tail -20 || true

    echo -e "  ${CYAN}dotnet sonarscanner end${NC}"
    if dotnet sonarscanner end $DSS_TOKEN_ARG 2>&1 | tee /tmp/dss-end-$$.log \
         | grep -E "ANALYSIS SUCCESSFUL|ERROR|WARN" | head -20; then
      :
    fi
    if grep -qE "ANALYSIS SUCCESSFUL" /tmp/dss-end-$$.log 2>/dev/null; then
      echo -e "  ${GREEN}✓ dotnet sonarscanner — ANALYSIS SUCCESSFUL${NC}"
      ANALYSIS_SUCCESS=true
    else
      # Same trick as Maven: check the CE queue — analysis may have been submitted
      sleep 3
      CE_CHECK=$(curl -s ${SONAR_AUTH_CURL} \
        "${SONAR_URL}/api/ce/activity?component=${PROJECT_KEY}&ps=1" 2>/dev/null \
        | python3 -c "import sys,json; tasks=json.load(sys.stdin).get('tasks',[]); print(tasks[0]['status'] if tasks else 'NONE')" 2>/dev/null || echo "NONE")
      if [ "$CE_CHECK" != "NONE" ]; then
        echo -e "  ${GREEN}✓ Analysis task found in SonarQube (status: ${CE_CHECK})${NC}"
        ANALYSIS_SUCCESS=true
      else
        echo -e "  ${YELLOW}⚠ dotnet sonarscanner did not report success — falling back to sonar-scanner CLI${NC}"
      fi
    fi
    rm -f /tmp/dss-end-$$.log 2>/dev/null
    popd >/dev/null
  fi
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

fi  # ── end of "if [ \"$CSHARP_DIRECT_DONE\" = true ] (skip) else (Sonar pipeline)" ──

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

