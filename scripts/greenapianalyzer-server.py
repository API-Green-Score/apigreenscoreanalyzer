#!/usr/bin/env python3
"""
greenapianalyzer-server.py
──────────────────────────
Tiny local HTTP bridge used by `dashboard/interactive.html`.

It exposes:
  GET  /                        → serves dashboard/interactive.html
  GET  /<static>                → serves anything under the project root
                                  (badges, reports, dashboard assets, …)
  POST /api/discover            → { targets:[url,…], bearer:"" }
                                   ↳ returns merged resources list discovered
                                     from each target's OpenAPI spec
  POST /api/analyze             → { targets:[…], swaggers:[…], bearer:"",
                                     appname:"", endpoints:[
                                        {target,method,path,calls,payload}
                                     ] }
                                   ↳ runs scripts/greenapianalyzer.sh and
                                     returns the produced latest-report.json

The server is intentionally dependency-free (stdlib only) so it works on any
machine that already runs the analyzer.

Usage:
  python3 scripts/greenapianalyzer-server.py            # http://127.0.0.1:8765
  python3 scripts/greenapianalyzer-server.py --port 9999 --open
"""
from __future__ import annotations

import argparse
import io
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
DASHBOARD = ROOT / "dashboard"
REPORTS = ROOT / "reports"
ANALYZER_SH = SCRIPTS / "greenapianalyzer.sh"

# Try to keep parity with the canonical discovery list of the analyzer.
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

# ─── Helpers ────────────────────────────────────────────────────────────────

def _http_get(url: str, headers: dict | None = None, timeout: int = 10):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            ctype = resp.headers.get("Content-Type", "")
            return resp.status, ctype, data
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", "") if e.headers else "", e.read()
    except Exception:
        return 0, "", b""


def _parse_spec(raw: bytes, ctype: str) -> dict | None:
    try:
        text = raw.decode("utf-8", errors="replace")
    except Exception:
        return None
    # JSON first
    try:
        return json.loads(text)
    except Exception:
        pass
    # YAML fallback (best-effort, optional)
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text)
    except Exception:
        return None


# ─── OpenAPI example extraction (mirrors green-api-auto-discover.py) ──────
# We duplicate a tiny subset here so the bridge stays dependency-free and
# self-contained. Keep both implementations in sync.

_REF_MAX_DEPTH = 6


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
    """Return (resolved_swagger_url, spec_dict_or_None) for a base URL."""
    base = base_url.rstrip("/")
    headers = {"Accept": "application/json, application/yaml, */*"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    # If the user already passed a full swagger URL, just fetch it.
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
    """Flatten an OpenAPI spec into a list of {target, method, path, summary, …}.

    Each resource is also enriched with example data extracted from the spec
    so the interactive dashboard can pre-fill defaults the user can tweak:
      - ``examplePathParams``   : dict {name: value} from path params
      - ``exampleQueryParams``  : dict {name: value} from required query params
      - ``exampleBody``         : best-effort JSON body for POST/PUT/PATCH
    """
    out: list[dict] = []
    base_path = ""
    if spec.get("swagger") == "2.0":
        base_path = spec.get("basePath", "") or ""
    paths = spec.get("paths") or {}
    for path, ops in paths.items():
        if not isinstance(ops, dict):
            continue
        full_path = (base_path + path) if base_path else path
        # Path-level parameters apply to every operation
        path_level_params = ops.get("parameters") if isinstance(ops.get("parameters"), list) else []
        for method in ("get", "post", "put", "patch", "delete", "head"):
            if method not in ops or not isinstance(ops.get(method), dict):
                continue
            op = ops[method]
            tags = op.get("tags") or []
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
                "summary": op.get("summary", "") or op.get("description", "")[:140],
                "tags": tags,
                "hasBody": method in ("post", "put", "patch"),
                "examplePathParams": example_path_params,
                "exampleQueryParams": example_query_params,
                "exampleBody": example_body,
            })
    return out


# ─── HTTP handler ───────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    server_version = "GreenAPIAnalyzerBridge/1.0"

    def _send_json(self, status: int, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path, ctype: str):
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            self.send_error(404, "Not found")
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):  # CORS preflight
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type,Authorization")
        self.end_headers()

    # ── GET: static serving ──
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/interactive", "/index.html"):
            return self._send_file(DASHBOARD / "interactive.html", "text/html; charset=utf-8")
        # ── Bridge liveness probe (used by the dashboard) ──
        if path == "/api/ping":
            return self._send_json(200, {"ok": True, "service": "greenapianalyzer-bridge", "version": "1.0"})
        # ── Live log tail of the most recent start.sh run ──
        if path == "/api/local-log":
            log_file = REPORTS / ".start-sh.log"
            if not log_file.is_file():
                return self._send_json(200, {"ok": True, "running": False, "content": "", "size": 0})
            try:
                with log_file.open("r", encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except Exception as e:
                return self._send_json(500, {"error": f"failed to read log: {e}"})
            running_marker = REPORTS / ".start-sh.running"
            return self._send_json(200, {
                "ok": True,
                "running": running_marker.is_file(),
                "content": content,
                "size": len(content),
            })
        # ── Live log tail of the most recent /api/analyze run (Remote tab) ──
        if path == "/api/analyze-log":
            log_file = REPORTS / ".analyzer.log"
            if not log_file.is_file():
                return self._send_json(200, {"ok": True, "running": False, "content": "", "size": 0})
            try:
                with log_file.open("r", encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except Exception as e:
                return self._send_json(500, {"error": f"failed to read log: {e}"})
            running_marker = REPORTS / ".analyzer.running"
            return self._send_json(200, {
                "ok": True,
                "running": running_marker.is_file(),
                "content": content,
                "size": len(content),
            })
        # Map path to filesystem under ROOT
        rel = path.lstrip("/")
        # Prevent traversal
        target = (ROOT / rel).resolve()
        try:
            target.relative_to(ROOT)
        except ValueError:
            self.send_error(403, "Forbidden")
            return
        if not target.is_file():
            self.send_error(404, "Not found")
            return
        ext = target.suffix.lower()
        ctypes = {
            ".html": "text/html; charset=utf-8",
            ".js":   "application/javascript; charset=utf-8",
            ".css":  "text/css; charset=utf-8",
            ".json": "application/json; charset=utf-8",
            ".svg":  "image/svg+xml",
            ".png":  "image/png",
            ".md":   "text/markdown; charset=utf-8",
        }
        return self._send_file(target, ctypes.get(ext, "application/octet-stream"))

    # ── POST: API endpoints ──
    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length > 0 else b"{}"
            payload = json.loads(raw.decode("utf-8") or "{}")
        except Exception as e:
            return self._send_json(400, {"error": f"invalid json: {e}"})

        if self.path == "/api/discover":
            return self._handle_discover(payload)
        if self.path == "/api/analyze":
            return self._handle_analyze(payload)
        if self.path == "/api/local-analyze":
            return self._handle_local_analyze(payload)
        return self._send_json(404, {"error": "unknown endpoint"})

    # ── /api/discover ──
    def _handle_discover(self, payload):
        targets = payload.get("targets") or []
        bearer = (payload.get("bearer") or "").strip()
        if not isinstance(targets, list) or not targets:
            return self._send_json(400, {"error": "targets[] is required"})
        targets = [t.strip().rstrip("/") for t in targets if t and t.strip()]
        out = {
            "targets": [],
            "resources": [],
        }
        for t in targets:
            swagger_url, spec = _discover_swagger_for(t, bearer)
            entry = {"target": t, "swagger": swagger_url, "ok": bool(spec)}
            if spec:
                resources = _extract_resources(t, spec)
                entry["count"] = len(resources)
                out["resources"].extend(resources)
                entry["info"] = {
                    "title": (spec.get("info") or {}).get("title", ""),
                    "version": (spec.get("info") or {}).get("version", ""),
                    "openapi": spec.get("openapi") or spec.get("swagger") or "",
                }
            else:
                entry["count"] = 0
                entry["error"] = f"No OpenAPI spec found for {t}"
            out["targets"].append(entry)
        return self._send_json(200, out)

    # ── /api/analyze ──
    def _handle_analyze(self, payload):
        targets = payload.get("targets") or []
        swaggers = payload.get("swaggers") or []
        bearer = payload.get("bearer") or ""
        appname = payload.get("appname") or ""
        endpoints = payload.get("endpoints") or []

        targets = [t.strip().rstrip("/") for t in targets if t]
        swaggers = [s.strip() for s in swaggers if s]
        if not targets:
            # derive targets from endpoints if not provided
            targets = sorted({e.get("target", "").rstrip("/") for e in endpoints if e.get("target")})
        if not targets:
            return self._send_json(400, {"error": "no targets provided"})

        # Compute the maximum number of calls requested by the user across all
        # selected resources, clamped to a sane range. The python analyzer uses
        # a single global --repeat, so we use the max so every requested call
        # count is at least covered.
        calls_values = [int(e.get("calls", 3) or 3) for e in endpoints if e]
        max_calls = max(calls_values) if calls_values else 3
        max_calls = max(1, min(max_calls, 20))

        # ── Hydrate empty payloads from the OpenAPI examples ─────────────
        # Even when the dashboard ships an empty `payload` (e.g. user cleared
        # the textarea, or an older cached UI didn't pre-fill it), we still
        # want the persisted config + scenario to reflect the example bodies
        # advertised by the spec for body-bearing methods (POST/PUT/PATCH).
        # We re-discover each unique target once and look up each endpoint
        # in the resulting resource list.
        body_methods = {"post", "put", "patch"}
        # Collect unique targets to (re-)discover specs for. Cheap because the
        # bridge is local and the user just queried the same targets via
        # /api/discover seconds ago.
        unique_targets = sorted({(ep.get("target") or "").rstrip("/")
                                 for ep in endpoints
                                 if ep.get("target")} | set(targets))
        # target → {(METHOD, path): resource_dict}
        spec_index: dict[str, dict] = {}
        for tgt in unique_targets:
            if not tgt:
                continue
            try:
                _swurl, _spec = _discover_swagger_for(tgt, bearer)
            except Exception:
                _spec = None
            if not _spec:
                continue
            try:
                resources = _extract_resources(tgt, _spec)
            except Exception:
                resources = []
            spec_index[tgt] = {
                (r.get("method", "").upper(), r.get("path", "")): r for r in resources
            }

        for ep in endpoints:
            mtd = (ep.get("method") or "").upper()
            pth = ep.get("path") or ""
            tgt = (ep.get("target") or "").rstrip("/")
            res = spec_index.get(tgt, {}).get((mtd, pth))
            if not res:
                continue
            # Body hydration (only for body-bearing methods)
            if mtd.lower() in body_methods:
                cur = ep.get("payload")
                if (not isinstance(cur, str)) or not cur.strip():
                    eb = res.get("exampleBody")
                    if eb is not None:
                        try:
                            ep["payload"] = (eb if isinstance(eb, str)
                                             else json.dumps(eb, indent=2, ensure_ascii=False))
                        except Exception:
                            ep["payload"] = str(eb)
            # Carry through path / query example dicts so they end up in the
            # persisted config and the scenario for the analyzer.
            if not ep.get("pathParams") and res.get("examplePathParams"):
                ep["pathParams"] = dict(res["examplePathParams"])
            if not ep.get("queryParams") and res.get("exampleQueryParams"):
                ep["queryParams"] = dict(res["exampleQueryParams"])

        # Persist the user's per-endpoint configuration alongside the report
        # for future reference / debugging — does NOT modify the analyzer.
        # We expand path placeholders ({id} → 1) and append query strings
        # using the OpenAPI examples so the persisted file is human-readable
        # and self-explanatory. The original templated path is preserved
        # under ``pathTemplate`` for traceability. The scenario file built
        # below still uses the templated paths (the analyzer matches them
        # against the OpenAPI spec).
        from urllib.parse import urlencode, quote_plus
        import re as _re

        def _resolve_path(template, path_params, query_params):
            if not isinstance(template, str):
                return template
            out = template
            if isinstance(path_params, dict):
                out = _re.sub(
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
                    out = out + sep + urlencode(flat, quote_via=quote_plus)
            return out

        endpoints_persisted = []
        for ep in endpoints:
            ep_copy = dict(ep)
            tmpl = ep_copy.get("path", "")
            ep_copy["pathTemplate"] = tmpl
            ep_copy["path"] = _resolve_path(
                tmpl, ep_copy.get("pathParams"), ep_copy.get("queryParams")
            )
            endpoints_persisted.append(ep_copy)

        REPORTS.mkdir(exist_ok=True)
        cfg_path = REPORTS / "interactive-config.json"
        with cfg_path.open("w", encoding="utf-8") as f:
            json.dump({
                "targets": targets,
                "swaggers": swaggers,
                "appname": appname,
                "endpoints": endpoints_persisted,
                "repeat": max_calls,
            }, f, indent=2, ensure_ascii=False)

        # ── Build a "scenario" file consumed by the analyzer ──
        # The Python analyzer (green-api-auto-discover.py) honours a JSON
        # scenario with shape {pathParams: {<path>: {<name>: <value>}},
        # requestBodies: {<METHOD>:<path>: <payload>}}.  We translate the
        # user's UI choices into that shape so:
        #   • payloads typed in the textarea (or pre-filled from the OpenAPI
        #     example and possibly tweaked) are actually sent on POST/PUT/PATCH
        #   • path/query example values resolved by the dashboard are honoured
        # The analyzer reads this file when GREEN_INTERACTIVE_SCENARIO is set.
        scenario = {"pathParams": {}, "requestBodies": {}, "queryParams": {}}
        for ep in endpoints:
            mtd = (ep.get("method") or "").lower().strip()
            pth = ep.get("path") or ""
            if not mtd or not pth:
                continue
            # Body — only meaningful for POST/PUT/PATCH. Try JSON first so
            # the analyzer can re-serialise; fall back to the raw string.
            payload_raw = ep.get("payload")
            if mtd in ("post", "put", "patch") and isinstance(payload_raw, str) and payload_raw.strip():
                key = f"{mtd}:{pth}"
                try:
                    scenario["requestBodies"][key] = json.loads(payload_raw)
                except Exception:
                    scenario["requestBodies"][key] = payload_raw
            # Path params (carried through from /api/discover when present)
            ep_path_params = ep.get("pathParams") or ep.get("examplePathParams")
            if isinstance(ep_path_params, dict) and ep_path_params:
                scenario["pathParams"][pth] = {
                    str(k): v for k, v in ep_path_params.items()
                }
            # Required query params (same idea, optional in scenario shape)
            ep_query_params = ep.get("queryParams") or ep.get("exampleQueryParams")
            if isinstance(ep_query_params, dict) and ep_query_params:
                scenario["queryParams"][f"{mtd}:{pth}"] = {
                    str(k): v for k, v in ep_query_params.items()
                }
        scenario_path = REPORTS / ".interactive-scenario.json"
        with scenario_path.open("w", encoding="utf-8") as f:
            json.dump(scenario, f, indent=2, ensure_ascii=False)

        cmd = ["bash", str(ANALYZER_SH),
               "--targets", ",".join(targets),
               "--repeat", str(max_calls),
               "--output-dir", str(REPORTS)]
        if swaggers:
            cmd += ["--swaggers", ",".join(swaggers)]
        if bearer:
            cmd += ["--bearer", bearer]
        if appname:
            cmd += ["--appname", appname]

        # ── Live log streaming (mirror of /api/local-analyze) ────────
        # Write the analyzer's stdout+stderr to .analyzer.log while the
        # subprocess is blocked, so the dashboard can poll /api/analyze-log
        # in parallel and display a live console at the bottom of the page.
        log_file = REPORTS / ".analyzer.log"
        running_marker = REPORTS / ".analyzer.running"
        try: log_file.unlink(missing_ok=True)        # truncate (py3.8+)
        except TypeError:
            try: log_file.unlink()
            except Exception: pass
        try: running_marker.touch()
        except Exception: pass

        try:
            with open(str(log_file), "w", encoding="utf-8") as lf:
                lf.write("$ " + " ".join(cmd) + "\n")
                lf.flush()
                proc = subprocess.run(
                    cmd, cwd=str(ROOT),
                    stdout=lf, stderr=subprocess.STDOUT,
                    text=True, timeout=900,
                    env={**os.environ, "GREEN_INTERACTIVE_SCENARIO": str(scenario_path)},
                )
        except subprocess.TimeoutExpired:
            try: running_marker.unlink()
            except Exception: pass
            return self._send_json(504, {"error": "analyzer timeout (>15 min)"})
        except Exception as e:
            try: running_marker.unlink()
            except Exception: pass
            return self._send_json(500, {"error": f"failed to run analyzer: {e}"})
        finally:
            try: running_marker.unlink()
            except Exception: pass

        # Re-read the log file we just wrote — that's the canonical capture.
        try:
            with open(str(log_file), "r", encoding="utf-8", errors="replace") as lf:
                log = lf.read()
        except Exception:
            log = ""
        latest = REPORTS / "latest-report.json"
        if proc.returncode != 0 or not latest.is_file():
            return self._send_json(500, {
                "error": "analyzer failed",
                "exit_code": proc.returncode,
                "log": log[-8000:],
            })

        try:
            with latest.open("r", encoding="utf-8") as f:
                report = json.load(f)
        except Exception as e:
            return self._send_json(500, {"error": f"could not read report: {e}"})

        return self._send_json(200, {
            "ok": True,
            "report": report,
            "log_tail": log[-4000:],
            "config": {
                "targets": targets,
                "swaggers": swaggers,
                "appname": appname,
                "repeat": max_calls,
                "endpoints_selected": len(endpoints),
            },
        })

    # Keep server log compact
    def log_message(self, fmt, *args):
        sys.stderr.write("[bridge] %s - %s\n" % (self.address_string(), fmt % args))

    # ── /api/local-analyze ── (drives scripts/start.sh)
    def _handle_local_analyze(self, payload):
        """Run the canonical scripts/start.sh pipeline (Green Score + optional
        Creedengo source analysis) and return both reports."""
        targets   = payload.get("targets")   or []
        bearer    = (payload.get("bearer")   or "").strip()
        appname   = (payload.get("appname")  or "").strip()
        creedengo = bool(payload.get("creedengo"))
        git_repo   = (payload.get("gitRepo")    or "").strip()
        git_branch = (payload.get("gitBranch")  or "").strip()
        git_subdir = (payload.get("gitSubdir")  or "").strip()
        git_keep   = bool(payload.get("gitKeep"))
        debug      = bool(payload.get("debug"))
        # New: stack selector + local source folder + build-and-run toggle
        stack         = (payload.get("stack")     or "auto").strip().lower()
        source_dir    = (payload.get("sourceDir") or "").strip()
        build_and_run = bool(payload.get("buildAndRun"))
        # Architecture rules (AR02 Phase 3 / AR05) — optional from UI
        consumer_region          = (payload.get("consumerRegion") or "").strip()
        enable_geoip             = bool(payload.get("enableGeoip"))
        cloud_footprint_confirmed = bool(payload.get("cloudFootprintConfirmed"))

        if stack not in ("auto", "java", "dotnet"):
            return self._send_json(400, {"error": f"invalid stack: {stack!r} (expected auto|java|dotnet)"})
        if source_dir:
            sd = Path(source_dir)
            if not sd.is_dir():
                return self._send_json(400, {"error": f"sourceDir not found: {source_dir}"})
        if build_and_run and not source_dir:
            return self._send_json(400, {"error": "buildAndRun=true requires sourceDir"})

        targets = [t.strip().rstrip("/") for t in targets if t and t.strip()]
        if not targets and not git_repo and not build_and_run:
            return self._send_json(400, {
                "error": "either targets[] or gitRepo or buildAndRun is required"
            })

        start_sh = SCRIPTS / "start.sh"
        if not start_sh.is_file():
            return self._send_json(500, {"error": f"start.sh not found: {start_sh}"})

        cmd = ["bash", str(start_sh)]
        if debug:
            cmd.append("--debug")
        if appname:
            cmd += ["--appname", appname]
        if bearer:
            cmd += ["--bearer", bearer]
        # Pass the endpoints API as a single comma-separated --targets csv
        # (start.sh and the analyzer wrapper both accept this form, and it
        # keeps the argv short & explicit in the logs).
        if targets:
            cmd += ["--targets", ",".join(targets)]
        if creedengo or git_repo:
            cmd.append("--creedengo")
        if git_repo:
            cmd += ["--git-repo", git_repo]
        if git_branch:
            cmd += ["--git-branch", git_branch]
        if git_subdir:
            cmd += ["--git-subdir", git_subdir]
        if git_keep:
            cmd.append("--git-keep")
        # Stack + local source folder + build-and-run forwarding
        if stack and stack != "auto":
            cmd += ["--stack", stack]
        if source_dir:
            cmd += ["--source-dir", source_dir]
        if build_and_run:
            cmd.append("--build-and-run")
        # AR02 / AR05 forwarding
        if consumer_region:
            cmd += ["--consumer-region", consumer_region]
        if enable_geoip:
            cmd.append("--enable-geoip")
        if cloud_footprint_confirmed:
            cmd.append("--cloud-footprint-confirmed")

        REPORTS.mkdir(exist_ok=True)
        latest = REPORTS / "latest-report.json"
        creedengo_path = REPORTS / "creedengo-report.json"
        creedengo_requested = bool(creedengo or git_repo)

        # ── Force a clean regeneration ────────────────────────────
        # Delete the reports we EXPECT to be regenerated by this run so the
        # UI never shows leftovers from a previous interactive (remote) run
        # or a previous start.sh run. We only delete the categories the user
        # actually asked for — e.g. don't wipe creedengo-report.json if the
        # user didn't enable Creedengo on this run.
        try:
            if latest.is_file():
                latest.unlink()
        except Exception:
            pass
        if creedengo_requested:
            try:
                if creedengo_path.is_file():
                    creedengo_path.unlink()
            except Exception:
                pass

        # Persist the request for traceability
        with (REPORTS / "interactive-local-config.json").open("w", encoding="utf-8") as f:
            # Mask the bearer in the persisted file
            safe = dict(payload)
            if safe.get("bearer"):
                safe["bearer"] = "***"
            json.dump({"argv": cmd, "request": safe}, f, indent=2, ensure_ascii=False)

        # ── Live log streaming ────────────────────────────────────
        # Write start.sh's stdout+stderr to a known file that the dashboard
        # can poll via GET /api/local-log while we're still blocked on
        # subprocess. The bridge uses ThreadingHTTPServer so polling works
        # in parallel with the running analysis.
        log_file = REPORTS / ".start-sh.log"
        running_marker = REPORTS / ".start-sh.running"
        try: log_file.unlink(missing_ok=True)        # truncate
        except TypeError:                             # py<3.8 fallback
            try: log_file.unlink()
            except Exception: pass
        try: running_marker.touch()
        except Exception: pass

        log_buf_path = str(log_file)
        try:
            with open(log_buf_path, "w", encoding="utf-8") as lf:
                lf.write("$ " + " ".join(cmd) + "\n")
                lf.flush()
                # Tell start.sh we're driving it from the interactive UI so it
                # skips its trailing 5-minute SonarQube countdown — that wait
                # is meant for human Ctrl+C, not for an automated run.
                env = os.environ.copy()
                env["INTERACTIVE_BRIDGE"] = "1"
                proc = subprocess.run(
                    cmd, cwd=str(ROOT), env=env,
                    stdout=lf, stderr=subprocess.STDOUT,
                    text=True, timeout=600,  # 10 min
                )
        except subprocess.TimeoutExpired:
            try: running_marker.unlink()
            except Exception: pass
            return self._send_json(504, {"error": "start.sh timeout (>10 min)"})
        except Exception as e:
            try: running_marker.unlink()
            except Exception: pass
            return self._send_json(500, {"error": f"failed to run start.sh: {e}"})
        finally:
            try: running_marker.unlink()
            except Exception: pass

        # Re-read the log file we just wrote — that's the canonical capture.
        try:
            with open(log_buf_path, "r", encoding="utf-8", errors="replace") as lf:
                log = lf.read()
        except Exception:
            log = ""

        # Reports are "fresh" if they exist after the run (we deleted the
        # ones we expected to regenerate before launching, so any file
        # present now is necessarily from this run).
        report = None
        report_fresh = False
        if latest.is_file():
            try:
                with latest.open("r", encoding="utf-8") as f:
                    report = json.load(f)
                report_fresh = True
            except Exception:
                report = None

        creedengo_report = None
        creedengo_fresh = False
        if creedengo_path.is_file():
            try:
                with creedengo_path.open("r", encoding="utf-8") as f:
                    creedengo_report = json.load(f)
                # Only count it as "fresh" if the user actually asked for it
                # this run. If the user did not request Creedengo, an existing
                # file is leftover state from a previous run and must NOT be
                # surfaced as part of this run's results.
                creedengo_fresh = creedengo_requested
                if not creedengo_requested:
                    creedengo_report = None
            except Exception:
                creedengo_report = None

        # If everything failed AND we don't even have a green-score report,
        # surface the error to the UI.
        if proc.returncode != 0 and report is None:
            return self._send_json(500, {
                "error": "start.sh failed",
                "exit_code": proc.returncode,
                "log": log[-12000:],
            })

        # ── SobriIT integration (conditional) ──
        sobriit_result = None
        if payload.get("sendToSobriit"):
            try:
                sobriit_result = _sobriit_send(
                    appname=appname,
                    green_report=report,
                    creedengo_report=creedengo_report,
                    base_url=payload.get("sobriitBaseUrl"),
                    api_key=payload.get("sobriitApiKey"),
                )
            except Exception as e:
                sobriit_result = {"ok": False, "error": str(e)}

        return self._send_json(200, {
            "ok": True,
            "report": report,
            "report_fresh": report_fresh,
            "creedengo": creedengo_report,
            "creedengo_fresh": creedengo_fresh,
            "creedengo_requested": creedengo_requested,
            "exit_code": proc.returncode,
            "log_tail": log[-8000:],
            "sobriit": sobriit_result,
            "config": {
                "targets": targets,
                "appname": appname,
                "creedengo": creedengo_requested,
                "git_repo": git_repo,
                "git_branch": git_branch,
                "git_subdir": git_subdir,
                "stack": stack,
                "source_dir": source_dir,
                "build_and_run": build_and_run,
                "source": "start.sh",
            },
        })


# ─── Entry point ────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description="Green API Analyzer interactive bridge")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--open", action="store_true", help="Open the dashboard in the default browser")
    args = p.parse_args()

    # Force UTF-8 stdout (matches existing analyzer convention)
    if sys.stdout.encoding and sys.stdout.encoding.lower().replace("-", "") != "utf8":
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}/"
    print(f"🌿 Interactive Green API Analyzer ready: {url}")
    print(f"   ROOT = {ROOT}")
    print(f"   ANALYZER = {ANALYZER_SH}")
    if args.open:
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception:
            pass
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Stopped.")
        httpd.server_close()


if __name__ == "__main__":
    main()


