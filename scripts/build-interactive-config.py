#!/usr/bin/env python3
"""
build-interactive-config.py
───────────────────────────
Non-interactive twin of the bridge's ``/api/discover`` + ``/api/analyze``
flow used by ``dashboard/interactive.html``. Designed to be called from
``start.sh`` (and from CI) so that the **local** Green Score path
(``start.sh`` → ``green-score-analyzer_withdiscovery.sh`` →
``green-api-auto-discover.py``) discovers the targets' OpenAPI specs,
extracts the example payloads / path / query params declared in the spec,
and persists:

  • ``reports/interactive-config.json``      — human-readable, JSON config
    that lists every endpoint with its resolved path, default body, etc.
    (same shape as what the interactive UI persists).
  • ``reports/.interactive-scenario.json``   — analyzer-side scenario file
    consumed by ``green-api-auto-discover.py`` when
    ``GREEN_INTERACTIVE_SCENARIO`` is set. It carries the OpenAPI examples
    so the analyzer issues realistic POST/PUT/PATCH bodies and substitutes
    path placeholders during the runtime probes.

The script never prompts the user — every default comes from the OpenAPI
``example`` / ``examples`` / ``default`` / ``enum[0]`` keys, falling back to
type-aware scalars otherwise. Stdlib-only, mirrors the bridge's helpers
(see ``scripts/greenapianalyzer-server.py``).

Usage::

    python3 scripts/build-interactive-config.py \
        --targets http://localhost:8080,http://localhost:8081 \
        [--bearer TOKEN] [--appname myapp] [--repeat 3] \
        [--output-dir reports/]

Exits 0 even when discovery fails on a subset of targets (the analyzer
will then run with whatever was discovered). Exits 1 only on bad CLI args
or unrecoverable I/O errors so the calling script can keep going on
``true ||`` semantics.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ─── Shared with greenapianalyzer-server.py ────────────────────────────────
# Keep this list in sync with the bridge's SWAGGER_DISCOVERY_PATHS so the
# local and remote pipelines find the same specs.
SWAGGER_DISCOVERY_PATHS = [
    "/api/v3/api-docs",
    "/v3/api-docs",
    "/v3/api-docs.yaml",
    "/v2/api-docs",
    "/openapi.json",
    "/openapi.yaml",
    "/swagger/v1/swagger.json",
    "/swagger.json",
    "/swagger.yaml",
]

_REF_MAX_DEPTH = 6


def _http_get(url: str, headers: dict | None = None, timeout: int = 10):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            ctype = resp.headers.get("Content-Type", "")
            return resp.status, ctype, data
    except urllib.error.HTTPError as e:
        return e.code, (e.headers.get("Content-Type", "") if e.headers else ""), e.read()
    except Exception:
        return 0, "", b""


def _parse_spec(raw: bytes, ctype: str) -> dict | None:
    try:
        text = raw.decode("utf-8", errors="replace")
    except Exception:
        return None
    try:
        return json.loads(text)
    except Exception:
        pass
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text)
    except Exception:
        return None


def _resolve_ref(spec: dict, ref: str) -> dict:
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return {}
    node = spec
    for part in ref[2:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            return {}
    return node if isinstance(node, dict) else {}


def _deref(spec, node, _seen=None, _depth=0):
    if not isinstance(node, dict):
        return node
    ref = node.get("$ref")
    if not ref or _depth >= _REF_MAX_DEPTH:
        return node
    seen = _seen or set()
    if ref in seen:
        return {}
    return _deref(spec, _resolve_ref(spec, ref), seen | {ref}, _depth + 1)


def _scalar_for_type(schema):
    if not isinstance(schema, dict):
        return None
    t = schema.get("type")
    fmt = schema.get("format", "")
    if t == "string":
        if fmt == "date":      return "2024-01-01"
        if fmt == "date-time": return "2024-01-01T00:00:00Z"
        if fmt == "uuid":      return "00000000-0000-0000-0000-000000000000"
        if fmt == "email":     return "user@example.com"
        if fmt in ("byte", "binary", "password"): return ""
        return "string"
    if t == "integer": return 1
    if t == "number":  return 1.0
    if t == "boolean": return True
    if t == "array":   return []
    if t == "object":  return {}
    return None


def _example_from_schema(spec, schema, _depth=0):
    if _depth > _REF_MAX_DEPTH or not isinstance(schema, dict):
        return None
    schema = _deref(spec, schema, _depth=_depth)
    if "example" in schema:  return schema["example"]
    if "default" in schema:  return schema["default"]
    if isinstance(schema.get("enum"), list) and schema["enum"]:
        return schema["enum"][0]
    for key in ("oneOf", "anyOf", "allOf"):
        branches = schema.get(key)
        if isinstance(branches, list) and branches:
            if key == "allOf":
                merged = {}
                for sub in branches:
                    sub_ex = _example_from_schema(spec, sub, _depth + 1)
                    if isinstance(sub_ex, dict):
                        merged.update(sub_ex)
                if merged:
                    return merged
            else:
                ex = _example_from_schema(spec, branches[0], _depth + 1)
                if ex is not None:
                    return ex
    t = schema.get("type")
    if t == "object" or "properties" in schema:
        out = {}
        props = schema.get("properties") or {}
        required = set(schema.get("required") or [])
        for name, sub in props.items():
            sub_ex = _example_from_schema(spec, sub, _depth + 1)
            if name in required:
                out[name] = sub_ex if sub_ex is not None else _scalar_for_type(sub)
            elif sub_ex is not None:
                out[name] = sub_ex
        return out
    if t == "array":
        item_ex = _example_from_schema(spec, schema.get("items") or {}, _depth + 1)
        return [item_ex] if item_ex is not None else []
    return _scalar_for_type(schema)


def _param_example(spec, param):
    param = _deref(spec, param)
    if not isinstance(param, dict):
        return None
    if "example" in param:
        return param["example"]
    examples = param.get("examples")
    if isinstance(examples, dict) and examples:
        first = _deref(spec, next(iter(examples.values())))
        if isinstance(first, dict) and "value" in first:
            return first["value"]
    schema = param.get("schema") or {}
    if param.get("type") and not schema:  # Swagger 2.0 inline
        schema = {k: param[k] for k in ("type", "format", "enum", "default", "example")
                  if k in param}
    return _example_from_schema(spec, schema)


def _request_body_example(spec, op):
    rb = _deref(spec, op.get("requestBody") or {})
    content = rb.get("content") if isinstance(rb, dict) else None
    if isinstance(content, dict) and content:
        media = (
            content.get("application/json")
            or next((v for k, v in content.items() if "json" in k.lower()), None)
            or next(iter(content.values()))
        )
        media = _deref(spec, media or {})
        if "example" in media:
            return media["example"]
        examples = media.get("examples")
        if isinstance(examples, dict) and examples:
            first = _deref(spec, next(iter(examples.values())))
            if isinstance(first, dict) and "value" in first:
                return first["value"]
        return _example_from_schema(spec, media.get("schema") or {})
    # Swagger 2.0 — body via parameters[in=body]
    for p in op.get("parameters") or []:
        p = _deref(spec, p)
        if isinstance(p, dict) and p.get("in") == "body":
            if "example" in p:
                return p["example"]
            return _example_from_schema(spec, p.get("schema") or {})
    return None


def _discover_swagger_for(base_url: str, bearer: str) -> tuple[str, dict | None]:
    base = base_url.rstrip("/")
    headers = {"Accept": "application/json, application/yaml, */*"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    if any(p in base for p in ("api-docs", "openapi", "swagger.json", "swagger.yaml")):
        code, ctype, raw = _http_get(base, headers=headers)
        if code == 200:
            spec = _parse_spec(raw, ctype)
            if spec:
                return base, spec
    for p in SWAGGER_DISCOVERY_PATHS:
        url = base + p
        code, ctype, raw = _http_get(url, headers=headers)
        if code == 200:
            spec = _parse_spec(raw, ctype)
            if spec:
                return url, spec
    return "", None


def _extract_resources(target: str, spec: dict) -> list[dict]:
    """Mirrors the bridge's _extract_resources — every endpoint enriched with
    examplePathParams / exampleQueryParams / exampleBody."""
    out: list[dict] = []
    base_path = ""
    if spec.get("swagger") == "2.0":
        base_path = spec.get("basePath", "") or ""
    paths = spec.get("paths") or {}
    for path, ops in paths.items():
        if not isinstance(ops, dict):
            continue
        full_path = (base_path + path) if base_path else path
        path_level_params = ops.get("parameters") if isinstance(ops.get("parameters"), list) else []
        for method in ("get", "post", "put", "patch", "delete", "head"):
            if method not in ops or not isinstance(ops.get(method), dict):
                continue
            op = ops[method]
            params = list(op.get("parameters") or [])
            seen_names = {(_deref(spec, p) or {}).get("name") for p in params}
            for p in path_level_params:
                p_name = (_deref(spec, p) or {}).get("name")
                if p_name not in seen_names:
                    params.append(p)

            example_path_params: dict = {}
            example_query_params: dict = {}
            for p in params:
                p_d = _deref(spec, p)
                if not isinstance(p_d, dict):
                    continue
                p_in = p_d.get("in")
                p_name = p_d.get("name")
                if not p_name:
                    continue
                ex = _param_example(spec, p_d)
                if ex is None:
                    continue
                if p_in == "path":
                    example_path_params[p_name] = ex
                elif p_in == "query" and p_d.get("required"):
                    example_query_params[p_name] = ex

            example_body = None
            if method in ("post", "put", "patch"):
                example_body = _request_body_example(spec, op)

            out.append({
                "target": target,
                "method": method.upper(),
                "path": full_path,
                "operationId": op.get("operationId", ""),
                "summary": op.get("summary", "") or (op.get("description", "") or "")[:140],
                "tags": op.get("tags") or [],
                "hasBody": method in ("post", "put", "patch"),
                "examplePathParams": example_path_params,
                "exampleQueryParams": example_query_params,
                "exampleBody": example_body,
            })
    return out


def _resolve_path(template: str, path_params: dict | None,
                  query_params: dict | None) -> str:
    """Same expansion as the bridge: replace ``{name}`` placeholders with
    values + append a query-string built from required params, so the
    persisted ``interactive-config.json`` is human-readable."""
    if not isinstance(template, str):
        return template
    out = template
    if isinstance(path_params, dict):
        out = re.sub(
            r"\{([^}]+)\}",
            lambda m: str(path_params.get(m.group(1), m.group(0))),
            out,
        )
    if isinstance(query_params, dict) and query_params:
        flat = {}
        for k, v in query_params.items():
            if v is None:
                continue
            flat[k] = json.dumps(v) if isinstance(v, (dict, list)) else v
        if flat:
            sep = "&" if "?" in out else "?"
            out = out + sep + urllib.parse.urlencode(
                flat, quote_via=urllib.parse.quote_plus
            )
    return out


def build_artifacts(targets: list[str], bearer: str, appname: str,
                    repeat: int, output_dir: Path) -> dict:
    """Discover every target, extract example-driven resources, persist
    ``interactive-config.json`` and ``.interactive-scenario.json``.

    Returns a small summary dict (also printed to stdout) so the caller can
    grep it for diagnostics.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    discovered: list[dict] = []
    swaggers: list[str] = []
    endpoints_persisted: list[dict] = []
    scenario = {"pathParams": {}, "requestBodies": {}, "queryParams": {}}

    body_methods = {"POST", "PUT", "PATCH"}

    for raw in targets:
        t = raw.strip().rstrip("/")
        if not t:
            continue
        swurl, spec = _discover_swagger_for(t, bearer)
        if not spec:
            print(f"  ⚠️  {t}: no OpenAPI spec found (tried {len(SWAGGER_DISCOVERY_PATHS)} paths)",
                  file=sys.stderr)
            discovered.append({"target": t, "swagger": "", "ok": False, "count": 0})
            continue
        swaggers.append(swurl)
        resources = _extract_resources(t, spec)
        info = (spec.get("info") or {})
        discovered.append({
            "target": t, "swagger": swurl, "ok": True, "count": len(resources),
            "info": {
                "title":   info.get("title", ""),
                "version": info.get("version", ""),
                "openapi": spec.get("openapi") or spec.get("swagger") or "",
            },
        })
        print(f"  ✅ {t}: {len(resources)} resource(s) found "
              f"({info.get('title','')} {info.get('version','')})")

        for r in resources:
            method = r["method"]
            tmpl   = r["path"]
            path_params  = dict(r.get("examplePathParams")  or {})
            query_params = dict(r.get("exampleQueryParams") or {})
            body         = r.get("exampleBody")

            # Persisted config — same shape as interactive-config.json from
            # the bridge: human-readable resolved path + raw template +
            # extracted defaults (path/query/body).
            ep = {
                "target":       t,
                "method":       method,
                "path":         _resolve_path(tmpl, path_params, query_params),
                "calls":        repeat,
                "payload":      "",
                "pathTemplate": tmpl,
            }
            if path_params:
                ep["pathParams"]  = path_params
            if query_params:
                ep["queryParams"] = query_params
            if method in body_methods and body is not None:
                try:
                    ep["payload"] = (body if isinstance(body, str)
                                     else json.dumps(body, indent=2,
                                                     ensure_ascii=False))
                except Exception:
                    ep["payload"] = str(body)
            endpoints_persisted.append(ep)

            # Analyzer-side scenario — keyed on templated path so the
            # analyzer can match it against the OpenAPI spec.
            mtd_lower = method.lower()
            if path_params:
                scenario["pathParams"][tmpl] = {str(k): v for k, v in path_params.items()}
            if query_params:
                scenario["queryParams"][f"{mtd_lower}:{tmpl}"] = {
                    str(k): v for k, v in query_params.items()
                }
            if method in body_methods and body is not None:
                key = f"{mtd_lower}:{tmpl}"
                if isinstance(body, str):
                    try:
                        scenario["requestBodies"][key] = json.loads(body)
                    except Exception:
                        scenario["requestBodies"][key] = body
                else:
                    scenario["requestBodies"][key] = body

    # Persist outputs
    cfg_path = output_dir / "interactive-config.json"
    with cfg_path.open("w", encoding="utf-8") as f:
        json.dump({
            "targets":   [t.strip().rstrip("/") for t in targets if t.strip()],
            "swaggers":  swaggers,
            "appname":   appname,
            "endpoints": endpoints_persisted,
            "repeat":    repeat,
            "source":    "start.sh",
        }, f, indent=2, ensure_ascii=False)

    scenario_path = output_dir / ".interactive-scenario.json"
    with scenario_path.open("w", encoding="utf-8") as f:
        json.dump(scenario, f, indent=2, ensure_ascii=False)

    summary = {
        "config":    str(cfg_path),
        "scenario":  str(scenario_path),
        "targets":   len(targets),
        "endpoints": len(endpoints_persisted),
        "discovery": discovered,
    }
    return summary


# ─── CLI ────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--targets", required=True,
                   help="Comma-separated list of base URLs (e.g. "
                        "http://localhost:8080,http://localhost:8081).")
    p.add_argument("--bearer", default="",
                   help="Optional bearer token used during swagger discovery.")
    p.add_argument("--appname", default="",
                   help="Application name (persisted in interactive-config.json).")
    p.add_argument("--repeat", type=int, default=3,
                   help="Default ``calls`` per resource (default: 3).")
    p.add_argument("--output-dir", default="reports",
                   help="Where to write interactive-config.json and "
                        ".interactive-scenario.json (default: reports/).")
    args = p.parse_args()

    targets = [t for t in (args.targets or "").split(",") if t.strip()]
    if not targets:
        print("❌ --targets cannot be empty", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.output_dir).resolve()
    print(f"🔎 Discovering swagger + extracting examples for {len(targets)} target(s)…")
    summary = build_artifacts(
        targets=targets,
        bearer=args.bearer.strip(),
        appname=args.appname.strip(),
        repeat=max(1, min(args.repeat, 50)),
        output_dir=out_dir,
    )
    print(f"📝 Wrote {summary['config']}")
    print(f"📝 Wrote {summary['scenario']}")
    print(f"   {summary['endpoints']} endpoint(s) across {summary['targets']} target(s).")


if __name__ == "__main__":
    main()

