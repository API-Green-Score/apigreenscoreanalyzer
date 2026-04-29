#!/usr/bin/env python3
"""
creedengo-cli-to-report.py
==========================
Converts the JSON output produced by the Creedengo .NET tool
(``creedengo-cli analyze <sln|csproj> out.json``) into the dashboard-compatible
``creedengo-report.json`` schema used by the rest of this project.

Why a dedicated converter?
--------------------------
The .NET tool (``Creedengo.Tool`` from the green-code-initiative) is the
**simplest, most reliable** way to run Creedengo C# analysis — no SonarQube
container, no Docker, no NuGet package edits in the target project. It writes
a flat JSON array of Roslyn ``DiagnosticInfo`` objects:

    [
      {
        "Directory": "/abs/path",
        "File":      "Foo.cs",
        "Location":  "Row 12, Column 3",
        "Severity":  "Warning",
        "Code":      "GCI69",
        "Message":   "Don't call loop invariant functions in loop conditions"
      },
      ...
    ]

Reference: https://github.com/green-code-initiative/creedengo-csharp
           src/Creedengo.Tool/Common/DiagnosticInfo.cs

The dashboard expects a much richer document (``creedengo_score`` with grade,
``rules_summary`` aggregated by rule key, ``severity_breakdown`` in Sonar
nomenclature, etc.). This script bridges the two.

Usage:
    python3 creedengo-cli-to-report.py \\
        --input  /tmp/creedengo-cli-out.json \\
        --output reports/creedengo-report.json \\
        --appname my-api \\
        --project /path/to/MySolution.sln \\
        [--tool-version 0.0.0]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

# Same grade thresholds as creedengo-extract-results.py for visual consistency
GRADE_THRESHOLDS = [(95, "A+"), (85, "A"), (70, "B"), (50, "C"), (30, "D"), (0, "E")]

# Roslyn DiagnosticSeverity → SonarQube severity (used by the dashboard)
ROSLYN_TO_SONAR_SEVERITY = {
    "error":   "CRITICAL",
    "warning": "MAJOR",
    "info":    "MINOR",
    "hidden":  "INFO",
}

# Rough effort estimate per severity (minutes) — aligned with Sonar defaults
EFFORT_MINUTES = {
    "BLOCKER":  10,
    "CRITICAL":  5,
    "MAJOR":     5,
    "MINOR":     2,
    "INFO":      1,
}


def categorize(rule_id: str, message: str) -> str:
    """Best-effort eco-design category from rule id + message keywords."""
    text = f"{rule_id} {message}".lower()
    if any(w in text for w in ("loop", "concat", "string", "regex", "linq", "where", "orderby")):
        return "cpu"
    if any(w in text for w in ("dispose", "async", "stream", "memory", "collection", "array")):
        return "memory"
    if any(w in text for w in ("gc.collect", "object", "alloc")):
        return "memory"
    if any(w in text for w in ("network", "http", "request")):
        return "network"
    if any(w in text for w in ("energy", "power")):
        return "energy"
    return "general"


def is_creedengo_rule(rule_id: str) -> bool:
    """Creedengo C# rules are prefixed ``GCI`` (Green Code Initiative)."""
    return rule_id.upper().startswith("GCI")


def compute_score(rules_violated: int, total_rules: int) -> tuple[int, str]:
    """Same formula as the SonarQube path: (1 − violated/total) * 100."""
    if total_rules <= 0:
        score = 100 if rules_violated == 0 else 0
    else:
        score = max(0, round((1 - rules_violated / total_rules) * 100))
    grade = "E"
    for threshold, g in GRADE_THRESHOLDS:
        if score >= threshold:
            grade = g
            break
    return score, grade


def fmt_effort(minutes: int) -> str:
    if minutes <= 0:
        return "0min"
    if minutes < 60:
        return f"{minutes}min"
    h, m = divmod(minutes, 60)
    return f"{h}h{m}min" if m else f"{h}h"


def parse_location(loc: str) -> tuple[int, int]:
    """Parse 'Row 12, Column 3' → (12, 3). Returns (0, 0) on failure."""
    line = col = 0
    if not loc:
        return 0, 0
    try:
        # Format: "Row {N}, Column {M}"
        parts = loc.replace(",", "").split()
        for i, w in enumerate(parts):
            if w.lower().startswith("row") and i + 1 < len(parts):
                line = int(parts[i + 1])
            elif w.lower().startswith("col") and i + 1 < len(parts):
                col = int(parts[i + 1])
    except (ValueError, IndexError):
        pass
    return line, col


def normalize_diag(d: Dict[str, Any]) -> Dict[str, Any]:
    """Be tolerant of casing variations (PascalCase or camelCase)."""
    def g(key: str, default: str = "") -> str:
        for k in (key, key.lower(), key[0].lower() + key[1:]):
            if k in d:
                return str(d[k] or "")
        return default
    return {
        "directory": g("Directory"),
        "file":      g("File"),
        "location":  g("Location"),
        "severity":  g("Severity"),
        "code":      g("Code"),
        "message":   g("Message"),
    }


def build_report(diagnostics: List[Dict[str, Any]],
                 appname: str,
                 project: str,
                 tool_version: str) -> Dict[str, Any]:
    diags = [normalize_diag(d) for d in diagnostics if isinstance(d, dict)]

    issues: List[Dict[str, Any]] = []
    sev_breakdown = {"BLOCKER": 0, "CRITICAL": 0, "MAJOR": 0, "MINOR": 0, "INFO": 0}
    rules_agg: Dict[str, Dict[str, Any]] = defaultdict(lambda: {
        "count": 0, "files": set(), "severity": "INFO",
        "name": "", "description": "", "category": "general", "type": "CODE_SMELL",
    })
    files_seen: set = set()
    effort_minutes = 0

    for d in diags:
        sev_roslyn = (d["severity"] or "info").lower()
        sev_sonar = ROSLYN_TO_SONAR_SEVERITY.get(sev_roslyn, "MINOR")
        sev_breakdown[sev_sonar] = sev_breakdown.get(sev_sonar, 0) + 1

        rule_id = d["code"] or "UNKNOWN"
        msg = d["message"] or ""
        cat = categorize(rule_id, msg)
        line, col = parse_location(d["location"])
        rel_file = os.path.join(d["directory"], d["file"]).replace("\\", "/") if d["directory"] else d["file"]

        files_seen.add(rel_file)
        effort_minutes += EFFORT_MINUTES.get(sev_sonar, 2)

        issues.append({
            "key":      f"{rule_id}-{len(issues)}",
            "rule":     rule_id,
            "severity": sev_sonar,
            "type":     "CODE_SMELL",
            "message":  msg,
            "component": rel_file,
            "line":     line,
            "column":   col,
            "category": cat,
            "engine":   "creedengo-cli",
        })

        agg = rules_agg[rule_id]
        agg["count"] += 1
        agg["files"].add(rel_file)
        # Keep the highest severity seen for this rule
        sev_order = {"BLOCKER": 0, "CRITICAL": 1, "MAJOR": 2, "MINOR": 3, "INFO": 4}
        if sev_order.get(sev_sonar, 9) < sev_order.get(agg["severity"], 9):
            agg["severity"] = sev_sonar
        # First message becomes the rule description (rough — Roslyn doesn't give per-rule metadata in JSON)
        if not agg["description"]:
            agg["description"] = msg
        if not agg["name"]:
            agg["name"] = msg.split(".")[0][:80] if msg else rule_id
        agg["category"] = cat

    # ── Aggregate rules_summary (sorted by severity then count) ──
    sev_rank = {"BLOCKER": 0, "CRITICAL": 1, "MAJOR": 2, "MINOR": 3, "INFO": 4}
    rules_summary: List[Dict[str, Any]] = []
    for rid, agg in rules_agg.items():
        rules_summary.append({
            "key":         rid,
            "name":        agg["name"] or rid,
            "description": agg["description"],
            "severity":    agg["severity"],
            "type":        agg["type"],
            "category":    agg["category"],
            "count":       agg["count"],
            "files":       sorted(agg["files"]),
            "creedengo":   is_creedengo_rule(rid),
        })
    rules_summary.sort(key=lambda r: (sev_rank.get(r["severity"], 9), -r["count"]))

    # ── Score: based ONLY on creedengo (GCI*) rules ratio ──
    creedengo_rules = [r for r in rules_summary if r["creedengo"]]
    rules_violated_creedengo = len(creedengo_rules)
    # Rough total: number of GCI rules currently published in creedengo-csharp (~15)
    # Pulled from README at the time of writing — bumped to 20 to be lenient.
    total_creedengo_rules = max(15, rules_violated_creedengo)
    score, grade = compute_score(rules_violated_creedengo, total_creedengo_rules)

    # ── Top files (by issue count) ──
    files_count: Dict[str, int] = defaultdict(int)
    for it in issues:
        files_count[it["component"]] += 1
    top_files = [{"file": f, "issues": c} for f, c in
                 sorted(files_count.items(), key=lambda kv: -kv[1])[:20]]

    # ── Categories breakdown ──
    cats_count: Dict[str, int] = defaultdict(int)
    for it in issues:
        cats_count[it["category"]] += 1
    categories = [{"category": k, "count": v} for k, v in
                  sorted(cats_count.items(), key=lambda kv: -kv[1])]

    return {
        "timestamp":   datetime.now(timezone.utc).isoformat(),
        "appname":     appname,
        "project":     project,
        "language":    "csharp",
        "analyzer":    "Creedengo.Tool (creedengo-cli)",
        "analyzer_version": tool_version or "unknown",
        "repos_analyzed": [project] if project else [],
        "creedengo_score": {
            "total":    score,
            "max":      100,
            "grade":    grade,
            "issues_count": len(issues),
            "severity_breakdown": sev_breakdown,
            "total_effort": fmt_effort(effort_minutes),
            "total_effort_minutes": effort_minutes,
        },
        "measures": {
            "ncloc":                0,   # creedengo-cli does not report SLOC
            "bugs":                 0,
            "vulnerabilities":      0,
            "code_smells":          len(issues),
            "complexity":           0,
            "cognitive_complexity": 0,
        },
        "rules_summary":          rules_summary,
        "categories":             categories,
        "top_files":              top_files,
        "issues":                 issues,
        "all_creedengo_rules":    total_creedengo_rules,
        "rules_violated":         rules_violated_creedengo,
        "sonar_issues":           {"issues_count": 0, "items": []},
        "detection":              {},     # filled in later by creedengo-analyzer.sh
    }


def main() -> int:
    p = argparse.ArgumentParser(description="Convert Creedengo .NET tool JSON to dashboard report")
    p.add_argument("--input",   required=True, help="Path to the JSON file produced by 'creedengo-cli analyze'")
    p.add_argument("--output",  required=True, help="Destination path for creedengo-report.json")
    p.add_argument("--appname", required=True, help="Application/project display name")
    p.add_argument("--project", default="",    help="Path to .sln/.slnx/.csproj that was analyzed")
    p.add_argument("--tool-version", default="", help="Creedengo.Tool version reported by 'dotnet tool list'")
    args = p.parse_args()

    in_path = Path(args.input)
    if not in_path.is_file():
        print(f"❌ Input file not found: {in_path}", file=sys.stderr)
        return 2

    try:
        raw = json.loads(in_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"❌ Failed to parse {in_path}: {e}", file=sys.stderr)
        return 3

    if not isinstance(raw, list):
        print(f"❌ Expected a top-level JSON array, got {type(raw).__name__}", file=sys.stderr)
        return 4

    report = build_report(raw, args.appname, args.project, args.tool_version)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"✓ Wrote {out_path}  "
          f"({len(report['issues'])} issues · {report['rules_violated']} rules · "
          f"score {report['creedengo_score']['total']}/100 · grade {report['creedengo_score']['grade']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

