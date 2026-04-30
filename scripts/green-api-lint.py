#!/usr/bin/env python3
"""
green-api-lint.py
─────────────────
Offline OpenAPI linter — checks an OpenAPI / Swagger document against
the same Green API rules used by the live analyzer (DE / US / AR
families), but **without** issuing any HTTP request. Designed for:

  • IDE plugins (IntelliJ Green API plugin)
  • CI pre-merge gates (cheaper than spinning up a real API)
  • Pre-commit hook on the spec file

Usage:
    green-api-lint <spec-file>                       # human-readable
    green-api-lint <spec-file> --format json         # machine-readable
    green-api-lint <spec-file> --format sarif        # for code-review tools
    green-api-lint <spec-file> --fail-on-warn        # exit non-zero on findings

Exit codes:
    0  — no findings, or findings only when --fail-on-warn is NOT set
    1  — findings + --fail-on-warn
    2  — bad input (file missing, invalid YAML/JSON, …)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# ─── Lightweight rule definitions (subset that's checkable statically) ─────
# Each rule maps to (id, label, severity_default, max_pts, check fn).
# Severities follow Spectral conventions: error / warning / info.

SEVERITY_ORDER = {"error": 0, "warning": 1, "info": 2}


def _load_spec(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    try:
        return json.loads(text)
    except Exception:
        try:
            import yaml  # type: ignore
        except ImportError:
            print("❌ This file looks like YAML but PyYAML is not installed. "
                  "Try: pip install pyyaml", file=sys.stderr)
            sys.exit(2)
        return yaml.safe_load(text)


def _iter_operations(spec: dict):
    """Yield (method, path, op_dict) for every operation."""
    paths = spec.get("paths") or {}
    for path, ops in paths.items():
        if not isinstance(ops, dict):
            continue
        for method, op in ops.items():
            if method not in ("get", "post", "put", "patch", "delete", "head"):
                continue
            if isinstance(op, dict):
                yield method.upper(), path, op


# ─── Static checks (mirroring the runtime rules) ────────────────────────────

def check_DE11_pagination(spec):
    """Collection GETs should expose pagination (page/size or limit/offset)."""
    findings = []
    for method, path, op in _iter_operations(spec):
        if method != "GET":
            continue
        # Heuristic: a "collection" has no path placeholder at the tail.
        if path.rstrip("/").endswith("}"):
            continue
        params = (op.get("parameters") or [])
        names = {(p or {}).get("name", "").lower() for p in params if isinstance(p, dict)}
        if not (names & {"page", "size", "limit", "offset", "cursor", "pagesize", "pagenumber"}):
            findings.append({
                "rule_id": "DE11", "severity": "warning",
                "path": path, "method": method,
                "message": "Collection endpoint without pagination parameters "
                           "(page/size or limit/offset).",
                "remediation": "Add a `page` & `size` (or `limit`/`offset`) "
                               "query parameter.",
            })
    return findings


def check_DE08_fields(spec):
    """GETs should expose a `fields` parameter for sparse fieldsets."""
    findings = []
    for method, path, op in _iter_operations(spec):
        if method != "GET":
            continue
        params = (op.get("parameters") or [])
        names = {(p or {}).get("name", "").lower() for p in params if isinstance(p, dict)}
        if not (names & {"fields", "select", "include"}):
            findings.append({
                "rule_id": "DE08", "severity": "info",
                "path": path, "method": method,
                "message": "No sparse-fieldset parameter (`fields` / `select`).",
                "remediation": "Add a `fields` query param so clients can request "
                               "only what they need.",
            })
    return findings


def check_DE02_DE03_cache(spec):
    """Single-resource GETs should declare a 304 response (ETag / If-None-Match)."""
    findings = []
    for method, path, op in _iter_operations(spec):
        if method != "GET":
            continue
        if not path.rstrip("/").endswith("}"):
            continue
        responses = (op.get("responses") or {})
        if "304" not in responses:
            findings.append({
                "rule_id": "DE02/DE03", "severity": "warning",
                "path": path, "method": method,
                "message": "Single-resource GET without 304 Not Modified response "
                           "(ETag / If-None-Match support).",
                "remediation": "Document a 304 response and emit ETag headers "
                               "in the implementation.",
            })
    return findings


def check_range_206(spec):
    """Detail/range endpoints should declare 206 Partial Content."""
    findings = []
    for method, path, op in _iter_operations(spec):
        responses = (op.get("responses") or {})
        if "206" in responses:
            return []  # at least one endpoint supports it → rule is informational only
    findings.append({
        "rule_id": "BIN01-range", "severity": "info",
        "path": "*", "method": "*",
        "message": "No operation declares a 206 Partial Content response.",
        "remediation": "Support `Range:` requests on large payloads to avoid "
                       "shipping unused bytes.",
    })
    return findings


def check_DE06_delta(spec):
    """At least one delta/changes endpoint with a `since` parameter."""
    for method, path, op in _iter_operations(spec):
        if re.search(r"/(changes|delta|since|events|sync)\b", path, flags=re.IGNORECASE):
            return []
        params = (op.get("parameters") or [])
        names = {(p or {}).get("name", "").lower() for p in params if isinstance(p, dict)}
        if names & {"since", "modified_since", "updatedat", "updated_after"}:
            return []
    return [{
        "rule_id": "DE06", "severity": "warning",
        "path": "*", "method": "*",
        "message": "No delta/changes endpoint detected (path or `since` param).",
        "remediation": "Expose a /changes?since=<ts> endpoint to avoid full re-syncs.",
    }]


def check_AR02_format_cbor(spec):
    """At least one operation should expose a binary content-type."""
    binary_types = ("application/cbor", "application/protobuf",
                    "application/x-protobuf", "application/octet-stream",
                    "application/msgpack", "application/avro")
    for method, path, op in _iter_operations(spec):
        responses = (op.get("responses") or {})
        for r in responses.values():
            content = (r or {}).get("content") or {}
            for ct in content:
                if ct.lower() in binary_types:
                    return []
    return [{
        "rule_id": "BIN01-cbor", "severity": "info",
        "path": "*", "method": "*",
        "message": "No operation exposes a binary content-type "
                   "(CBOR / Protobuf / MsgPack).",
        "remediation": "Add a binary variant for high-volume read endpoints "
                       "(typically 30-50% smaller than JSON).",
    }]


def check_AR01_event_driven(spec):
    """Detect explicit EDA signals: callbacks, webhooks, AsyncAPI hint, SSE,
    WebSocket. Polling-flavoured paths (/changes, /events) without a streaming
    media-type are flagged as migration opportunities."""
    advice = []

    def _has_eda(spec):
        if spec.get("webhooks"):
            return True
        for _m, _p, op in _iter_operations(spec):
            if op.get("callbacks"):
                return True
            for r in (op.get("responses") or {}).values():
                content = (r or {}).get("content") or {}
                if any(ct.startswith("text/event-stream") for ct in content):
                    return True
        return False

    if _has_eda(spec):
        return []

    polling_re = re.compile(r"/(changes|since|events|notifications|updates|polls?)\b",
                            flags=re.IGNORECASE)
    for method, path, op in _iter_operations(spec):
        if method == "GET" and polling_re.search(path):
            advice.append({
                "rule_id": "AR01", "severity": "warning",
                "path": path, "method": method,
                "message": "Polling-style endpoint without streaming alternative.",
                "remediation": "Migrate to SSE (text/event-stream), WebSocket, "
                               "or an AsyncAPI subscription.",
            })
    if not advice:
        advice.append({
            "rule_id": "AR01", "severity": "info",
            "path": "*", "method": "*",
            "message": "No event-driven mechanism declared (callbacks, webhooks, "
                       "SSE, AsyncAPI).",
            "remediation": "Consider an event-driven channel for high-frequency "
                           "consumers to avoid wasteful polling.",
        })
    return advice


def check_AR03_unique_api(spec):
    """Detect intra-spec duplication (v1/v2 cohabitation on the same path)."""
    findings = []
    bucket: dict[tuple, list[str]] = {}
    version_prefix = re.compile(r"^/v\d+(?=/)", flags=re.IGNORECASE)
    for method, path, _op in _iter_operations(spec):
        norm = re.sub(r"\{[^}]+\}", "{}", version_prefix.sub("", path or ""))
        bucket.setdefault((method, norm), []).append(path)
    for (method, norm), originals in bucket.items():
        uniq = sorted(set(originals))
        if len(uniq) >= 2:
            findings.append({
                "rule_id": "AR03", "severity": "warning",
                "path": " ⇄ ".join(uniq), "method": method,
                "message": f"Cohabitation de versions sur {method} {norm}.",
                "remediation": "Déprécier explicitement l'ancienne version pour "
                               "supprimer le runtime redondant.",
            })
    return findings


def check_LO01_observability(spec):
    """Hint when no /actuator, /health, /metrics endpoint is declared."""
    paths = (spec.get("paths") or {})
    keys = " ".join(paths.keys()).lower()
    if any(k in keys for k in ("/health", "/actuator", "/metrics", "/q/health", "/q/metrics")):
        return []
    return [{
        "rule_id": "LO01", "severity": "warning",
        "path": "*", "method": "*",
        "message": "No observability endpoint declared (/health, /actuator, /metrics).",
        "remediation": "Expose health/metrics so the carbon footprint can be "
                       "observed (Prometheus / OpenTelemetry).",
    }]


CHECKS = [
    check_DE11_pagination,
    check_DE08_fields,
    check_DE02_DE03_cache,
    check_range_206,
    check_DE06_delta,
    check_AR02_format_cbor,
    check_AR01_event_driven,
    check_AR03_unique_api,
    check_LO01_observability,
]


# ─── Renderers ──────────────────────────────────────────────────────────────

def _render_text(findings, spec_path):
    if not findings:
        print(f"✅  {spec_path} — no Green API findings.")
        return
    by_sev = {"error": 0, "warning": 0, "info": 0}
    print(f"🔎  Green API lint — {spec_path}")
    print("─" * 72)
    for f in sorted(findings, key=lambda x: SEVERITY_ORDER.get(x["severity"], 9)):
        by_sev[f["severity"]] = by_sev.get(f["severity"], 0) + 1
        sev_icon = {"error": "❌", "warning": "⚠️ ", "info": "ℹ️ "}.get(f["severity"], "•")
        print(f"  {sev_icon} [{f['rule_id']:>10s}] {f['method']} {f['path']}")
        print(f"        {f['message']}")
        if f.get("remediation"):
            print(f"        → {f['remediation']}")
    print("─" * 72)
    print(f"  {by_sev['error']} error(s), {by_sev['warning']} warning(s), "
          f"{by_sev['info']} info.")


def _render_json(findings, spec_path):
    print(json.dumps({
        "spec": str(spec_path),
        "findings": findings,
        "summary": {
            "errors":   sum(1 for f in findings if f["severity"] == "error"),
            "warnings": sum(1 for f in findings if f["severity"] == "warning"),
            "infos":    sum(1 for f in findings if f["severity"] == "info"),
            "total":    len(findings),
        },
    }, indent=2, ensure_ascii=False))


def _render_sarif(findings, spec_path):
    """Minimal SARIF 2.1.0 — consumable by GitHub Code Scanning, JetBrains
    Qodana, etc."""
    rules_seen = {}
    results = []
    for f in findings:
        rid = f["rule_id"]
        rules_seen.setdefault(rid, {
            "id": rid,
            "name": rid,
            "shortDescription": {"text": f["message"]},
        })
        results.append({
            "ruleId": rid,
            "level": {"error": "error", "warning": "warning",
                      "info": "note"}.get(f["severity"], "note"),
            "message": {"text": f["message"]},
            "locations": [{
                "physicalLocation": {
                    "artifactLocation": {"uri": str(spec_path)},
                    "region": {"startLine": 1},
                },
                "logicalLocations": [{
                    "name": f"{f['method']} {f['path']}",
                    "kind": "endpoint",
                }],
            }],
        })
    sarif = {
        "$schema": "https://schemastore.azurewebsites.net/schemas/json/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {"driver": {
                "name": "green-api-lint",
                "informationUri": "https://github.com/API-Green-Score/apigreenscoreanalyzer",
                "rules": list(rules_seen.values()),
            }},
            "results": results,
        }],
    }
    print(json.dumps(sarif, indent=2, ensure_ascii=False))


# ─── CLI ────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(
        prog="green-api-lint",
        description="Offline lint of an OpenAPI document against Green API rules.",
    )
    p.add_argument("spec", help="Path to the OpenAPI / Swagger file (JSON or YAML).")
    p.add_argument("--format", choices=("text", "json", "sarif"), default="text")
    p.add_argument("--fail-on-warn", action="store_true",
                   help="Exit non-zero if any finding is emitted.")
    args = p.parse_args()

    spec_path = Path(args.spec)
    if not spec_path.is_file():
        print(f"❌  spec not found: {spec_path}", file=sys.stderr)
        sys.exit(2)
    try:
        spec = _load_spec(spec_path)
    except Exception as e:
        print(f"❌  could not parse {spec_path}: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(spec, dict) or "paths" not in spec:
        print(f"❌  {spec_path} doesn't look like an OpenAPI document "
              "(missing top-level `paths`).", file=sys.stderr)
        sys.exit(2)

    findings = []
    for chk in CHECKS:
        try:
            findings.extend(chk(spec) or [])
        except Exception as e:
            findings.append({
                "rule_id": chk.__name__,
                "severity": "error",
                "path": "*", "method": "*",
                "message": f"Internal lint error: {e}",
                "remediation": "Please file a bug report.",
            })

    if args.format == "json":
        _render_json(findings, spec_path)
    elif args.format == "sarif":
        _render_sarif(findings, spec_path)
    else:
        _render_text(findings, spec_path)

    if findings and args.fail_on_warn:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()

