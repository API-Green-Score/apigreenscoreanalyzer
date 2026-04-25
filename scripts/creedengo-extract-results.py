#!/usr/bin/env python3
"""
🌱 Creedengo Results Extractor
================================
Extracts eco-design issues from SonarQube (with Creedengo plugin) via its Web API
and generates a JSON report compatible with the Green Score dashboard.

Usage:
    python3 creedengo-extract-results.py \
        --sonar-url http://localhost:9100 \
        --sonar-token <TOKEN> \
        --project-key esign-payment-backend \
        --output reports/creedengo-report.json
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
from urllib.parse import urlencode, quote
from base64 import b64encode


# ── Scoring model ──
# Score = (1 - rules_violated / total_rules) * 100
# Example: 6 violated out of 17 → (1 - 6/17) * 100 ≈ 65

GRADE_THRESHOLDS = [
    (95, "A+"),
    (85, "A"),
    (70, "B"),
    (50, "C"),
    (30, "D"),
    (0, "E"),
]

# ── Creedengo rule categories (eco-design concerns) ──
RULE_CATEGORIES = {
    "energy": "⚡ Consommation d'énergie",
    "memory": "💾 Utilisation mémoire",
    "cpu": "🖥️ Utilisation CPU",
    "network": "🌐 Transfert réseau",
    "storage": "💽 Stockage",
    "general": "🌱 Éco-conception générale",
}


def _api_get(base_url: str, path: str, params: dict = None,
             token: str = "", user: str = "", password: str = "",
             max_retries: int = 3, timeout: int = 90) -> dict:
    """Call SonarQube Web API and return JSON, with retry logic."""
    url = f"{base_url}{path}"
    if params:
        url += "?" + urlencode(params, quote_via=quote)

    req = Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    elif user:
        creds = b64encode(f"{user}:{password}".encode()).decode()
        req.add_header("Authorization", f"Basic {creds}")

    last_error = None
    for attempt in range(1, max_retries + 1):
        try:
            with urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())
        except HTTPError as e:
            body = e.read().decode() if hasattr(e, 'read') else ''
            last_error = e
            # Don't retry on 4xx client errors (except 408 Request Timeout)
            if 400 <= e.code < 500 and e.code != 408:
                print(f"  ⚠ API error {e.code} for {path}: {body[:200]}", file=sys.stderr)
                return {}
            print(f"  ⚠ API error {e.code} for {path} (attempt {attempt}/{max_retries})", file=sys.stderr)
        except (URLError, Exception) as e:
            last_error = e
            print(f"  ⚠ Connection error for {path} (attempt {attempt}/{max_retries}): {e}", file=sys.stderr)

        if attempt < max_retries:
            import time
            wait = 2 ** attempt  # exponential backoff: 2s, 4s, 8s
            print(f"    ↻ Retrying in {wait}s...", file=sys.stderr)
            time.sleep(wait)

    print(f"  ❌ Failed after {max_retries} attempts for {path}: {last_error}", file=sys.stderr)
    return {}


def compute_score(rules_violated: int, total_rules: int) -> tuple[int, str]:
    """Compute Creedengo score (0-100) and grade from violated/total rules ratio.

    Formula: (1 - rules_violated / total_rules) * 100
    Example: 6 violated out of 17 → (1 - 6/17) * 100 ≈ 64.71 → 65
    """
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


def categorize_rule(rule_key: str, rule_name: str, rule_desc: str) -> str:
    """Categorize a Creedengo rule into an eco-design concern."""
    text = f"{rule_key} {rule_name} {rule_desc}".lower()
    if any(w in text for w in ["loop", "concatenat", "stringbuilder", "regex", "cpu", "autobox"]):
        return "cpu"
    if any(w in text for w in ["memory", "object", "collection", "array", "resource", "close", "cursor"]):
        return "memory"
    if any(w in text for w in ["sql", "query", "database", "request"]):
        return "storage"
    if any(w in text for w in ["network", "http", "download", "transfer"]):
        return "network"
    if any(w in text for w in ["energy", "power", "battery"]):
        return "energy"
    return "general"


def _is_creedengo_rule(rule_key: str, repo_list: list[str]) -> bool:
    """Return True if the rule key belongs to a Creedengo/ecoCode repository."""
    creedengo_prefixes = tuple(f"{r}:" for r in repo_list)
    ecocode_prefixes = tuple(f"ecocode-{r.replace('creedengo-', '')}:" for r in repo_list)
    return rule_key.startswith(creedengo_prefixes + ecocode_prefixes)


def _parse_effort(effort: str) -> int:
    """Parse SonarQube effort string ('5min', '1h', '1h30min') to minutes."""
    if not effort:
        return 0
    mins = 0
    if "h" in effort:
        parts = effort.split("h")
        mins += int(parts[0]) * 60
        rest = parts[1].replace("min", "").strip()
        if rest:
            mins += int(rest)
    elif "min" in effort:
        mins += int(effort.replace("min", "").strip())
    return mins


def _effort_str(total_minutes: int) -> str:
    """Format total minutes as human-readable effort string."""
    if total_minutes >= 60:
        return f"{total_minutes // 60}h{total_minutes % 60:02d}min"
    return f"{total_minutes}min"


def extract_results(sonar_url: str, project_key: str,
                    token: str = "", user: str = "", password: str = "",
                    appname: str = "", language: str = "java",
                    sonar_repos: str = "") -> dict:
    """Extract Creedengo analysis results from SonarQube."""
    import time

    auth = dict(token=token, user=user, password=password)

    # ── Wait for CE task to be fully complete before extracting ──
    print("  ⏳ Checking analysis task status...")
    ce_timeout = 300
    ce_elapsed = 0
    while ce_elapsed < ce_timeout:
        ce_data = _api_get(sonar_url, "/api/ce/activity",
                           {"component": project_key, "ps": "1"}, **auth)
        tasks = ce_data.get("tasks", [])
        if tasks:
            ce_status = tasks[0].get("status", "PENDING")
        else:
            ce_data2 = _api_get(sonar_url, "/api/ce/component",
                                {"component": project_key}, **auth)
            ce_status = ce_data2.get("current", {}).get("status", "") if ce_data2 else ""
            if not ce_status:
                ce_status = "NO_TASK"
        if ce_status == "SUCCESS":
            print(f"  ✅ Analysis task complete ({ce_elapsed}s)")
            break
        elif ce_status == "FAILED":
            print(f"  ⚠ Analysis task failed — extracting whatever is available")
            break
        elif ce_status in ("PENDING", "IN_PROGRESS"):
            if ce_elapsed % 15 == 0:
                print(f"    ... waiting for analysis ({ce_elapsed}s/{ce_timeout}s, status: {ce_status})")
            time.sleep(3)
            ce_elapsed += 3
        elif ce_status == "NO_TASK":
            print(f"  ⚠ No analysis task found — analysis may not have been submitted")
            break
        else:
            print(f"  ⚠ CE status: {ce_status} — proceeding with extraction")
            break
    if ce_elapsed >= ce_timeout:
        print(f"  ⚠ Timeout waiting for CE task ({ce_timeout}s) — extracting partial results")

    # Determine which repositories to query (multi-language support)
    repo_list = [r.strip() for r in sonar_repos.split(",") if r.strip()] if sonar_repos else [f"creedengo-{language}"]

    # ── Step 1: Fetch all rule KEYS from each Creedengo repository ──
    print("  📋 Fetching Creedengo rule keys from repositories...")
    repo_rule_keys: dict[str, list[str]] = {}
    for repo in repo_list:
        rules_data = _api_get(sonar_url, "/api/rules/search", {
            "repositories": repo,
            "ps": 500,
        }, **auth)
        keys = [r["key"] for r in rules_data.get("rules", [])]
        repo_rule_keys[repo] = keys
        if keys:
            print(f"    {repo}: {len(keys)} rules found")
        else:
            print(f"    {repo}: no rules found (plugin may not be loaded)")

    # ── Step 2: Fetch Creedengo issues using actual rule keys ──
    print("  📋 Fetching Creedengo issues...")
    creedengo_issues_raw = []
    for repo in repo_list:
        rule_keys = repo_rule_keys.get(repo, [])
        if not rule_keys:
            print(f"    {repo}: no rules to query")
            continue

        batch_size = 20
        for i in range(0, len(rule_keys), batch_size):
            batch = rule_keys[i:i + batch_size]
            rules_param = ",".join(batch)
            page = 1
            while True:
                data = _api_get(sonar_url, "/api/issues/search", {
                    "componentKeys": project_key,
                    "rules": rules_param,
                    "ps": 500,
                    "p": page,
                    "resolved": "false",
                }, **auth)
                issues_page = data.get("issues", [])
                creedengo_issues_raw.extend(issues_page)
                total = data.get("total", 0)
                if len(issues_page) == 0 or page * 500 >= total:
                    break
                page += 1

        repo_issue_count = sum(1 for iss in creedengo_issues_raw if iss.get("rule", "").startswith(f"{repo}:"))
        if repo_issue_count > 0:
            print(f"    {repo}: {repo_issue_count} issues")

    print(f"  Found {len(creedengo_issues_raw)} Creedengo-specific issues")

    # ── Step 2b: Also fetch ALL project issues (for the general SonarQube context) ──
    print("  📋 Fetching all project issues (for general SonarQube context)...")
    all_project_issues_raw = []
    page = 1
    while True:
        data = _api_get(sonar_url, "/api/issues/search", {
            "componentKeys": project_key,
            "ps": 500,
            "p": page,
            "resolved": "false",
        }, **auth)
        page_issues = data.get("issues", [])
        all_project_issues_raw.extend(page_issues)
        total = data.get("total", 0)
        if not page_issues or page * 500 >= total:
            break
        page += 1
    print(f"  Found {len(all_project_issues_raw)} total project issues")

    # ── Step 2c: If no creedengo-specific issues found via rule keys, try broad filter ──
    if not creedengo_issues_raw:
        print("  📋 No Creedengo issues via rule filter. Filtering broad results...")
        creedengo_prefixes = tuple(f"{r}:" for r in repo_list)
        ecocode_prefixes = tuple(f"ecocode-{r.replace('creedengo-', '')}:" for r in repo_list)
        all_prefixes = creedengo_prefixes + ecocode_prefixes
        creedengo_issues_raw = [
            i for i in all_project_issues_raw
            if i.get("rule", "").startswith(all_prefixes)
        ]
        if creedengo_issues_raw:
            print(f"  Found {len(creedengo_issues_raw)} Creedengo issues from broad search")
        else:
            print(f"  ⚠ No Creedengo/ecodesign rule violations found (0 issues)")

    # ── Separate general SonarQube issues (non-Creedengo) ──
    creedengo_rule_keys_set = {i.get("rule", "") for i in creedengo_issues_raw}
    sonar_only_issues_raw = [
        i for i in all_project_issues_raw
        if not _is_creedengo_rule(i.get("rule", ""), repo_list)
    ]
    print(f"  Separated: {len(creedengo_issues_raw)} Creedengo | {len(sonar_only_issues_raw)} SonarQube general")

    # ── Fetch Creedengo rules metadata ──
    print("  📋 Fetching rule definitions...")
    rules_meta = {}
    for repo in repo_list:
        rules_data = _api_get(sonar_url, "/api/rules/search", {
            "repositories": repo,
            "ps": 500,
        }, **auth)
        for rule in rules_data.get("rules", []):
            rules_meta[rule["key"]] = {
                "name": rule.get("name", ""),
                "severity": rule.get("severity", "INFO"),
                "type": rule.get("type", "CODE_SMELL"),
                "htmlDesc": rule.get("htmlDesc", ""),
                "tags": rule.get("tags", []),
            }
        rule_count = rules_data.get("total", 0)
        if rule_count > 0:
            print(f"    {repo}: {rule_count} rules defined")
        else:
            print(f"    {repo}: 0 rules defined — plugin may not be loaded")

    # ── Fetch project measures ──
    print("  📋 Fetching project measures...")
    measures_data = _api_get(sonar_url, "/api/measures/component", {
        "component": project_key,
        "metricKeys": "ncloc,bugs,vulnerabilities,code_smells,complexity,cognitive_complexity",
    }, **auth)
    measures = {}
    for m in measures_data.get("component", {}).get("measures", []):
        measures[m["metric"]] = m.get("value", "0")

    # ═══════════════════════════════════════════════════════════════
    # Helper: build structured issue list + aggregations from raw issues
    # ═══════════════════════════════════════════════════════════════
    def _build_issue_data(raw_issues: list[dict]) -> tuple:
        """Returns (issues_list, severity_counts, rules_agg, files_count, effort_min)."""
        issues_out = []
        sev = {"BLOCKER": 0, "CRITICAL": 0, "MAJOR": 0, "MINOR": 0, "INFO": 0}
        rules_agg: dict[str, dict] = {}
        files_cnt: dict[str, int] = {}
        effort = 0

        for issue in raw_issues:
            rule_key = issue.get("rule", "")
            severity = issue.get("severity", "INFO")
            component = issue.get("component", "")
            file_path = component.replace(f"{project_key}:", "")

            entry = {
                "rule": rule_key,
                "severity": severity,
                "message": issue.get("message", ""),
                "file": file_path,
                "line": issue.get("line", 0),
                "effort": issue.get("effort", ""),
                "type": issue.get("type", "CODE_SMELL"),
            }
            issues_out.append(entry)
            sev[severity] = sev.get(severity, 0) + 1
            files_cnt[file_path] = files_cnt.get(file_path, 0) + 1
            effort += _parse_effort(entry["effort"])

            if rule_key not in rules_agg:
                meta = rules_meta.get(rule_key, {})
                rules_agg[rule_key] = {
                    "key": rule_key,
                    "name": meta.get("name", rule_key.split(":")[-1] if ":" in rule_key else rule_key),
                    "severity": severity,
                    "type": issue.get("type", "CODE_SMELL"),
                    "description": meta.get("htmlDesc", "")[:300],
                    "category": categorize_rule(rule_key, meta.get("name", ""), meta.get("htmlDesc", "")),
                    "count": 0,
                    "files": [],
                }
            rules_agg[rule_key]["count"] += 1
            if file_path not in rules_agg[rule_key]["files"]:
                rules_agg[rule_key]["files"].append(file_path)

        return issues_out, sev, rules_agg, files_cnt, effort

    # ── Build Creedengo-only data (for main score & recap) ──
    cr_issues, cr_sev, cr_rules, cr_files, cr_effort = _build_issue_data(creedengo_issues_raw)

    # ── Build SonarQube-general data (context, separate section) ──
    sq_issues, sq_sev, sq_rules, sq_files, sq_effort = _build_issue_data(sonar_only_issues_raw)

    # ── Compute score based on CREEDENGO rules ratio ──
    # Formula: (1 - rules_violated / total_rules) * 100
    total_creedengo_rules = len(rules_meta)
    violated_creedengo_rules = len(cr_rules)
    score, grade = compute_score(violated_creedengo_rules, total_creedengo_rules)

    # ── Build category summary (Creedengo only) ──
    category_summary = {}
    for rule_data in cr_rules.values():
        cat = rule_data["category"]
        if cat not in category_summary:
            category_summary[cat] = {
                "key": cat,
                "label": RULE_CATEGORIES.get(cat, cat),
                "issues_count": 0,
                "rules_count": 0,
            }
        category_summary[cat]["issues_count"] += rule_data["count"]
        category_summary[cat]["rules_count"] += 1

    # ── Top files (Creedengo only) ──
    cr_top_files = sorted(cr_files.items(), key=lambda x: -x[1])[:20]

    # ── Assemble report ──
    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "appname": appname,
        "project": project_key,
        "language": language,
        "analyzer": "creedengo",
        "analyzer_version": "SonarQube + Creedengo Plugin",
        "repos_analyzed": repo_list,
        # ── Main score: Creedengo/ecodesign rules ONLY ──
        "creedengo_score": {
            "total": score,
            "max": 100,
            "grade": grade,
            "issues_count": len(cr_issues),
            "severity_breakdown": cr_sev,
            "total_effort": _effort_str(cr_effort),
            "total_effort_minutes": cr_effort,
        },
        "measures": {
            "ncloc": int(measures.get("ncloc", 0)),
            "bugs": int(measures.get("bugs", 0)),
            "vulnerabilities": int(measures.get("vulnerabilities", 0)),
            "code_smells": int(measures.get("code_smells", 0)),
            "complexity": int(measures.get("complexity", 0)),
            "cognitive_complexity": int(measures.get("cognitive_complexity", 0)),
        },
        # ── Creedengo rules only ──
        "rules_summary": sorted(
            list(cr_rules.values()),
            key=lambda r: (
                {"BLOCKER": 0, "CRITICAL": 1, "MAJOR": 2, "MINOR": 3, "INFO": 4}.get(r["severity"], 5),
                -r["count"],
            ),
        ),
        "categories": sorted(
            list(category_summary.values()),
            key=lambda c: -c["issues_count"],
        ),
        "top_files": [{"file": f, "count": c} for f, c in cr_top_files],
        "issues": cr_issues[:200],
        "all_creedengo_rules": len(rules_meta),
        "rules_violated": len(cr_rules),
        # ── General SonarQube issues (separate section, for context) ──
        "sonar_issues": {
            "issues_count": len(sq_issues),
            "severity_breakdown": sq_sev,
            "total_effort": _effort_str(sq_effort),
            "total_effort_minutes": sq_effort,
            "rules_summary": sorted(
                list(sq_rules.values()),
                key=lambda r: (
                    {"BLOCKER": 0, "CRITICAL": 1, "MAJOR": 2, "MINOR": 3, "INFO": 4}.get(r["severity"], 5),
                    -r["count"],
                ),
            ),
            "top_files": [{"file": f, "count": c} for f, c in sorted(sq_files.items(), key=lambda x: -x[1])[:20]],
            "issues": sq_issues[:200],
        },
    }

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract Creedengo results from SonarQube")
    parser.add_argument("--sonar-url", required=True, help="SonarQube URL")
    parser.add_argument("--sonar-token", default="", help="SonarQube auth token")
    parser.add_argument("--sonar-user", default="", help="SonarQube username")
    parser.add_argument("--sonar-password", default="", help="SonarQube password")
    parser.add_argument("--project-key", required=True, help="SonarQube project key")
    parser.add_argument("--output", required=True, help="Output JSON file path")
    parser.add_argument("--appname", default="", help="Application name")
    parser.add_argument("--language", default="java", help="Primary language (java, python, javascript, csharp)")
    parser.add_argument("--sonar-repos", default="", help="Comma-separated SonarQube rule repositories (e.g. creedengo-java,creedengo-python)")
    args = parser.parse_args()

    report = extract_results(
        sonar_url=args.sonar_url,
        project_key=args.project_key,
        token=args.sonar_token,
        user=args.sonar_user,
        password=args.sonar_password,
        appname=args.appname,
        language=args.language,
        sonar_repos=args.sonar_repos,
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  ✅ Creedengo report written to {output_path}")
    print(f"     Score: {report['creedengo_score']['total']}/100 "
          f"(Grade: {report['creedengo_score']['grade']}) "
          f"— {report['creedengo_score']['issues_count']} issues")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

