#!/usr/bin/env bash
###############################################################################
#  🌱 SonarQube Quality Profile & Gate Setup for Creedengo
#  ========================================================
#  This script configures SonarQube BEFORE analysis:
#
#    1. Creates a quality profile "creedprofiles" (per language)
#       that EXTENDS the built-in "Sonar way" (parent inheritance).
#    2. Activates ALL available Creedengo eco-design rules in this profile.
#    3. Creates a quality gate "CreedGate" that copies conditions
#       from the default built-in gate and adds eco-design awareness.
#    4. Links the quality profile and quality gate to the target project.
#
#  Required environment variables (set by creedengo-analyzer.sh):
#    SONAR_URL          — SonarQube base URL (e.g. http://localhost:9100)
#    SONAR_AUTH_CURL    — curl auth flags   (e.g. "-u token:")
#    PROJECT_KEY        — SonarQube project key
#    ALL_SONAR_REPOS    — comma-separated repos  (e.g. creedengo-java,creedengo-python)
#    ALL_SONAR_LANGS    — comma-separated langs  (e.g. java,py)
#
#  Optional:
#    DEBUG_MODE         — "true" for verbose output
#    APPNAME            — project display name
#
#  Usage (standalone):
#    export SONAR_URL=http://localhost:9100
#    export SONAR_AUTH_CURL="-u admin:admin"
#    export PROJECT_KEY=esignpayment
#    export ALL_SONAR_REPOS=creedengo-java
#    export ALL_SONAR_LANGS=java
#    bash greenanalyzer/scripts/setup-sonar-quality.sh
#
#  Usage (from creedengo-analyzer.sh):
#    source "$SCRIPT_DIR/setup-sonar-quality.sh"
###############################################################################

# ── Colors ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Force Python UTF-8 output (if not already set by parent script) ──
export PYTHONIOENCODING=${PYTHONIOENCODING:-utf-8}

# ── Portable null device (if not already set by parent script) ──
if [ -z "${DEV_NULL:-}" ]; then
  if [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]]; then
    DEV_NULL="NUL"
  else
    DEV_NULL="/dev/null"
  fi
fi

# ── Portable curl HTTP code helper (if not already defined by parent script) ──
if ! declare -f curl_http_code &>/dev/null; then
  curl_http_code() {
    local _tmp
    _tmp=$(mktemp 2>/dev/null || echo "${TEMP:-/tmp}/_curl_$$")
    local _code
    _code=$(curl -s -o "$_tmp" -w "%{http_code}" "$@" 2>/dev/null) || _code="000"
    rm -f "$_tmp" 2>/dev/null
    echo "$_code"
  }
fi

# ── Validate required env vars ──
for var in SONAR_URL SONAR_AUTH_CURL PROJECT_KEY ALL_SONAR_REPOS ALL_SONAR_LANGS; do
  if [ -z "${!var:-}" ]; then
    echo -e "${RED}❌ Missing required env var: ${var}${NC}"
    exit 1
  fi
done

PROFILE_BASE_NAME="${QUALITY_PROFILE_NAME:-creedprofiles}"
GATE_NAME="${QUALITY_GATE_NAME:-CreedGate}"
DEBUG_MODE="${DEBUG_MODE:-false}"

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  📋  SonarQube Quality Profile & Gate Setup (pre-analysis)     ${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Give SonarQube a moment to finish indexing plugins/rules
sleep 3

###############################################################################
#  STEP 1 — Create quality profile "creedprofiles" extending "Sonar way"
###############################################################################
echo -e "${CYAN}── Step 1: Creating quality profile '${PROFILE_BASE_NAME}' per language ──${NC}"

IFS=',' read -ra REPOS_ARRAY <<< "$ALL_SONAR_REPOS"
IFS=',' read -ra LANGS_ARRAY <<< "$ALL_SONAR_LANGS"

# Track created profiles using dynamic variables (Bash 3 compatible)
# PROFILE_KEY_<lang> and PROFILE_NAME_<lang> will be set per language

for idx in "${!REPOS_ARRAY[@]}"; do
  repo="${REPOS_ARRAY[$idx]}"
  lang="${LANGS_ARRAY[$idx]}"
  [ -z "$repo" ] && continue

  PROFILE_NAME="${PROFILE_BASE_NAME}-${lang}"
  echo -e "  🔧 Language: ${CYAN}${lang}${NC}  Repo: ${CYAN}${repo}${NC}"

  # 1a. Count available Creedengo rules for this language
  RULE_COUNT=$(curl -s ${SONAR_AUTH_CURL} \
    "${SONAR_URL}/api/rules/search?repositories=${repo}&ps=1&languages=${lang}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "0")
  echo -e "     Creedengo rules available: ${CYAN}${RULE_COUNT}${NC}"

  if [ "$RULE_COUNT" -eq 0 ]; then
    echo -e "     ${YELLOW}⚠ No Creedengo rules found for ${repo} — plugin may not be loaded, skipping${NC}"
    continue
  fi

  # 1b. Find the built-in "Sonar way" profile key for this language
  BUILTIN_KEY=$(curl -s ${SONAR_AUTH_CURL} \
    "${SONAR_URL}/api/qualityprofiles/search?language=${lang}" 2>/dev/null \
    | python3 -c "
import sys,json
profiles = json.load(sys.stdin).get('profiles',[])
for p in profiles:
    if p.get('isBuiltIn', False):
        print(p['key'])
        break
" 2>/dev/null || echo "")

  BUILTIN_NAME=$(curl -s ${SONAR_AUTH_CURL} \
    "${SONAR_URL}/api/qualityprofiles/search?language=${lang}" 2>/dev/null \
    | python3 -c "
import sys,json
profiles = json.load(sys.stdin).get('profiles',[])
for p in profiles:
    if p.get('isBuiltIn', False):
        print(p['name'])
        break
" 2>/dev/null || echo "Sonar way")

  [ "$DEBUG_MODE" = true ] && echo -e "     Built-in profile: ${BUILTIN_NAME} (key: ${BUILTIN_KEY})"

  # 1c. Check if the profile already exists
  EXISTING_KEY=$(curl -s ${SONAR_AUTH_CURL} \
    "${SONAR_URL}/api/qualityprofiles/search?language=${lang}" 2>/dev/null \
    | python3 -c "
import sys,json
for p in json.load(sys.stdin).get('profiles',[]):
    if p.get('name','') == '${PROFILE_NAME}':
        print(p['key'])
        break
" 2>/dev/null || echo "")

  if [ -n "$EXISTING_KEY" ]; then
    echo -e "     ${GREEN}✓ Profile '${PROFILE_NAME}' already exists (key: ${EXISTING_KEY})${NC}"
    TARGET_PROFILE_KEY="$EXISTING_KEY"
  else
    # 1d. Create the new quality profile
    QP_CREATE_RESP=$(curl -s ${SONAR_AUTH_CURL} -X POST \
      "${SONAR_URL}/api/qualityprofiles/create" \
      -d "language=${lang}&name=${PROFILE_NAME}" 2>/dev/null || echo "{}")

    TARGET_PROFILE_KEY=$(echo "$QP_CREATE_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(d.get('profile',{}).get('key',''))
" 2>/dev/null || echo "")

    if [ -n "$TARGET_PROFILE_KEY" ]; then
      echo -e "     ${GREEN}✓ Quality profile '${PROFILE_NAME}' created (key: ${TARGET_PROFILE_KEY})${NC}"
    else
      echo -e "     ${RED}❌ Failed to create profile '${PROFILE_NAME}'${NC}"
      [ "$DEBUG_MODE" = true ] && echo -e "     Response: ${QP_CREATE_RESP}"
      continue
    fi

    # 1e. Set parent profile to "Sonar way" (inherits all default rules)
    if [ -n "$BUILTIN_KEY" ] && [ "$BUILTIN_KEY" != "$TARGET_PROFILE_KEY" ]; then
      PARENT_RESP=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
        "${SONAR_URL}/api/qualityprofiles/change_parent" \
        -d "qualityProfile=${PROFILE_NAME}&language=${lang}&parentQualityProfile=${BUILTIN_NAME}")

      if [ "$PARENT_RESP" = "204" ] || [ "$PARENT_RESP" = "200" ]; then
        echo -e "     ${GREEN}✓ Inherits from '${BUILTIN_NAME}' (extends default rules)${NC}"
      else
        echo -e "     ${YELLOW}⚠ Could not set parent (HTTP ${PARENT_RESP}) — trying URL-encoded name${NC}"
        # Retry with URL-encoded Sonar way
        curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
          "${SONAR_URL}/api/qualityprofiles/change_parent" \
          -d "qualityProfile=${PROFILE_NAME}&language=${lang}&parentQualityProfile=Sonar%20way" 2>/dev/null || true
      fi
    fi
  fi

  # Store for later use (dynamic vars, Bash 3 compatible)
  eval "PROFILE_KEY_${lang}=\"${TARGET_PROFILE_KEY}\""
  eval "PROFILE_NAME_${lang}=\"${PROFILE_NAME}\""
done

echo ""

###############################################################################
#  STEP 2 — Activate ALL Creedengo rules in "creedprofiles"
###############################################################################
echo -e "${CYAN}── Step 2: Activating all Creedengo rules in '${PROFILE_BASE_NAME}' ──${NC}"

for idx in "${!REPOS_ARRAY[@]}"; do
  repo="${REPOS_ARRAY[$idx]}"
  lang="${LANGS_ARRAY[$idx]}"
  [ -z "$repo" ] && continue

  TARGET_KEY=""; eval "TARGET_KEY=\${PROFILE_KEY_${lang}:-}"
  [ -z "$TARGET_KEY" ] && continue

  PROFILE_NAME=""; eval "PROFILE_NAME=\${PROFILE_NAME_${lang}:-}"

  # 2a. Bulk-activate all rules from the Creedengo repository
  ACTIVATE_RESP=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/qualityprofiles/activate_rules" \
    -d "targetKey=${TARGET_KEY}&repositories=${repo}")

  if [ "$ACTIVATE_RESP" = "200" ] || [ "$ACTIVATE_RESP" = "204" ]; then
    # Count how many rules are now active
    ACTIVE_COUNT=$(curl -s ${SONAR_AUTH_CURL} \
      "${SONAR_URL}/api/rules/search?repositories=${repo}&activation=true&qprofile=${TARGET_KEY}&ps=1" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "?")
    TOTAL_AVAIL=$(curl -s ${SONAR_AUTH_CURL} \
      "${SONAR_URL}/api/rules/search?repositories=${repo}&ps=1&languages=${lang}" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "?")
    echo -e "  ${GREEN}✓ ${lang}: ${ACTIVE_COUNT}/${TOTAL_AVAIL} Creedengo rules activated in '${PROFILE_NAME}'${NC}"
  else
    echo -e "  ${YELLOW}⚠ ${lang}: activate_rules returned HTTP ${ACTIVATE_RESP}${NC}"
    # Fallback: activate rules one by one
    echo -e "  ${CYAN}  → Trying individual rule activation...${NC}"
    RULE_KEYS=$(curl -s ${SONAR_AUTH_CURL} \
      "${SONAR_URL}/api/rules/search?repositories=${repo}&ps=500&languages=${lang}" 2>/dev/null \
      | python3 -c "
import sys,json
rules = json.load(sys.stdin).get('rules',[])
for r in rules:
    print(r['key'])
" 2>/dev/null || echo "")

    ACTIVATED=0
    while IFS= read -r rule_key; do
      [ -z "$rule_key" ] && continue
      R_RESP=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
        "${SONAR_URL}/api/qualityprofiles/activate_rule" \
        -d "key=${TARGET_KEY}&rule=${rule_key}")
      if [ "$R_RESP" = "200" ] || [ "$R_RESP" = "204" ]; then
        ACTIVATED=$((ACTIVATED + 1))
      fi
    done <<< "$RULE_KEYS"
    echo -e "  ${GREEN}✓ ${lang}: ${ACTIVATED} rules activated individually${NC}"
  fi
done

echo ""

###############################################################################
#  STEP 3 — Create quality gate "CreedGate" extending the default
###############################################################################
echo -e "${CYAN}── Step 3: Creating quality gate '${GATE_NAME}' (extends default) ──${NC}"

# 3a. Find the default (built-in) quality gate
DEFAULT_GATE_ID=$(curl -s ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/qualitygates/list" 2>/dev/null \
  | python3 -c "
import sys,json
data = json.load(sys.stdin)
gates = data.get('qualitygates', data.get('qualityGates', []))
for g in gates:
    if g.get('isDefault', False) or g.get('isBuiltIn', False):
        print(g.get('id', g.get('name','')))
        break
" 2>/dev/null || echo "")

DEFAULT_GATE_NAME=$(curl -s ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/qualitygates/list" 2>/dev/null \
  | python3 -c "
import sys,json
data = json.load(sys.stdin)
gates = data.get('qualitygates', data.get('qualityGates', []))
for g in gates:
    if g.get('isDefault', False) or g.get('isBuiltIn', False):
        print(g.get('name',''))
        break
" 2>/dev/null || echo "Sonar way")

echo -e "  Default quality gate: ${CYAN}${DEFAULT_GATE_NAME}${NC} (id: ${DEFAULT_GATE_ID})"

# 3b. Check if CreedGate already exists
EXISTING_GATE_ID=$(curl -s ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/qualitygates/list" 2>/dev/null \
  | python3 -c "
import sys,json
data = json.load(sys.stdin)
gates = data.get('qualitygates', data.get('qualityGates', []))
for g in gates:
    if g.get('name','') == '${GATE_NAME}':
        print(g.get('id',''))
        break
" 2>/dev/null || echo "")

if [ -n "$EXISTING_GATE_ID" ]; then
  echo -e "  ${GREEN}✓ Quality gate '${GATE_NAME}' already exists (id: ${EXISTING_GATE_ID})${NC}"
  CREED_GATE_ID="$EXISTING_GATE_ID"
else
  # 3c. Copy the default quality gate to create CreedGate
  #     SonarQube 10+ supports api/qualitygates/copy
  COPY_RESP=$(curl -s ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/qualitygates/copy" \
    -d "sourceName=${DEFAULT_GATE_NAME}&name=${GATE_NAME}" 2>/dev/null || echo "{}")

  CREED_GATE_ID=$(echo "$COPY_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(d.get('id', d.get('name','')))
" 2>/dev/null || echo "")

  if [ -n "$CREED_GATE_ID" ]; then
    echo -e "  ${GREEN}✓ Quality gate '${GATE_NAME}' created (copy of '${DEFAULT_GATE_NAME}')${NC}"
  else
    echo -e "  ${YELLOW}⚠ Copy failed — creating from scratch${NC}"
    # 3d. Fallback: create an empty gate and add default conditions
    CREATE_GATE_RESP=$(curl -s ${SONAR_AUTH_CURL} -X POST \
      "${SONAR_URL}/api/qualitygates/create" \
      -d "name=${GATE_NAME}" 2>/dev/null || echo "{}")

    CREED_GATE_ID=$(echo "$CREATE_GATE_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(d.get('id', d.get('name','')))
" 2>/dev/null || echo "")

    if [ -n "$CREED_GATE_ID" ]; then
      echo -e "  ${GREEN}✓ Quality gate '${GATE_NAME}' created (empty)${NC}"

      # Add standard conditions that mirror "Sonar way" defaults
      # These are the typical default quality gate conditions in SQ 10+
      declare -a DEFAULT_CONDITIONS=(
        "new_reliability_rating|1|LT"       # New Reliability Rating is A
        "new_security_rating|1|LT"          # New Security Rating is A
        "new_maintainability_rating|1|LT"   # New Maintainability Rating is A
        "new_coverage|80|LT"                # New Code Coverage >= 80%
        "new_duplicated_lines_density|3|GT"  # New Duplicated Lines <= 3%
        "new_security_hotspots_reviewed|100|LT"  # Security Hotspots Reviewed 100%
      )

      for cond in "${DEFAULT_CONDITIONS[@]}"; do
        IFS='|' read -r metric error op <<< "$cond"
        curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
          "${SONAR_URL}/api/qualitygates/create_condition" \
          -d "gateName=${GATE_NAME}&metric=${metric}&error=${error}&op=${op}" 2>/dev/null || true
      done
      echo -e "  ${GREEN}✓ Default conditions added to '${GATE_NAME}'${NC}"
    else
      echo -e "  ${RED}❌ Failed to create quality gate '${GATE_NAME}'${NC}"
      [ "$DEBUG_MODE" = true ] && echo -e "     Response: ${CREATE_GATE_RESP}"
    fi
  fi
fi

echo ""

###############################################################################
#  STEP 4 — Link quality profile and quality gate to the project
###############################################################################
echo -e "${CYAN}── Step 4: Linking profile & gate to project '${PROJECT_KEY}' ──${NC}"

# 4a. Set creedprofiles as default quality profile for each language
for idx in "${!REPOS_ARRAY[@]}"; do
  lang="${LANGS_ARRAY[$idx]}"
  [ -z "$lang" ] && continue

  TARGET_KEY=""; eval "TARGET_KEY=\${PROFILE_KEY_${lang}:-}"
  PROFILE_NAME=""; eval "PROFILE_NAME=\${PROFILE_NAME_${lang}:-}"
  [ -z "$TARGET_KEY" ] && continue

  # Set as default for the language (all new projects get this profile)
  DEFAULT_RESP=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/qualityprofiles/set_default" \
    -d "qualityProfile=${PROFILE_NAME}&language=${lang}")

  if [ "$DEFAULT_RESP" = "204" ] || [ "$DEFAULT_RESP" = "200" ]; then
    echo -e "  ${GREEN}✓ '${PROFILE_NAME}' set as DEFAULT quality profile for ${lang}${NC}"
  else
    echo -e "  ${YELLOW}⚠ set_default returned HTTP ${DEFAULT_RESP} for ${lang}${NC}"
  fi

  # Associate the profile explicitly with this project
  ASSOC_RESP=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/qualityprofiles/add_project" \
    -d "key=${TARGET_KEY}&project=${PROJECT_KEY}")

  if [ "$ASSOC_RESP" = "204" ] || [ "$ASSOC_RESP" = "200" ]; then
    echo -e "  ${GREEN}✓ '${PROFILE_NAME}' linked to project '${PROJECT_KEY}' (${lang})${NC}"
  else
    echo -e "  ${YELLOW}⚠ add_project returned HTTP ${ASSOC_RESP} — profile may already be linked${NC}"
  fi
done

# 4b. Set CreedGate as default quality gate (for all projects)
if [ -n "$CREED_GATE_ID" ]; then
  SET_DEFAULT_GATE=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/qualitygates/set_as_default" \
    -d "name=${GATE_NAME}")

  if [ "$SET_DEFAULT_GATE" = "204" ] || [ "$SET_DEFAULT_GATE" = "200" ]; then
    echo -e "  ${GREEN}✓ '${GATE_NAME}' set as DEFAULT quality gate${NC}"
  else
    echo -e "  ${YELLOW}⚠ set_as_default gate returned HTTP ${SET_DEFAULT_GATE}${NC}"
    # Retry with ID instead of name
    curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
      "${SONAR_URL}/api/qualitygates/set_as_default" \
      -d "id=${CREED_GATE_ID}" 2>/dev/null || true
  fi

  # 4c. Associate CreedGate with this specific project
  SELECT_GATE=$(curl_http_code ${SONAR_AUTH_CURL} -X POST \
    "${SONAR_URL}/api/qualitygates/select" \
    -d "gateName=${GATE_NAME}&projectKey=${PROJECT_KEY}")

  if [ "$SELECT_GATE" = "204" ] || [ "$SELECT_GATE" = "200" ]; then
    echo -e "  ${GREEN}✓ '${GATE_NAME}' linked to project '${PROJECT_KEY}'${NC}"
  else
    echo -e "  ${YELLOW}⚠ select gate returned HTTP ${SELECT_GATE}${NC}"
    # Retry with gateId parameter
    curl -s -o "$DEV_NULL" ${SONAR_AUTH_CURL} -X POST \
      "${SONAR_URL}/api/qualitygates/select" \
      -d "gateId=${CREED_GATE_ID}&projectKey=${PROJECT_KEY}" 2>/dev/null || true
  fi
fi

echo ""

###############################################################################
#  SUMMARY — Display final configuration
###############################################################################
echo -e "${YELLOW}━━━ ✅ Quality Configuration Summary ━━━${NC}"
echo ""

# Show quality profiles
echo -e "  ${CYAN}Quality Profiles:${NC}"
for lang in "${LANGS_ARRAY[@]}"; do
  [ -z "$lang" ] && continue
  PNAME="n/a"; eval "PNAME=\${PROFILE_NAME_${lang}:-n/a}"
  PKEY="n/a"; eval "PKEY=\${PROFILE_KEY_${lang}:-n/a}"
  echo -e "    ${lang}: ${GREEN}${PNAME}${NC} (extends Sonar way) → key: ${PKEY}"
done
echo ""

# Show quality gate
echo -e "  ${CYAN}Quality Gate:${NC}"
echo -e "    ${GREEN}${GATE_NAME}${NC} (extends ${DEFAULT_GATE_NAME}) → id: ${CREED_GATE_ID:-n/a}"
echo ""

# Show project association
echo -e "  ${CYAN}Project:${NC}"
echo -e "    ${GREEN}${PROJECT_KEY}${NC}"
echo -e "    → Quality profiles: ${PROFILE_BASE_NAME}-* (per language)"
echo -e "    → Quality gate:     ${GATE_NAME}"
echo ""

# Verify configuration via API
echo -e "  ${CYAN}Verification:${NC}"
PROJ_QP=$(curl -s ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/qualityprofiles/search?project=${PROJECT_KEY}" 2>/dev/null \
  | python3 -c "
import sys,json
profiles = json.load(sys.stdin).get('profiles',[])
for p in profiles:
    name = p.get('name','')
    lang = p.get('language','')
    active = p.get('activeRuleCount', 0)
    parent = p.get('parentName', 'none')
    print(f'    ✅ {name} ({lang}) — {active} rules active, parent: {parent}')
" 2>/dev/null || echo "    ⚠ Could not verify profiles")
echo -e "$PROJ_QP"

PROJ_QG=$(curl -s ${SONAR_AUTH_CURL} \
  "${SONAR_URL}/api/qualitygates/get_by_project?project=${PROJECT_KEY}" 2>/dev/null \
  | python3 -c "
import sys,json
d = json.load(sys.stdin)
qg = d.get('qualityGate', {})
print(f'    ✅ Gate: {qg.get(\"name\",\"?\")} (default: {qg.get(\"default\", False)})')
" 2>/dev/null || echo "    ⚠ Could not verify quality gate")
echo -e "$PROJ_QG"

echo ""
echo -e "${GREEN}━━━ 📋 Quality setup complete — ready for analysis ━━━${NC}"
echo ""

