#!/usr/bin/env bash
###############################################################################
#  Generate Green Score badge (SVG)
#  Usage: bash scripts/generate-badge.sh reports/latest-report.json badges/green-score.svg
###############################################################################
set -euo pipefail

REPORT_FILE=${1:-reports/latest-report.json}
OUT_FILE=${2:-badges/green-score.svg}

if [ ! -f "$REPORT_FILE" ]; then
  echo "Report not found: $REPORT_FILE" >&2
  exit 1
fi

SCORE_RAW=$(python3 -c "import sys,json;d=json.load(sys.stdin);r=d.get('report',d);print(r['green_score']['total'])" < "$REPORT_FILE")
# Ensure SCORE is always an integer (strip decimals if python outputs float)
SCORE=$(printf '%.0f' "$SCORE_RAW")
GRADE=$(python3 -c "import sys,json;d=json.load(sys.stdin);r=d.get('report',d);print(r['green_score']['grade'])" < "$REPORT_FILE")

# Color mapping by score (SCORE is guaranteed integer)
if [ "$SCORE" -ge 90 ]; then COLOR="#16a34a";
elif [ "$SCORE" -ge 80 ]; then COLOR="#22c55e";
elif [ "$SCORE" -ge 65 ]; then COLOR="#eab308";
elif [ "$SCORE" -ge 50 ]; then COLOR="#f97316";
else COLOR="#ef4444"; fi

LABEL="Green Score"
VALUE="${SCORE}/100 (${GRADE})"

# Simple SVG badge
cat > "$OUT_FILE" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="220" height="24" role="img" aria-label="${LABEL}: ${VALUE}">
  <title>${LABEL}: ${VALUE}</title>
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <rect rx="4" width="100" height="24" fill="#374151"/>
  <rect rx="4" x="100" width="120" height="24" fill="${COLOR}"/>
  <rect rx="4" width="220" height="24" fill="url(#s)"/>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11">
    <text x="50" y="16">${LABEL}</text>
    <text x="160" y="16">${VALUE}</text>
  </g>
</svg>
EOF

echo "Badge written to $OUT_FILE"
