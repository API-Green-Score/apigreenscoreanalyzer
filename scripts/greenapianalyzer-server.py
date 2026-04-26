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
    """Flatten an OpenAPI spec into a list of {target, method, path, summary, …}."""
    out: list[dict] = []
    base_path = ""
    if spec.get("swagger") == "2.0":
        base_path = spec.get("basePath", "") or ""
    paths = spec.get("paths") or {}
    for path, ops in paths.items():
        if not isinstance(ops, dict):
            continue
        full_path = (base_path + path) if base_path else path
        for method in ("get", "post", "put", "patch", "delete", "head"):
            if method not in ops or not isinstance(ops.get(method), dict):
                continue
            op = ops[method]
            tags = op.get("tags") or []
            out.append({
                "target": target,
                "method": method.upper(),
                "path": full_path,
                "operationId": op.get("operationId", ""),
                "summary": op.get("summary", "") or op.get("description", "")[:140],
                "tags": tags,
                "hasBody": method in ("post", "put", "patch"),
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

        # Persist the user's per-endpoint configuration alongside the report
        # for future reference / debugging — does NOT modify the analyzer.
        REPORTS.mkdir(exist_ok=True)
        cfg_path = REPORTS / "interactive-config.json"
        with cfg_path.open("w", encoding="utf-8") as f:
            json.dump({
                "targets": targets,
                "swaggers": swaggers,
                "appname": appname,
                "endpoints": endpoints,
                "repeat": max_calls,
            }, f, indent=2, ensure_ascii=False)

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

        try:
            proc = subprocess.run(
                cmd, cwd=str(ROOT),
                capture_output=True, text=True, timeout=900,
            )
        except subprocess.TimeoutExpired:
            return self._send_json(504, {"error": "analyzer timeout (>15 min)"})
        except Exception as e:
            return self._send_json(500, {"error": f"failed to run analyzer: {e}"})

        log = (proc.stdout or "") + "\n" + (proc.stderr or "")
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

