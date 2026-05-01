#!/usr/bin/env python3
"""
sobriit_sender.py
─────────────────
Standalone module that sends Green API Score and Creedengo analysis results
to the SobriIT platform via its REST API.

Configuration (environment variables):
  SOBRIIT_BASE_URL   Base URL of the SobriIT API (e.g. https://sobriit.example.com)
  SOBRIIT_API_KEY    API key for authentication (sent as X-API-Key header)

These can also be passed as function parameters (override env vars).

Usage from Python:
    from sobriit_sender import send_to_sobriit
    result = send_to_sobriit(appname, green_report_dict, creedengo_report_dict)

Usage from CLI (for shell script integration):
    python3 scripts/sobriit_sender.py \\
        --appname myapp \\
        --green-report reports/latest-report.json \\
        --creedengo-report reports/creedengo-report.json \\
        [--base-url https://sobriit.example.com] \\
        [--api-key xxx]
    Exit code 0 = success, 1 = failure (non-blocking by design).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


# ─── HTTP helpers (stdlib only) ──────────────────────────────────────────────

def _api_call(method: str, url: str, api_key: str,
              body: dict | None = None, timeout: int = 15) -> tuple[int, dict | str]:
    """Perform an HTTP request to SobriIT. Returns (status_code, parsed_json_or_text)."""
    headers = {
        "X-API-Key": api_key,
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            try:
                return resp.status, json.loads(raw)
            except Exception:
                return resp.status, raw.decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        raw = e.read() if e.fp else b""
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode("utf-8", errors="replace")
    except Exception as exc:
        return 0, str(exc)


def _json_str(obj) -> str | None:
    """Serialize obj to a JSON string, or None if obj is None/empty."""
    if obj is None:
        return None
    if isinstance(obj, str):
        return obj if obj.strip() else None
    try:
        return json.dumps(obj, ensure_ascii=False)
    except Exception:
        return str(obj)


# ─── Main send function ─────────────────────────────────────────────────────

def send_to_sobriit(
    appname: str,
    green_report: dict | None = None,
    creedengo_report: dict | None = None,
    base_url: str | None = None,
    api_key: str | None = None,
) -> dict:
    """
    Send analysis results to SobriIT.

    Flow:
      1. GET /api/v1/applications/by-name/{appname} → lookup existing app
         If 404 → POST /api/v1/applications to create it
      2. POST /api/v1/builds → create a build linked to the application
      3. POST /api/v1/reports/greenapibackend → create the detailed report

    Returns a status dict:
      {"ok": True/False, "applicationId": ..., "buildId": ..., "reportId": ..., "error": ...}
    """
    base_url = (base_url or os.environ.get("SOBRIIT_BASE_URL", "")).rstrip("/")
    api_key = api_key or os.environ.get("SOBRIIT_API_KEY", "")

    if not base_url:
        return {"ok": False, "error": "SOBRIIT_BASE_URL not configured"}
    if not api_key:
        return {"ok": False, "error": "SOBRIIT_API_KEY not configured"}
    if not appname:
        return {"ok": False, "error": "appname is required"}
    if not green_report and not creedengo_report:
        return {"ok": False, "error": "no report data to send"}

    # ── Extract green score data ──
    gs = {}
    report_section = {}
    if green_report:
        report_section = green_report.get("report") or {}
        gs = report_section.get("green_score") or {}

    green_total = gs.get("total")
    green_max = gs.get("max")
    green_grade = gs.get("grade")
    score_normalised = round(green_total / green_max * 100, 2) if green_total and green_max else None
    report_timestamp = report_section.get("timestamp")

    # ── Extract creedengo data ──
    cs = {}
    if creedengo_report:
        cs = creedengo_report.get("creedengo_score") or {}

    # ── Step 1: Lookup or create application ──
    app_id = None

    # Try lookup by name
    status, resp = _api_call(
        "GET",
        f"{base_url}/api/v1/applications/by-name/{urllib.request.quote(appname, safe='')}",
        api_key,
    )
    if status == 200 and isinstance(resp, dict) and resp.get("id"):
        app_id = resp["id"]
    elif status == 404:
        # Create the application
        app_payload = {
            "name": appname,
            "code": appname,
        }
        status, resp = _api_call("POST", f"{base_url}/api/v1/applications", api_key, body=app_payload)
        if status in (200, 201) and isinstance(resp, dict) and resp.get("id"):
            app_id = resp["id"]
        else:
            return {"ok": False, "error": f"failed to create application (HTTP {status}): {resp}"}
    else:
        return {"ok": False, "error": f"failed to lookup application (HTTP {status}): {resp}"}

    # ── Step 2: Create build ──
    build_payload = {
        "applicationId": app_id,
        "tag": report_timestamp or "",
        "globalScore": score_normalised or 0.0,
        "performance": 0.0,
        "accessibility": 0.0,
        "bestPractices": 0.0,
        "ecoindex": 0.0,
        "bestPracticesCnumr": round(cs.get("total", 0) / cs.get("max", 100) * 100, 2) if cs.get("max") else 0.0,
        "accessibilityAxeCore": 0.0,
    }
    status, resp = _api_call("POST", f"{base_url}/api/v1/builds", api_key, body=build_payload)
    if status not in (200, 201) or not isinstance(resp, dict) or not resp.get("id"):
        return {
            "ok": False,
            "applicationId": app_id,
            "error": f"failed to create build (HTTP {status}): {resp}",
        }
    build_id = resp["id"]

    # ── Step 3: Create GreenApiBackendReport ──
    report_payload = {
        "buildId": build_id,
        "appName": appname,
        "reportTimestamp": report_timestamp,
        # Green Score fields
        "greenApiScoreTotal": green_total,
        "greenApiScoreMax": green_max,
        "greenApiGrade": green_grade,
        "scoreNormalised100": score_normalised,
        "greenScoreBreakdownJson": _json_str(gs.get("breakdown")),
        "ruleResourceMappingJson": _json_str(gs.get("rule_resource_mapping")),
        "greenScoreDetailsJson": _json_str(gs.get("details")),
        "endpointRulesJson": _json_str(report_section.get("endpoint_rules")),
        "totalsJson": _json_str(report_section.get("totals")),
        "endpointsJson": _json_str(report_section.get("endpoints")),
        "measurementsJson": _json_str(report_section.get("measurements")),
        "autoDiscoveryJson": _json_str(report_section.get("auto_discovery")),
        # Creedengo fields
        "creedengoScoreTotal": cs.get("total"),
        "creedengoScoreMax": cs.get("max"),
        "creedengoGrade": cs.get("grade"),
        "creedengoIssuesCount": cs.get("issues_count"),
        "creedengoTotalEffortMinutes": cs.get("total_effort_minutes"),
        "creedengoLanguage": creedengo_report.get("language") if creedengo_report else None,
        "creedengoProject": creedengo_report.get("project") if creedengo_report else None,
        "creedengoSeverityJson": _json_str(cs.get("severity_breakdown")),
        "creedengoMeasuresJson": _json_str(creedengo_report.get("measures")) if creedengo_report else None,
        "creedengoRulesSummaryJson": _json_str(creedengo_report.get("rules_summary")) if creedengo_report else None,
        "creedengoCategoriesJson": _json_str(creedengo_report.get("categories")) if creedengo_report else None,
        "creedengoTopFilesJson": _json_str(creedengo_report.get("top_files")) if creedengo_report else None,
        "creedengoIssuesJson": _json_str(creedengo_report.get("issues")) if creedengo_report else None,
        "creedengoDetectionJson": _json_str(creedengo_report.get("detection")) if creedengo_report else None,
    }

    # Remove None values (SobriIT accepts nullable but cleaner without)
    report_payload = {k: v for k, v in report_payload.items() if v is not None}

    status, resp = _api_call(
        "POST", f"{base_url}/api/v1/reports/greenapibackend", api_key, body=report_payload
    )
    if status not in (200, 201):
        return {
            "ok": False,
            "applicationId": app_id,
            "buildId": build_id,
            "error": f"failed to create report (HTTP {status}): {resp}",
        }

    report_id = resp.get("id") if isinstance(resp, dict) else None
    return {
        "ok": True,
        "applicationId": app_id,
        "buildId": build_id,
        "reportId": report_id,
    }


# ─── CLI entry point (for shell script integration) ─────────────────────────

def main():
    p = argparse.ArgumentParser(description="Send analysis results to SobriIT")
    p.add_argument("--appname", required=True, help="Application name")
    p.add_argument("--green-report", help="Path to latest-report.json")
    p.add_argument("--creedengo-report", help="Path to creedengo-report.json")
    p.add_argument("--base-url", default=None, help="SobriIT base URL (or SOBRIIT_BASE_URL env)")
    p.add_argument("--api-key", default=None, help="SobriIT API key (or SOBRIIT_API_KEY env)")
    args = p.parse_args()

    green_report = None
    if args.green_report:
        fp = Path(args.green_report)
        if fp.is_file():
            with fp.open("r", encoding="utf-8") as f:
                green_report = json.load(f)
        else:
            print(f"⚠ Green report not found: {args.green_report}", file=sys.stderr)

    creedengo_report = None
    if args.creedengo_report:
        fp = Path(args.creedengo_report)
        if fp.is_file():
            with fp.open("r", encoding="utf-8") as f:
                creedengo_report = json.load(f)
        else:
            print(f"⚠ Creedengo report not found: {args.creedengo_report}", file=sys.stderr)

    if not green_report and not creedengo_report:
        print("❌ No report files found — nothing to send.", file=sys.stderr)
        sys.exit(1)

    result = send_to_sobriit(
        appname=args.appname,
        green_report=green_report,
        creedengo_report=creedengo_report,
        base_url=args.base_url,
        api_key=args.api_key,
    )

    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()

