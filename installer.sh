#!/usr/bin/env bash
###############################################################################
#  🌿 Green Analyzer Installer
#  ============================
#  Clones a target repository, creates a feature branch, and copies the
#  Green API / Creedengo analysis tooling into it.
#
#  Usage:
#    bash greenanalyzer/installer.sh <git-repo-url>
#
#  Example:
#    bash greenanalyzer/installer.sh https://github.com/org/my-project.git
#    bash greenanalyzer/installer.sh git@github.com:org/my-project.git
###############################################################################
set -euo pipefail

# ── Colors ──
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GREEN_DIR="$(cd "$(dirname "$0")" && pwd)"
BRANCH_NAME="feat/greenanalyzer-int"

###############################################################################
# Validate arguments
###############################################################################
if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo -e "${RED}❌ Usage: bash greenanalyzer/installer.sh <git-repo-url>${NC}"
  echo -e "   Example: bash greenanalyzer/installer.sh https://github.com/org/my-project.git"
  exit 1
fi

REPO_URL="$1"

# Extract repo name from URL (handles both HTTPS and SSH formats)
REPO_NAME=$(basename "$REPO_URL" .git)
if [ -z "$REPO_NAME" ]; then
  echo -e "${RED}❌ Could not determine repository name from: $REPO_URL${NC}"
  exit 1
fi

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  🌿 Green Analyzer Installer                               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

###############################################################################
# Step 1 — Clone the repository
###############################################################################
echo -e "${YELLOW}━━━ 📥 Step 1: Cloning repository ━━━${NC}"
echo -e "  Repo: ${CYAN}${REPO_URL}${NC}"

if [ -d "$REPO_NAME" ]; then
  echo -e "  ${YELLOW}⚠ Directory '${REPO_NAME}' already exists — pulling latest instead${NC}"
  cd "$REPO_NAME"
  git pull --ff-only 2>/dev/null || true
else
  git clone "$REPO_URL"
  cd "$REPO_NAME"
fi

REPO_ROOT="$(pwd)"
echo -e "  ${GREEN}✅ Repository ready at: ${REPO_ROOT}${NC}"
echo ""

###############################################################################
# Step 2 — Create feature branch
###############################################################################
echo -e "${YELLOW}━━━ 🌿 Step 2: Creating branch '${BRANCH_NAME}' ━━━${NC}"

if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}" 2>/dev/null; then
  echo -e "  ${YELLOW}⚠ Branch '${BRANCH_NAME}' already exists locally — switching to it${NC}"
  git checkout "$BRANCH_NAME"
elif git show-ref --verify --quiet "refs/remotes/origin/${BRANCH_NAME}" 2>/dev/null; then
  echo -e "  ${YELLOW}⚠ Branch '${BRANCH_NAME}' exists on remote — checking out${NC}"
  git checkout -b "$BRANCH_NAME" "origin/${BRANCH_NAME}"
else
  git checkout -b "$BRANCH_NAME"
  echo -e "  ${GREEN}✅ Branch '${BRANCH_NAME}' created${NC}"
fi
echo ""

###############################################################################
# Step 3 — Copy Green Analyzer tooling into greenanalyzer/ folder
###############################################################################
echo -e "${YELLOW}━━━ 📦 Step 3: Copying Green Analyzer tooling ━━━${NC}"

TARGET_DIR="$REPO_ROOT/greenanalyzer"
mkdir -p "$TARGET_DIR"

# 3a — scripts/ folder (excluding unused/)
echo -e "  Copying ${CYAN}greenanalyzer/scripts/${NC} ..."
mkdir -p "$TARGET_DIR/scripts"
for item in "$GREEN_DIR/scripts/"*; do
  base="$(basename "$item")"
  if [ "$base" = "unused" ]; then
    continue
  fi
  cp -R "$item" "$TARGET_DIR/scripts/"
done
echo -e "  ${GREEN}✓ scripts/ copied${NC}"

# 3b — .spectral.yml
if [ -f "$GREEN_DIR/.spectral.yml" ]; then
  echo -e "  Copying ${CYAN}greenanalyzer/.spectral.yml${NC} ..."
  cp "$GREEN_DIR/.spectral.yml" "$TARGET_DIR/.spectral.yml"
  echo -e "  ${GREEN}✓ .spectral.yml copied${NC}"
fi

# 3c — green-score-threshold.json
if [ -f "$GREEN_DIR/green-score-threshold.json" ]; then
  echo -e "  Copying ${CYAN}greenanalyzer/green-score-threshold.json${NC} ..."
  cp "$GREEN_DIR/green-score-threshold.json" "$TARGET_DIR/green-score-threshold.json"
  echo -e "  ${GREEN}✓ green-score-threshold.json copied${NC}"
fi

# 3d — .creedengo/ folder (plugins + backup)
if [ -d "$GREEN_DIR/.creedengo" ]; then
  echo -e "  Copying ${CYAN}greenanalyzer/.creedengo/${NC} ..."
  cp -R "$GREEN_DIR/.creedengo" "$TARGET_DIR/.creedengo"
  echo -e "  ${GREEN}✓ .creedengo/ copied${NC}"
fi

# 3e — dashboard/ (HTML template + generated dashboard)
if [ -d "$GREEN_DIR/dashboard" ]; then
  echo -e "  Copying ${CYAN}greenanalyzer/dashboard/${NC} ..."
  mkdir -p "$TARGET_DIR/dashboard"
  cp -R "$GREEN_DIR/dashboard/"* "$TARGET_DIR/dashboard/" 2>/dev/null || true
  echo -e "  ${GREEN}✓ dashboard/ copied${NC}"
fi

# 3f — reports/ (generated reports)
echo -e "  Copying ${CYAN}greenanalyzer/reports/${NC} ..."
mkdir -p "$TARGET_DIR/reports"
if [ -d "$GREEN_DIR/reports" ] && [ "$(ls -A "$GREEN_DIR/reports" 2>/dev/null)" ]; then
  cp -R "$GREEN_DIR/reports/"* "$TARGET_DIR/reports/" 2>/dev/null || true
fi
echo -e "  ${GREEN}✓ reports/ copied${NC}"

# 3g — badges/ (SVG badges)
echo -e "  Copying ${CYAN}greenanalyzer/badges/${NC} ..."
mkdir -p "$TARGET_DIR/badges"
if [ -d "$GREEN_DIR/badges" ] && [ "$(ls -A "$GREEN_DIR/badges" 2>/dev/null)" ]; then
  cp -R "$GREEN_DIR/badges/"* "$TARGET_DIR/badges/" 2>/dev/null || true
fi
echo -e "  ${GREEN}✓ badges/ copied${NC}"

# 3h — .github/ folder → into greenanalyzer/ as reference + repo root for GitHub Actions
SOURCE_GITHUB="$(cd "$GREEN_DIR/.." && pwd)/.github"
if [ -d "$SOURCE_GITHUB" ]; then
  # Copy into greenanalyzer/ as reference
  echo -e "  Copying ${CYAN}greenanalyzer/.github/${NC} ..."
  mkdir -p "$TARGET_DIR/.github"
  cp -R "$SOURCE_GITHUB/"* "$TARGET_DIR/.github/"
  echo -e "  ${GREEN}✓ .github/ copied into greenanalyzer/${NC}"

  # Also copy to repo root (required by GitHub Actions)
  echo -e "  Copying ${CYAN}.github/${NC} to repo root ..."
  mkdir -p "$REPO_ROOT/.github"
  cp -R "$SOURCE_GITHUB/"* "$REPO_ROOT/.github/"
  echo -e "  ${GREEN}✓ .github/ copied to repo root${NC}"
fi

echo ""

###############################################################################
# Step 4 — Go to repo root
###############################################################################
echo -e "${YELLOW}━━━ 📂 Step 4: Ready at repository root ━━━${NC}"
cd "$REPO_ROOT"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ✅ Green Analyzer installed successfully!                  ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  📁 Repo:   ${GREEN}${REPO_ROOT}${NC}"
echo -e "${CYAN}║  🌿 Branch: ${GREEN}${BRANCH_NAME}${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}║  Files copied:                                             ║${NC}"
echo -e "${CYAN}║    📂 greenanalyzer/scripts/     (analysis & reporting)    ║${NC}"
echo -e "${CYAN}║    📂 greenanalyzer/dashboard/   (HTML dashboard)          ║${NC}"
echo -e "${CYAN}║    📂 greenanalyzer/reports/     (generated reports)       ║${NC}"
echo -e "${CYAN}║    📂 greenanalyzer/badges/      (SVG badges)             ║${NC}"
echo -e "${CYAN}║    📂 greenanalyzer/.creedengo/  (Creedengo plugins)      ║${NC}"
echo -e "${CYAN}║    📂 greenanalyzer/.github/     (CI pipeline reference)  ║${NC}"
echo -e "${CYAN}║    📄 greenanalyzer/.spectral.yml (OpenAPI linting rules) ║${NC}"
echo -e "${CYAN}║    📄 greenanalyzer/green-score-threshold.json (CI gate)  ║${NC}"
echo -e "${CYAN}║    📂 .github/workflows/         (CI pipeline — active)   ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  Next steps:                                               ║${NC}"
echo -e "${CYAN}║    1. Review & adapt .github/workflows/pr-green-api.yml    ║${NC}"
echo -e "${CYAN}║    2. git add -A && git commit -m '🌿 Add Green Analyzer'  ║${NC}"
echo -e "${CYAN}║    3. git push -u origin ${BRANCH_NAME}       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

