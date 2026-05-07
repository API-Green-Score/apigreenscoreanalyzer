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
#    --git-repo <url>   Clone a remote Git repo, run Creedengo analysis on it,
#                       then return to the parent folder. Implies --creedengo.
#    --git-branch <b>   Branch/tag to checkout (default: repo default).
#    --git-subdir <p>   Analyze a sub-folder of the cloned repo.
#    --git-keep         Keep the cloned working copy after analysis.
#    --target  <url>          One API base URL to analyze. Repeat the flag to
#                              add several APIs.
#    --targets <csv>           Same as --target but accepts a comma-separated
#                              list, e.g. --targets http://a:8080,http://b:8082
#    --swagger  <url|file>     Explicit OpenAPI spec, paired with --target.
#                              Repeat or use --swaggers <csv>.
#    --swaggers <csv>          Comma-separated list of OpenAPI specs.
#
#    --consumer-region <ISO2>     ISO-3166 alpha-2 region of API consumers
#                                 (e.g. FR, US). Drives AR02 distance scoring.
#    --enable-geoip               Enable optional GeoIP lookup (ipinfo.io) for
#                                 AR02 anycast/ASN cross-validation.
#    --cloud-footprint-confirmed  Confirm that the cloud provider's carbon
#                                 dashboard is actively used (validates AR05).
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
CREEDENGO_EXTRA=()   # forwarded as-is to creedengo-analyzer.sh
STACK="auto"          # auto | java | dotnet — drives build/run + creedengo --lang
SOURCE_DIR=""         # local source folder for --build-and-run / --creedengo
BUILD_AND_RUN=false   # if true: build + start the API locally before health-checks
APP_PID=""            # PID of the locally-launched app (when --build-and-run)
APP_LOG=""            # log file of the locally-launched app

# AR02 Phase 3 / AR04 Phase 2 controls (forwarded to green-api-auto-discover.py)
CONSUMER_REGION="${CONSUMER_REGION:-}"   # ISO-3166 alpha-2 (e.g. FR, US) — AR02
ENABLE_GEOIP="${ENABLE_GEOIP:-false}"    # true → ipinfo.io lookup for AR02
CLOUD_FOOTPRINT_CONFIRMED="${CLOUD_FOOTPRINT_CONFIRMED:-false}"  # AR05 confirmation

# Git checkout (when --git-repo is provided): we clone the repo here in start.sh
# so the same working copy can drive --build-and-run AND be analyzed by Creedengo
# (no double clone, no local source needed on the user's machine).
GIT_REPO=""
GIT_BRANCH=""
GIT_SUBDIR=""
GIT_KEEP=false
GIT_CLONE_DIR=""          # filled in after we clone (cleaned at exit unless --git-keep)
SOURCE_DIR_FROM_GIT=false # true when SOURCE_DIR was derived from the clone
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
    --git-repo|--git-branch|--git-subdir)
      flag="${args[$i]}"
      i=$((i + 1))
      val="${args[$i]:-}"
      # Capture locally so start.sh can clone once and feed both --build-and-run
      # and Creedengo from the same working copy (no double clone).
      case "$flag" in
        --git-repo)   GIT_REPO="$val" ;;
        --git-branch) GIT_BRANCH="$val" ;;
        --git-subdir) GIT_SUBDIR="$val" ;;
      esac
      RUN_CREEDENGO=true   # implicit: --git-repo only makes sense for creedengo
      ;;
    --git-keep)
      GIT_KEEP=true
      RUN_CREEDENGO=true
      ;;
    --root)
      # Explicit project folder for Creedengo (defaults to CWD otherwise).
      i=$((i + 1))
      val="${args[$i]:-}"
      CREEDENGO_EXTRA+=("--root" "$val")
      ;;
    --stack)
      i=$((i + 1))
      STACK="${args[$i]:-auto}"
      ;;
    --stack=*)
      STACK="${args[$i]#--stack=}"
      ;;
    --source-dir)
      i=$((i + 1))
      SOURCE_DIR="${args[$i]:-}"
      ;;
    --source-dir=*)
      SOURCE_DIR="${args[$i]#--source-dir=}"
      ;;
    --consumer-region)
      i=$((i + 1))
      CONSUMER_REGION="${args[$i]:-}"
      ;;
    --consumer-region=*)
      CONSUMER_REGION="${args[$i]#--consumer-region=}"
      ;;
    --enable-geoip)
      ENABLE_GEOIP=true
      ;;
    --cloud-footprint-confirmed)
      CLOUD_FOOTPRINT_CONFIRMED=true
      ;;
    --build-and-run)
      BUILD_AND_RUN=true
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

###############################################################################
# Git checkout (single clone, shared by --build-and-run AND Creedengo)
#   When --git-repo is provided, clone the repo here once, then:
#     • use the working copy as SOURCE_DIR (unless --source-dir is explicit)
#     • forward it to Creedengo as --root (so Creedengo skips its own clone)
#   This avoids needing a local copy of the project and prevents double-clone.
###############################################################################
cleanup_git_clone() {
  if [ -n "${GIT_CLONE_DIR:-}" ] && [ "$GIT_KEEP" = false ] && [ -d "$GIT_CLONE_DIR" ]; then
    echo "🧹 Suppression du checkout temporaire : $GIT_CLONE_DIR"
    rm -rf "$GIT_CLONE_DIR" 2>/dev/null || true
  fi
}

if [ -n "$GIT_REPO" ]; then
  command -v git >/dev/null 2>&1 || { echo "❌ git requis pour --git-repo"; exit 1; }

  CHECKOUTS_DIR="$ROOT/.checkouts"
  # ── Purge previous checkouts so .checkouts/ never accumulates ─────────────
  # The checkout dir is supposed to hold ONE project at a time (the one we
  # are currently building / analyzing). If a previous run was killed before
  # cleanup, stale clones can pile up — clean them now.
  if [ -d "$CHECKOUTS_DIR" ]; then
    _stale=$(find "$CHECKOUTS_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
    if [ -n "$_stale" ]; then
      echo "🧹 Purge des checkouts précédents dans $CHECKOUTS_DIR/"
      rm -rf "$CHECKOUTS_DIR"/* "$CHECKOUTS_DIR"/.[!.]* "$CHECKOUTS_DIR"/..?* 2>/dev/null || true
    fi
  fi
  mkdir -p "$CHECKOUTS_DIR"
  repo_basename="$(basename "${GIT_REPO%.git}")"
  repo_slug="$(echo "$repo_basename" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/--*/-/g;s/^-//;s/-$//')"
  GIT_CLONE_DIR="$CHECKOUTS_DIR/${repo_slug}-$$"

  echo ""
  echo "📥 Clonage du repo Git (source unique pour build & analyse)"
  echo "   Repo   : $GIT_REPO"
  [ -n "$GIT_BRANCH" ] && echo "   Branch : $GIT_BRANCH"
  [ -n "$GIT_SUBDIR" ] && echo "   Subdir : $GIT_SUBDIR"
  echo "   Into   : $GIT_CLONE_DIR"

  CLONE_ARGS=(--depth 1)
  [ -n "$GIT_BRANCH" ] && CLONE_ARGS+=(--branch "$GIT_BRANCH")
  if ! git clone "${CLONE_ARGS[@]}" "$GIT_REPO" "$GIT_CLONE_DIR"; then
    echo "❌ git clone a échoué"
    exit 1
  fi

  # Resolve effective root inside the clone
  EFFECTIVE_CLONE_ROOT="$GIT_CLONE_DIR"
  if [ -n "$GIT_SUBDIR" ]; then
    if [ ! -d "$GIT_CLONE_DIR/$GIT_SUBDIR" ]; then
      echo "❌ --git-subdir '$GIT_SUBDIR' introuvable dans le repo cloné"
      exit 1
    fi
    EFFECTIVE_CLONE_ROOT="$GIT_CLONE_DIR/$GIT_SUBDIR"
  fi

  # Use the clone as SOURCE_DIR. If the user also passed --source-dir, the
  # clone wins by design (--git-repo is the explicit "no local source" mode).
  if [ -n "$SOURCE_DIR" ] && [ "$SOURCE_DIR" != "$EFFECTIVE_CLONE_ROOT" ]; then
    echo "⚠️  --source-dir '$SOURCE_DIR' ignoré : --git-repo a priorité (utilise le clone)"
  fi
  SOURCE_DIR="$EFFECTIVE_CLONE_ROOT"
  SOURCE_DIR_FROM_GIT=true
  echo "📂 --source-dir = $SOURCE_DIR (issu du clone)"

  # Pass --git-keep through to Creedengo only if requested. The clone path
  # itself is forwarded later via the standard SOURCE_DIR → --root translation.
  [ "$GIT_KEEP" = true ] && CREEDENGO_EXTRA+=("--git-keep")

  # Cleanup the temporary clone on exit unless --git-keep
  trap cleanup_git_clone EXIT INT TERM
fi

###############################################################################
# Stack auto-detection (when --stack auto + --source-dir is set)
###############################################################################
detect_stack_from_dir() {
  local dir="$1"
  if [ -z "$dir" ];   then echo "unknown"; return; fi
  if [ ! -d "$dir" ]; then echo "unknown"; return; fi

  # Java markers
  [ -f "$dir/pom.xml" ]            && { echo "java"; return; }
  [ -f "$dir/build.gradle" ]       && { echo "java"; return; }
  [ -f "$dir/build.gradle.kts" ]   && { echo "java"; return; }

  # .NET markers (classic .sln, new XML .slnx, or any .csproj at root or one level deep)
  shopt -s nullglob
  local matches=( "$dir"/*.sln "$dir"/*.slnx "$dir"/*.csproj "$dir"/*/*.csproj )
  shopt -u nullglob
  if [ ${#matches[@]} -gt 0 ]; then
    echo "dotnet"; return
  fi

  echo "unknown"
}

if [ "$STACK" = "auto" ] && [ -n "$SOURCE_DIR" ]; then
  DETECTED_STACK=$(detect_stack_from_dir "$SOURCE_DIR")
  if [ "$DETECTED_STACK" != "unknown" ]; then
    STACK="$DETECTED_STACK"
    echo "🔎 Stack auto-détecté: $STACK (depuis $SOURCE_DIR)"
  fi
fi

# Validate STACK
case "$STACK" in
  auto|java|dotnet) ;;
  *)
    echo "❌ --stack invalide: '$STACK' (attendu: auto | java | dotnet)"
    exit 1
    ;;
esac

# When SOURCE_DIR is provided, forward it as --root to the Creedengo analyzer
# and translate the stack into --lang for the analyzer's auto-detection override.
if [ -n "$SOURCE_DIR" ]; then
  if [ ! -d "$SOURCE_DIR" ]; then
    echo "❌ --source-dir introuvable: $SOURCE_DIR"
    exit 1
  fi
  SOURCE_DIR_ABS="$(cd "$SOURCE_DIR" && pwd)"
  CREEDENGO_EXTRA+=("--root" "$SOURCE_DIR_ABS")
fi
case "$STACK" in
  java)   CREEDENGO_EXTRA+=("--lang" "java") ;;
  dotnet) CREEDENGO_EXTRA+=("--lang" "csharp") ;;
esac

###############################################################################
# Build & run the API locally (--build-and-run)
#   Java Maven  → mvn spring-boot:run -Dserver.port=$PORT (background)
#   .NET 8+     → dotnet run --project <csproj> with ASPNETCORE_URLS=http://+:$PORT
#   The first --target URL drives the port; default 8080 if no targets given.
###############################################################################
extract_port_from_url() {
  local url="$1"
  echo "$url" | sed -E 's|^[a-z]+://[^:/]+:?([0-9]+)?.*|\1|;t;s|.*||' | head -1
}

cleanup_app() {
  if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
    echo ""
    echo "🧹 Arrêt de l'app locale (PID $APP_PID)..."
    kill -TERM "$APP_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$APP_PID" 2>/dev/null || true
  fi
}

if [ "$BUILD_AND_RUN" = true ]; then
  if [ -z "$SOURCE_DIR" ]; then
    echo "❌ --build-and-run requiert --source-dir <path>"
    exit 1
  fi
  if [ "$STACK" = "auto" ]; then
    DETECTED_STACK=$(detect_stack_from_dir "$SOURCE_DIR_ABS")
    [ "$DETECTED_STACK" != "unknown" ] && STACK="$DETECTED_STACK"
    if [ "$STACK" = "auto" ]; then
      echo "❌ Impossible d'auto-détecter le stack pour --build-and-run — précisez --stack java|dotnet"
      echo "   source-dir reçu : '$SOURCE_DIR_ABS'"
      echo "   Contenu :"
      ls -1 "$SOURCE_DIR_ABS" 2>/dev/null | sed 's/^/     /' | head -20
      echo "   Indices recherchés : pom.xml, build.gradle(.kts), *.sln, *.slnx, *.csproj, */*.csproj"
      echo "   ⚠️  Si votre chemin contient des espaces, pensez à le mettre entre guillemets :"
      echo "       --source-dir \"/path/with spaces/project\""
      exit 1
    fi
  fi

  # Determine the port the app must bind to.
  APP_PORT=""
  if [ ${#TARGETS[@]} -gt 0 ]; then
    APP_PORT=$(extract_port_from_url "${TARGETS[0]}")
  fi
  APP_PORT="${APP_PORT:-8080}"

  mkdir -p "$ROOT/reports"
  APP_LOG="$ROOT/reports/.app-run.log"
  # ── Purge previous run log so .app-run.log only contains the latest run ──
  # Also remove any rotated companion files (.app-run.log.1, .app-run.log.gz…)
  # that earlier runs may have left around.
  if [ -f "$APP_LOG" ] && [ -s "$APP_LOG" ]; then
    echo "🧹 Purge du log de la run précédente: $APP_LOG"
  fi
  : > "$APP_LOG"
  rm -f "$APP_LOG".[0-9]* "$APP_LOG".gz "$APP_LOG".old 2>/dev/null || true

  echo ""
  echo "🚀 Build & run local — stack=$STACK, source=$SOURCE_DIR_ABS, port=$APP_PORT"
  echo "   Logs applicatifs: $APP_LOG"

  case "$STACK" in
    java)
      # ── Resolve a usable Maven binary (mvn) ───────────────────────────────
      # Order:
      #   1) Maven Wrapper (./mvnw) shipped in the project — always preferred
      #      because it pins the exact Maven version the project was built with.
      #   2) System 'mvn' on PATH.
      #   3) Locally-installed Maven under $HOME/.maven/apache-maven-*/bin/mvn
      #      (cached from a previous run of this script).
      #   4) Offline backup at <repo>/.creedengo/.maven/apache-maven-*-bin.{tar.gz,zip}
      #      (operator-provided for air-gapped environments).
      #   5) Download from https://dlcdn.apache.org/maven/ as a last resort.
      MVN_BIN=""
      if [ -x "$SOURCE_DIR_ABS/mvnw" ]; then
        MVN_BIN="$SOURCE_DIR_ABS/mvnw"
        echo "✓ Maven Wrapper détecté: $MVN_BIN"
      elif command -v mvn >/dev/null 2>&1; then
        MVN_BIN="$(command -v mvn)"
      else
        # 3) cached local install
        MVN_LOCAL_ROOT="${MAVEN_LOCAL_ROOT:-$HOME/.maven}"
        mkdir -p "$MVN_LOCAL_ROOT"
        MVN_CACHED=$(ls -d "$MVN_LOCAL_ROOT"/apache-maven-*/bin/mvn 2>/dev/null | sort -V | tail -1)
        if [ -n "$MVN_CACHED" ] && [ -x "$MVN_CACHED" ]; then
          MVN_BIN="$MVN_CACHED"
          echo "✓ Maven trouvé en local: $MVN_BIN"
        else
          echo "⚠ 'mvn' introuvable — installation locale (sans sudo)..."
          # 4) offline backup
          _backup="$ROOT/.creedengo/.maven"
          if [ -d "$_backup" ]; then
            for archive in "$_backup"/apache-maven-*-bin.tar.gz "$_backup"/apache-maven-*-bin.zip; do
              [ -f "$archive" ] || continue
              echo "  📦 Extracting $(basename "$archive") → $MVN_LOCAL_ROOT"
              case "$archive" in
                *.tar.gz) tar -xzf "$archive" -C "$MVN_LOCAL_ROOT" 2>/dev/null && break ;;
                *.zip)    (cd "$MVN_LOCAL_ROOT" && unzip -q "$archive") 2>/dev/null && break ;;
              esac
            done
          fi
          # 5) online download from Apache
          MVN_CACHED=$(ls -d "$MVN_LOCAL_ROOT"/apache-maven-*/bin/mvn 2>/dev/null | sort -V | tail -1)
          if [ -z "$MVN_CACHED" ]; then
            MAVEN_VERSION="${MAVEN_VERSION:-3.9.9}"
            MAVEN_URL="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
            MAVEN_ARCHIVE="/tmp/apache-maven-${MAVEN_VERSION}-bin.tar.gz.$$"
            echo "  📥 Downloading $MAVEN_URL"
            if curl -fsSL "$MAVEN_URL" -o "$MAVEN_ARCHIVE" 2>/dev/null \
               || wget -qO "$MAVEN_ARCHIVE" "$MAVEN_URL" 2>/dev/null; then
              tar -xzf "$MAVEN_ARCHIVE" -C "$MVN_LOCAL_ROOT" 2>/dev/null
              rm -f "$MAVEN_ARCHIVE"
            else
              echo "  ⚠ Download échoué (réseau indisponible ?)"
              # Try Maven 3.8.8 as fallback (Apache mirrors keep older versions longer)
              MAVEN_FALLBACK_URL="https://archive.apache.org/dist/maven/maven-3/3.8.8/binaries/apache-maven-3.8.8-bin.tar.gz"
              MAVEN_ARCHIVE="/tmp/apache-maven-3.8.8-bin.tar.gz.$$"
              if curl -fsSL "$MAVEN_FALLBACK_URL" -o "$MAVEN_ARCHIVE" 2>/dev/null \
                 || wget -qO "$MAVEN_ARCHIVE" "$MAVEN_FALLBACK_URL" 2>/dev/null; then
                tar -xzf "$MAVEN_ARCHIVE" -C "$MVN_LOCAL_ROOT" 2>/dev/null
                rm -f "$MAVEN_ARCHIVE"
              fi
            fi
            MVN_CACHED=$(ls -d "$MVN_LOCAL_ROOT"/apache-maven-*/bin/mvn 2>/dev/null | sort -V | tail -1)
          fi
          if [ -n "$MVN_CACHED" ] && [ -x "$MVN_CACHED" ]; then
            MVN_BIN="$MVN_CACHED"
            export PATH="$(dirname "$MVN_BIN"):$PATH"
            export MAVEN_HOME="$(cd "$(dirname "$MVN_BIN")/.." && pwd)"
            echo "✓ Maven installé localement: $MVN_BIN"
            echo "  💡 MAVEN_HOME=$MAVEN_HOME"
          else
            echo "❌ Impossible d'installer Maven automatiquement"
            echo "   💡 Options:"
            echo "      • brew install maven   (macOS)"
            echo "      • apt-get install maven  (Debian/Ubuntu)"
            echo "      • Drop apache-maven-X.Y.Z-bin.tar.gz at $ROOT/.creedengo/.maven/"
            echo "      • Use the Maven Wrapper (./mvnw) shipped with your project"
            exit 1
          fi
        fi
      fi
      # ── JDK check (Maven needs a JDK, not just a JRE) ─────────────────────
      if ! command -v javac >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
        if command -v /usr/libexec/java_home >/dev/null 2>&1; then
          # macOS helper
          _jh=$(/usr/libexec/java_home 2>/dev/null || true)
          [ -n "$_jh" ] && export JAVA_HOME="$_jh" && export PATH="$JAVA_HOME/bin:$PATH"
        fi
      fi
      if ! command -v javac >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
        echo "⚠ JDK (javac) introuvable — Maven a besoin d'un JDK pour compiler."
        echo "   💡 Installe un JDK 17+ (recommandé):"
        echo "      • brew install --cask temurin"
        echo "      • apt-get install default-jdk"
        echo "      • https://adoptium.net/"
        # Non-fatal — older Maven may still work for `package` if classes are pre-compiled,
        # but spring-boot:run will fail. We continue and let mvn report a clearer error.
      fi

      # ── Lombok pre-flight (auto-patch in throwaway checkout) ──────────────
      # Many projects fail to compile with errors like:
      #   "cannot find symbol: method getXxx() / variable log"
      # because Lombok's annotation processor isn't running. Common bugs:
      #   1) Source uses @Data/@Slf4j/@Getter but the lombok dep is only
      #      listed under <dependencyManagement> in the parent pom — so the
      #      module never actually pulls it onto the build classpath.
      #   2) maven-compiler-plugin is pinned to an ancient version (<3.10)
      #      via <pluginManagement> in the parent pom; on JDK 17/21+ this
      #      either silently disables annotation processing or fails because
      #      the bundled processor doesn't understand the new javac API.
      # We work in a throwaway directory under `.checkouts/`, so we patch
      # any pom that needs it (non-destructive to the user's repo).
      LOMBOK_VERSION="${LOMBOK_VERSION:-1.18.34}"  # supports JDK 8..23+
      python3 - "$SOURCE_DIR_ABS" "$LOMBOK_VERSION" <<'PYEOF' || true
import os, re, sys, glob
ROOT, LVER = sys.argv[1], sys.argv[2]
LOMBOK_RE = re.compile(
    r'@Data\b|@Slf4j\b|@Getter\b|@Setter\b|@Builder\b|@Value\b|'
    r'@AllArgsConstructor\b|@NoArgsConstructor\b|@RequiredArgsConstructor\b|'
    r'@EqualsAndHashCode\b|^\s*import\s+lombok\.', re.M)

def src_uses_lombok(module_dir):
    src = os.path.join(module_dir, "src", "main", "java")
    if not os.path.isdir(src):
        return False
    for dirpath, _, files in os.walk(src):
        for fn in files:
            if not fn.endswith(".java"):
                continue
            try:
                with open(os.path.join(dirpath, fn), "r", encoding="utf-8", errors="ignore") as f:
                    if LOMBOK_RE.search(f.read()):
                        return True
            except Exception:
                pass
    return False

def has_real_lombok_dep(pom_text):
    """True only if pom has a <dependency> for lombok OUTSIDE
    <dependencyManagement>. <dependencyManagement> alone does NOT add it
    to the build classpath."""
    # Strip <dependencyManagement>...</dependencyManagement> blocks first.
    stripped = re.sub(
        r'<dependencyManagement>.*?</dependencyManagement>',
        '', pom_text, flags=re.DOTALL)
    return bool(re.search(
        r'<dependency>\s*(?:[^<]|<(?!/dependency>))*?'
        r'<artifactId>\s*lombok\s*</artifactId>',
        stripped, flags=re.DOTALL))

def inject_lombok_dep(pom_text, lver):
    dep = (
      '    <dependency>\n'
      '      <groupId>org.projectlombok</groupId>\n'
      '      <artifactId>lombok</artifactId>\n'
      f'      <version>{lver}</version>\n'
      '      <scope>provided</scope>\n'
      '      <optional>true</optional>\n'
      '    </dependency>\n'
    )
    # Insert into the FIRST top-level <dependencies> (not inside
    # <dependencyManagement>). We achieve this by stripping the management
    # block, finding the position of </dependencies>, and inserting there.
    # We then reconstruct the original around the management block.
    mgmt_match = re.search(
        r'<dependencyManagement>.*?</dependencyManagement>',
        pom_text, flags=re.DOTALL)
    if mgmt_match:
        before = pom_text[:mgmt_match.start()]
        mgmt = pom_text[mgmt_match.start():mgmt_match.end()]
        after = pom_text[mgmt_match.end():]
        target = before + after
    else:
        target = pom_text

    if re.search(r'</dependencies>', target):
        target2 = re.sub(r'(\s*</dependencies>)', dep + r'\1', target, count=1)
    else:
        block = (
          '\n  <dependencies>\n' + dep + '  </dependencies>\n'
        )
        target2 = re.sub(r'(\s*</project>)', block + r'\1', target, count=1)

    if mgmt_match:
        # We need to put the management block back where it was. The
        # easiest correct way: re-run the same replacement on the ORIGINAL
        # text. Since the strip+insert dance is hard to invert losslessly,
        # we just inject again into the original by finding a top-level
        # </dependencies> that is not inside <dependencyManagement>.
        # Walk forward and find the first </dependencies> at depth 0
        # of <dependencyManagement>.
        depth = 0
        i = 0
        while i < len(pom_text):
            if pom_text.startswith('<dependencyManagement>', i):
                depth += 1
                i += len('<dependencyManagement>')
                continue
            if pom_text.startswith('</dependencyManagement>', i):
                depth -= 1
                i += len('</dependencyManagement>')
                continue
            if depth == 0 and pom_text.startswith('</dependencies>', i):
                # Insert dep just before this token
                return pom_text[:i] + dep + pom_text[i:]
            i += 1
        # No top-level </dependencies> outside <dependencyManagement>:
        # add a fresh top-level <dependencies> block before </project>.
        block = (
          '\n  <dependencies>\n' + dep + '  </dependencies>\n'
        )
        return re.sub(r'(\s*</project>)', block + r'\1', pom_text, count=1)
    return target2

def patch_compiler_plugin(pom_text, lver):
    """Upgrade any maven-compiler-plugin pinned to <3.10 inside <plugin>
    or <pluginManagement>. Add annotationProcessorPaths for Lombok."""
    new_block = (
      '<plugin>\n'
      '        <groupId>org.apache.maven.plugins</groupId>\n'
      '        <artifactId>maven-compiler-plugin</artifactId>\n'
      '        <version>3.13.0</version>\n'
      '        <configuration>\n'
      '          <annotationProcessorPaths>\n'
      '            <path>\n'
      '              <groupId>org.projectlombok</groupId>\n'
      '              <artifactId>lombok</artifactId>\n'
      f'              <version>{lver}</version>\n'
      '            </path>\n'
      '          </annotationProcessorPaths>\n'
      '        </configuration>\n'
      '      </plugin>'
    )
    pattern = re.compile(
        r'<plugin>\s*'
        r'(?:<groupId>\s*org\.apache\.maven\.plugins\s*</groupId>\s*)?'
        r'<artifactId>\s*maven-compiler-plugin\s*</artifactId>'
        r'.*?</plugin>',
        flags=re.DOTALL)
    changed = False
    out = pom_text
    for m in list(pattern.finditer(pom_text)):
        block = m.group(0)
        ver_m = re.search(
            r'<version>\s*([0-9]+(?:\.[0-9]+){1,2})\s*</version>', block)
        if ver_m:
            major, minor = (int(p) for p in ver_m.group(1).split('.')[:2])
            too_old = (major < 3) or (major == 3 and minor < 10)
            if not too_old:
                # Already modern — but ensure annotationProcessorPaths has lombok
                if 'org.projectlombok' not in block:
                    if '<configuration>' in block:
                        block2 = re.sub(
                            r'<configuration>',
                            '<configuration>\n'
                            '          <annotationProcessorPaths>\n'
                            '            <path>\n'
                            '              <groupId>org.projectlombok</groupId>\n'
                            '              <artifactId>lombok</artifactId>\n'
                            f'              <version>{lver}</version>\n'
                            '            </path>\n'
                            '          </annotationProcessorPaths>',
                            block, count=1)
                    else:
                        block2 = block.replace(
                            '</plugin>',
                            '<configuration>\n'
                            '          <annotationProcessorPaths>\n'
                            '            <path>\n'
                            '              <groupId>org.projectlombok</groupId>\n'
                            '              <artifactId>lombok</artifactId>\n'
                            f'              <version>{lver}</version>\n'
                            '            </path>\n'
                            '          </annotationProcessorPaths>\n'
                            '        </configuration>\n'
                            '      </plugin>')
                    out = out.replace(block, block2, 1)
                    changed = True
                continue
        else:
            too_old = False  # No explicit version — leave it alone (parent / BOM controls it)
            continue
        if too_old:
            out = out.replace(block, new_block, 1)
            changed = True
    return out, changed

poms = sorted(glob.glob(os.path.join(ROOT, '**', 'pom.xml'), recursive=True))
poms = [p for p in poms if '/target/' not in p]
patched = []
for pom in poms:
    try:
        with open(pom, 'r', encoding='utf-8') as f:
            txt = f.read()
    except Exception:
        continue
    orig = txt
    module_dir = os.path.dirname(pom)
    needs_lombok_dep = src_uses_lombok(module_dir) and not has_real_lombok_dep(txt)
    if needs_lombok_dep:
        txt = inject_lombok_dep(txt, LVER)
        print(f"🔧 [{os.path.relpath(pom, ROOT)}] Lombok dep injectée (provided + optional)")
    txt2, compiler_changed = patch_compiler_plugin(txt, LVER)
    if compiler_changed:
        print(f"🔧 [{os.path.relpath(pom, ROOT)}] maven-compiler-plugin upgradé → 3.13.0 + annotationProcessorPaths(lombok)")
        txt = txt2
    if txt != orig:
        with open(pom, 'w', encoding='utf-8') as f:
            f.write(txt)
        patched.append(os.path.relpath(pom, ROOT))

if patched:
    print(f"✓ Patch Lombok appliqué sur {len(patched)} pom(s) dans la copie de travail")
else:
    print("ℹ Pas de patch Lombok nécessaire (rien à modifier)")
PYEOF

      # ── Resolve the runnable Maven module ─────────────────────────────────
      # If the root pom is an aggregator (<packaging>pom</packaging> or has
      # <modules>), the actual runnable Spring Boot app lives inside one of
      # the sub-modules — running mvn at the root would fail with
      # "Unable to find a single main class from the following candidates"
      # or build everything but produce no runnable artifact at the root.
      # We therefore:
      #   1) Detect aggregator poms.
      #   2) Enumerate sub-modules with src/main/java + a Spring Boot trace.
      #   3) Pick one based on, in order:
      #        - $JAVA_MODULE env var (exact module dir name match)
      #        - the module that contains spring-boot-maven-plugin or
      #          spring-boot-starter (preferred)
      #        - a single eligible sub-module
      #      otherwise abort with a list so the user can pin via JAVA_MODULE.
      RUN_DIR_ABS="$SOURCE_DIR_ABS"
      if grep -qE '<packaging>\s*pom\s*</packaging>|<modules>' "$SOURCE_DIR_ABS/pom.xml" 2>/dev/null; then
        RESOLVED_MODULE=$(python3 - "$SOURCE_DIR_ABS" "${JAVA_MODULE:-}" <<'PYEOF'
import os, re, sys, glob
ROOT, PIN = sys.argv[1], sys.argv[2]
SB_RE = re.compile(r'spring-boot-(starter|maven-plugin)|<artifactId>\s*spring-boot-starter[^<]*</artifactId>')

def has_spring_boot(pom_path):
    try:
        with open(pom_path, 'r', encoding='utf-8') as f:
            return bool(SB_RE.search(f.read()))
    except Exception:
        return False

def has_main_class(module_dir):
    src = os.path.join(module_dir, "src", "main", "java")
    if not os.path.isdir(src): return False
    for dirpath, _, files in os.walk(src):
        for fn in files:
            if not fn.endswith(".java"): continue
            try:
                with open(os.path.join(dirpath, fn), "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read()
                # Either a Spring Boot main class or any plain main(String[] args)
                if "@SpringBootApplication" in content:
                    return True
                if re.search(r'public\s+static\s+void\s+main\s*\(\s*String\s*(?:\[\s*\]|\.\.\.)\s*\w+', content):
                    return True
            except Exception:
                pass
    return False

candidates = []
for pom in sorted(glob.glob(os.path.join(ROOT, '*', 'pom.xml')) +
                  glob.glob(os.path.join(ROOT, '*', '*', 'pom.xml'))):
    module_dir = os.path.dirname(pom)
    if '/target/' in pom: continue
    if not os.path.isdir(os.path.join(module_dir, "src", "main", "java")): continue
    sb = has_spring_boot(pom)
    main = has_main_class(module_dir)
    candidates.append((module_dir, sb, main))

# Filter to runnable (has a main class) — prefer those with spring-boot trace.
runnable = [c for c in candidates if c[2]]
spring_boot = [c for c in runnable if c[1]]

picked = None
if PIN:
    for c in candidates:
        if os.path.basename(c[0]) == PIN or c[0].endswith('/' + PIN):
            picked = c[0]; break

if not picked:
    if len(spring_boot) == 1:
        picked = spring_boot[0][0]
    elif len(runnable) == 1:
        picked = runnable[0][0]
    elif spring_boot:
        # Multiple Spring Boot modules — prefer one with "optimized" or similar in name.
        for hint in ("optimized", "app", "api", "service", "main"):
            for c in spring_boot:
                if hint in os.path.basename(c[0]).lower():
                    picked = c[0]; break
            if picked: break
        if not picked:
            picked = spring_boot[0][0]

if picked:
    print(picked)
else:
    sys.stderr.write("❌ Aucun module Spring Boot exécutable trouvé sous " + ROOT + "\n")
    if candidates:
        sys.stderr.write("   Modules détectés:\n")
        for c in candidates:
            tags = []
            if c[1]: tags.append("spring-boot")
            if c[2]: tags.append("main()")
            tag = " [" + ",".join(tags) + "]" if tags else ""
            sys.stderr.write("     • " + os.path.relpath(c[0], ROOT) + tag + "\n")
        sys.stderr.write("   💡 Forcez le choix avec: JAVA_MODULE=<nom-du-module> ./scripts/start.sh …\n")
    sys.exit(2)
PYEOF
        ) || {
          echo "$RESOLVED_MODULE" >&2
          exit 1
        }
        if [ -n "$RESOLVED_MODULE" ] && [ -d "$RESOLVED_MODULE" ]; then
          RUN_DIR_ABS="$RESOLVED_MODULE"
          echo "📦 Module Maven détecté: $(basename "$RUN_DIR_ABS") ($(realpath --relative-to="$SOURCE_DIR_ABS" "$RUN_DIR_ABS" 2>/dev/null || echo "$RUN_DIR_ABS"))"
        fi
      fi

      # ── Build & run strategy ──────────────────────────────────────────────
      # Primary path: `mvn package` → `java -jar <module>/target/*.jar`.
      # The packaged jar is faster to launch, doesn't keep Maven resident in
      # memory, and gives us a clean process tree for the dashboard.
      # Fallback: if package fails (e.g. test compile errors, missing
      # spring-boot-maven-plugin repackage step) AND the pom looks like a
      # Spring Boot app, try `spring-boot:run` as a graceful degradation.
      echo "RUN_DIR=$RUN_DIR_ABS"
      JAR=""
      PACKAGE_OK=true
      if ( cd "$SOURCE_DIR_ABS" && "$MVN_BIN" -DskipTests \
             -pl ":$(basename "$RUN_DIR_ABS")" -am package >>"$APP_LOG" 2>&1 ); then
        echo "✓ Build réussi avec mvn package"
        # Prefer the Spring Boot fat jar over the *-sources/-javadoc/plain ones.
        JAR=$(ls "$RUN_DIR_ABS"/target/*.jar 2>/dev/null \
              | grep -v -E "(sources|javadoc|original)" \
              | head -1)
      else
        PACKAGE_OK=false
        echo "⚠ mvn package a échoué — voir $APP_LOG"
        # Lombok-flavored diagnostic — recognize the most common failure mode.
        if grep -qE "cannot find symbol" "$APP_LOG" 2>/dev/null && \
           grep -qE "method get[A-Z]|variable log\b" "$APP_LOG" 2>/dev/null; then
          echo ""
          echo "🔍 Diagnostic: le compilateur ne trouve pas les méthodes Lombok"
          echo "    (getXxx() / variable 'log' venant de @Slf4j, @Data, @Getter…)."
          echo "    → Le processeur d'annotations Lombok ne s'est pas exécuté."
          echo "    Causes possibles:"
          echo "      • Lombok absent des <dependency> du pom.xml du module."
          echo "      • maven-compiler-plugin trop ancien (<3.10) sur JDK 17/21+."
          echo "      • Lombok < 1.18.30 incompatible avec votre JDK."
          echo "    💡 Le script tente normalement un patch auto dans .checkouts/."
          echo "       Si vous voyez ce message, le patch n'a pas matché votre pom."
          echo "       Forcez la version Lombok avec: LOMBOK_VERSION=1.18.34 ./scripts/start.sh …"
          echo ""
        fi
      fi

      if [ "$PACKAGE_OK" = true ] && [ -n "$JAR" ]; then
        echo "🚀 Lancement: java -jar $JAR --server.port=$APP_PORT"
        ( nohup java -jar "$JAR" --server.port="$APP_PORT" >>"$APP_LOG" 2>&1 ) &
        APP_PID=$!
        echo "✓ App démarrée avec java -jar (PID $APP_PID)"
      else
        # Fallback to spring-boot:run only if the pom advertises it.
        if grep -q "spring-boot-starter" "$RUN_DIR_ABS/pom.xml" 2>/dev/null \
           || grep -q "spring-boot-maven-plugin" "$RUN_DIR_ABS/pom.xml" 2>/dev/null; then
          echo "⤵ Fallback: spring-boot:run (recompilation à chaud, Maven résident)"
          ( cd "$SOURCE_DIR_ABS" && \
            nohup "$MVN_BIN" -B -pl ":$(basename "$RUN_DIR_ABS")" -am spring-boot:run \
              -Dspring-boot.run.jvmArguments="-Dserver.port=$APP_PORT" \
              >>"$APP_LOG" 2>&1 ) &
          APP_PID=$!
          echo "✓ App démarrée avec spring-boot:run (PID $APP_PID)"
        else
          if [ "$PACKAGE_OK" = true ]; then
            echo "❌ Aucun .jar exécutable produit dans $RUN_DIR_ABS/target/"
          else
            echo "❌ mvn package a échoué et le module n'a pas spring-boot-* — abandon."
          fi
          exit 1
        fi
      fi
      ;;
    dotnet)
      # ── Ensure 'dotnet' SDK is available, auto-installing if missing ───────
      # Mirrors the .NET fast path in creedengo-analyzer.sh: prefer the
      # operator-provided offline backup at <repo>/.creedengo/.dotnet/*.pkg
      # (or *.tar.gz on Linux), otherwise fetch via the official
      # https://dot.net/v1/dotnet-install.sh script (no sudo needed).
      DOTNET_LOCAL_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
      mkdir -p "$DOTNET_LOCAL_ROOT"
      export PATH="$DOTNET_LOCAL_ROOT:$DOTNET_LOCAL_ROOT/tools:$HOME/.dotnet/tools:$PATH"
      export DOTNET_ROOT="$DOTNET_LOCAL_ROOT"
      export DOTNET_NOLOGO=1
      export DOTNET_CLI_TELEMETRY_OPTOUT=1
      [ -x "$DOTNET_LOCAL_ROOT/dotnet" ] && export DOTNET_HOST_PATH="$DOTNET_LOCAL_ROOT/dotnet"
      _arch="$(uname -m 2>/dev/null || echo)"
      case "$_arch" in
        arm64|aarch64) export DOTNET_ROOT_ARM64="$DOTNET_LOCAL_ROOT" ;;
        x86_64|amd64)  export DOTNET_ROOT_X64="$DOTNET_LOCAL_ROOT" ;;
      esac
      # net9.0 / net10.0 apphosts can refuse to run on a different major
      # without explicit roll-forward, so we set Major like the analyzer does.
      export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"

      if ! command -v dotnet >/dev/null 2>&1; then
        echo "⚠ 'dotnet' SDK introuvable — installation locale (sans sudo)..."
        _DOTNET_CHANNEL="${DOTNET_CHANNEL:-8.0}"
        _OS="$(uname -s 2>/dev/null || echo Unknown)"

        # 1) Online install via the official Microsoft script.
        case "$_OS" in
          Linux*|Darwin*|*BSD*)
            _installer="/tmp/dotnet-install-$$.sh"
            if curl -fsSL "https://dot.net/v1/dotnet-install.sh" -o "$_installer" 2>/dev/null \
               || wget -qO "$_installer" "https://dot.net/v1/dotnet-install.sh" 2>/dev/null; then
              chmod +x "$_installer"
              echo "  ⚙  bash $_installer --channel $_DOTNET_CHANNEL --install-dir $DOTNET_LOCAL_ROOT"
              bash "$_installer" --channel "$_DOTNET_CHANNEL" --install-dir "$DOTNET_LOCAL_ROOT" --no-path \
                 >/tmp/dotnet-install-$$.log 2>&1 || true
              rm -f "$_installer"
              # macOS Gatekeeper: strip quarantine + ad-hoc sign so the host launches.
              if [ "$_OS" = "Darwin" ]; then
                xattr -dr com.apple.quarantine "$DOTNET_LOCAL_ROOT" 2>/dev/null || true
                if [ -x "$DOTNET_LOCAL_ROOT/dotnet" ] && command -v codesign >/dev/null 2>&1; then
                  codesign --force --deep --sign - "$DOTNET_LOCAL_ROOT/dotnet" >/dev/null 2>&1 || true
                fi
              fi
            fi
            ;;
        esac

        # 2) Offline backup fallback at <repo>/.creedengo/.dotnet/{*.pkg,*.tar.gz}
        if ! command -v dotnet >/dev/null 2>&1; then
          echo "⚠ Online install échoué — tentative depuis le backup .creedengo/.dotnet/..."
          _backup="$ROOT/.creedengo/.dotnet"
          if [ -d "$_backup" ]; then
            for pkg in "$_backup"/dotnet-*.pkg "$_backup"/*.pkg; do
              [ -f "$pkg" ] || continue
              echo "  📦 Extracting $(basename "$pkg")"
              _tmp="$(mktemp -d /tmp/dotnet-pkg-XXXXX)"
              if pkgutil --expand-full "$pkg" "$_tmp/x" >/dev/null 2>&1; then
                find "$_tmp/x" -type d -name Payload | while read _P; do
                  if [ -d "$_P/usr/local/share/dotnet" ]; then
                    cp -R "$_P/usr/local/share/dotnet/." "$DOTNET_LOCAL_ROOT/" 2>/dev/null
                  elif [ -d "$_P/shared" ] || [ -d "$_P/host" ] || [ -d "$_P/sdk" ] || [ -f "$_P/dotnet" ]; then
                    cp -R "$_P/." "$DOTNET_LOCAL_ROOT/" 2>/dev/null
                  fi
                done
              fi
              rm -rf "$_tmp"
            done
            for tarball in "$_backup"/dotnet-*.tar.gz "$_backup"/*.tar.gz; do
              [ -f "$tarball" ] || continue
              echo "  📦 Extracting $(basename "$tarball")"
              tar -xzf "$tarball" -C "$DOTNET_LOCAL_ROOT" 2>/dev/null || true
            done
            if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
              xattr -dr com.apple.quarantine "$DOTNET_LOCAL_ROOT" 2>/dev/null || true
              [ -x "$DOTNET_LOCAL_ROOT/dotnet" ] && command -v codesign >/dev/null 2>&1 \
                && codesign --force --deep --sign - "$DOTNET_LOCAL_ROOT/dotnet" >/dev/null 2>&1 || true
            fi
          fi
        fi

        # Refresh DOTNET_HOST_PATH now that we may have a new binary.
        [ -x "$DOTNET_LOCAL_ROOT/dotnet" ] && export DOTNET_HOST_PATH="$DOTNET_LOCAL_ROOT/dotnet"

        if ! command -v dotnet >/dev/null 2>&1; then
          echo "❌ Impossible d'installer dotnet SDK $_DOTNET_CHANNEL automatiquement"
          echo "   💡 Options:"
          echo "      • brew install --cask dotnet-sdk"
          echo "      • curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel $_DOTNET_CHANNEL"
          echo "      • Drop a backup .pkg at $ROOT/.creedengo/.dotnet/"
          exit 1
        fi
        echo "✓ dotnet SDK installé localement: $(dotnet --version 2>/dev/null || echo '?')"
      fi
      # Prefer a .csproj (works reliably with `dotnet run --project`).
      # Fall back to .sln / .slnx if no csproj is found at root or one level deep.
      ENTRY=$(ls "$SOURCE_DIR_ABS"/*.csproj 2>/dev/null | head -1)
      if [ -z "$ENTRY" ]; then
        ENTRY=$(ls "$SOURCE_DIR_ABS"/*/*.csproj 2>/dev/null | head -1)
      fi
      if [ -z "$ENTRY" ]; then
        ENTRY=$(ls "$SOURCE_DIR_ABS"/*.sln "$SOURCE_DIR_ABS"/*.slnx 2>/dev/null | head -1)
      fi
      if [ -z "$ENTRY" ]; then
        echo "❌ Aucun .csproj / .sln / .slnx trouvé dans $SOURCE_DIR_ABS"; exit 1
      fi
      # Force HTTP-only binding to avoid the ASP.NET Core HTTPS dev cert prompt.
      export ASPNETCORE_URLS="http://+:$APP_PORT"
      export DOTNET_NOLOGO=1
      ( cd "$SOURCE_DIR_ABS" && \
        nohup dotnet run --project "$ENTRY" --no-launch-profile --urls "http://+:$APP_PORT" \
          >>"$APP_LOG" 2>&1 ) &
      APP_PID=$!
      ;;
  esac

  # Make sure the app is killed when start.sh exits / is interrupted
  trap cleanup_app EXIT INT TERM

  # Auto-add the launched URL to TARGETS if the user didn't provide any
  if [ ${#TARGETS[@]} -eq 0 ]; then
    TARGETS+=("http://localhost:$APP_PORT")
    echo "🎯 --target auto-renseigné: http://localhost:$APP_PORT"
  fi
  echo "   PID: $APP_PID"
  echo ""
fi

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

# ── AR02 / AR04 / AR05 propagation ──
# SOURCE_DIR is consumed by the wrapper to enable Phase 2 (AR04 IaC scan
# + AR01 broker-deps cross-validation) and is auto-derived from --git-repo
# clones. CONSUMER_REGION / ENABLE_GEOIP drive AR02 Phase 3 (anycast +
# distance-aware TLS latency). CLOUD_FOOTPRINT_CONFIRMED validates AR05.
if [ -n "${SOURCE_DIR:-}" ]; then
  export SOURCE_DIR
  echo "📂 Source dir (AR04/AR01 deps scan): $SOURCE_DIR"
fi
if [ -n "${CONSUMER_REGION:-}" ]; then
  export CONSUMER_REGION
  echo "🌍 Région consommateur (AR02): $CONSUMER_REGION"
fi
if [ "${ENABLE_GEOIP:-false}" = "true" ]; then
  export ENABLE_GEOIP=true
  echo "🛰️  GeoIP activé (AR02 anycast/ASN cross-check via ipinfo.io)"
fi
if [ "${CLOUD_FOOTPRINT_CONFIRMED:-false}" = "true" ]; then
  export CLOUD_FOOTPRINT_CONFIRMED=true
  echo "✅ Cloud footprint dashboard confirmé (AR05)"
fi
echo ""

# ── Build interactive-config.json from the OpenAPI specs (non-interactive) ──
# Mirrors the bridge's /api/discover + /api/analyze flow used by
# dashboard/interactive.html: discover the swagger of every target, extract
# the example payloads / path / query params declared in the spec, and
# persist:
#   - reports/interactive-config.json     → human-readable resolved config
#   - reports/.interactive-scenario.json  → analyzer-side scenario file
# The analyzer (green-api-auto-discover.py) honours the scenario when the
# GREEN_INTERACTIVE_SCENARIO env var points to it, so POST/PUT/PATCH bodies
# and {placeholder} path params come straight from the spec — no prompt.
if [ ${#TARGETS[@]} -gt 0 ]; then
  echo "🔎 Découverte swagger + extraction d'exemples (start.sh local mode)…"
  REPORTS_DIR="$ROOT/reports"
  mkdir -p "$REPORTS_DIR"
  BUILD_CFG_CMD=(python3 "$ROOT/scripts/build-interactive-config.py"
                 --targets "$TARGET_URL_JOINED"
                 --output-dir "$REPORTS_DIR"
                 --repeat 3)
  if [ -n "${BEARER_TOKEN:-}" ]; then
    BUILD_CFG_CMD+=(--bearer "$BEARER_TOKEN")
  fi
  if [ -n "${APPNAME:-}" ]; then
    BUILD_CFG_CMD+=(--appname "$APPNAME")
  fi
  if "${BUILD_CFG_CMD[@]}"; then
    INTERACTIVE_SCENARIO="$REPORTS_DIR/.interactive-scenario.json"
    if [ -f "$INTERACTIVE_SCENARIO" ]; then
      export GREEN_INTERACTIVE_SCENARIO="$INTERACTIVE_SCENARIO"
      echo "📥 Scénario interactif activé: $GREEN_INTERACTIVE_SCENARIO"
    fi
  else
    echo "⚠️  build-interactive-config a échoué — l'analyzer continuera sans scénario."
  fi
  echo ""
fi

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
  bash "$ROOT/scripts/creedengo-analyzer.sh" $DEBUG_FLAG --skip-build --no-cleanup --skip-dashboard ${CREEDENGO_EXTRA[@]+"${CREEDENGO_EXTRA[@]}"} || true
else
  echo ""
  echo "💡 Tip: run with --creedengo to also run Creedengo eco-design code analysis"
fi

###############################################################################
# Report paths (used by SobriIT + Dashboard)
###############################################################################
LATEST_REPORT="$ROOT/reports/latest-report.json"
CREEDENGO_REPORT="$ROOT/reports/creedengo-report.json"

###############################################################################
# SobriIT integration — send results if --send-to-sobriit is set
###############################################################################
if [ "$SEND_TO_SOBRIIT" = true ]; then
  echo ""
  echo "━━━ 📤 Sending results to SobriIT ━━━"
  SOBRIIT_CMD=(python3 "$ROOT/scripts/sobriit_sender.py"
               --appname "$APPNAME")
  [ -f "$LATEST_REPORT" ]   && SOBRIIT_CMD+=(--green-report "$LATEST_REPORT")
  [ -f "$CREEDENGO_REPORT" ] && SOBRIIT_CMD+=(--creedengo-report "$CREEDENGO_REPORT")
  if "${SOBRIIT_CMD[@]}"; then
    echo "✅ Results sent to SobriIT"
  else
    echo "⚠️  Failed to send results to SobriIT (non-blocking)"
  fi
fi

###############################################################################
# Dashboard generation — AFTER all analyses (green-score + creedengo)
###############################################################################
echo ""
echo "━━━ 📊 Generating final Dashboard ━━━"

if [ -f "$ROOT/scripts/generate-dashboard.sh" ] && [ -f "$LATEST_REPORT" ]; then
  DASHBOARD_ARGS=("$LATEST_REPORT" "$ROOT/dashboard/index.save.html" "$ROOT/dashboard/index.html")
  if [ -f "$CREEDENGO_REPORT" ]; then
    DASHBOARD_ARGS+=("$CREEDENGO_REPORT")
  fi
  bash "$ROOT/scripts/generate-dashboard.sh" "${DASHBOARD_ARGS[@]}" || true
  echo "✅ Dashboard generated: $ROOT/dashboard/index.html"
else
  echo "⚠️  No report found — dashboard not generated"
fi

# ── Attente de 10 minutes ou Ctrl+C avant nettoyage ──
SONAR_CONTAINER_FILE="$ROOT/.creedengo/.sonar-container-name"
# When driven by the interactive bridge (greenapianalyzer-server.py) we MUST
# NOT block on the 5-minute Ctrl+C countdown — the bridge needs the script to
# return so the dashboard can pick up the reports. Set INTERACTIVE_BRIDGE=1
# in the environment to skip the trailing wait + cleanup containers cleanly.
if [ "${INTERACTIVE_BRIDGE:-}" = "1" ]; then
  echo ""
  echo "ℹ️  INTERACTIVE_BRIDGE=1 → skipping the trailing SonarQube countdown."
  if [ "$RUN_CREEDENGO" = true ] && [ -f "$SONAR_CONTAINER_FILE" ]; then
    SONAR_CONTAINER=$(cat "$SONAR_CONTAINER_FILE" 2>/dev/null)
    source "$ROOT/scripts/_container-runtime.sh"
    if [ -n "${SONAR_CONTAINER:-}" ]; then
      $CONTAINER_RT rm -f "$SONAR_CONTAINER" 2>/dev/null || true
    fi
    for cid in $($CONTAINER_RT ps -aq --filter "name=creedengo-sonar" 2>/dev/null); do
      $CONTAINER_RT rm -f "$cid" 2>/dev/null || true
    done
    rm -f "$SONAR_CONTAINER_FILE" 2>/dev/null || true
  fi
  exit 0
fi

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
