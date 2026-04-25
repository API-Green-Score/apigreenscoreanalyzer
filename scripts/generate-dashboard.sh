#!/usr/bin/env bash
set -euo pipefail

GREEN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_FILE=${1:-"$GREEN_DIR/reports/latest-report.json"}
TEMPLATE_FILE=${2:-"$GREEN_DIR/dashboard/index.save.html"}
OUT_FILE=${3:-"$GREEN_DIR/dashboard/index.html"}
CREEDENGO_REPORT=${4:-"$GREEN_DIR/reports/creedengo-report.json"}

# Build optional args
EXTRA_ARGS=""
if [ -f "$CREEDENGO_REPORT" ]; then
  EXTRA_ARGS="--creedengo-report $CREEDENGO_REPORT"
fi

python3 "$GREEN_DIR/scripts/generate-dashboard.py" --report "$REPORT_FILE" --template "$TEMPLATE_FILE" --output "$OUT_FILE" $EXTRA_ARGS
