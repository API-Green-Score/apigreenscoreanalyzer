#!/usr/bin/env python3
"""
Green API Auto-Discover & Analyzer
===================================
1. Discovers routes from a running API (OpenAPI/Swagger endpoint or file)
2. Runs Spectral linting against Green API rules
3. Measures every discovered endpoint (response time, payload size)
4. Computes Green Score + energy estimates
5. Generates a report compatible with the dashboard (index.html)

Usage (standalone):
    python green-api-auto-discover.py --target http://localhost:8081

Usage (with explicit swagger):
    python green-api-auto-discover.py --target http://localhost:8081 \
        --swagger http://localhost:8081/v3/api-docs

Usage (dry-run, no HTTP calls):
    python green-api-auto-discover.py --swagger ./my-spec.yaml --dry-run
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# Local module: Architecture/Infrastructure rules (AR01..AR05)
sys.path.insert(0, str(Path(__file__).parent))
try:
    from architecture_rules import (
        evaluate_architecture_rules,
        ARCH_RULES as _ARCH_RULES_CATALOGUE,
    )
    _ARCH_RULES_AVAILABLE = True
except Exception as _arch_imp_err:  # pragma: no cover
    _ARCH_RULES_AVAILABLE = False
    _ARCH_RULES_IMPORT_ERROR = str(_arch_imp_err)

# ── Fix Windows console encoding (CP1252 → UTF-8) ──────────────────────────
# On Windows, the default stdout/stderr encoding is often CP1252 which cannot
# handle emojis (✅, ❌, 🟢, …).  Force UTF-8 with replace fallback so that
# print() never crashes even on non-UTF-8 terminals.
if sys.stdout.encoding and sys.stdout.encoding.lower().replace("-", "") != "utf8":
    sys.stdout = io.TextIOWrapper(
        sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True,
    )
if sys.stderr.encoding and sys.stderr.encoding.lower().replace("-", "") != "utf8":
    sys.stderr = io.TextIOWrapper(
        sys.stderr.buffer, encoding="utf-8", errors="replace", line_buffering=True,
    )

try:
    import yaml  # type: ignore
except Exception:
    yaml = None

# ─── Constants ──────────────────────────────────────────────────────────────

SWAGGER_DISCOVERY_PATHS = [
    "/api/v3/api-docs",       # springdoc-openapi with /api/ prefix (ESignPay)
    "/v3/api-docs",           # springdoc-openapi (Spring Boot) — priority
    "/v3/api-docs.yaml",      # springdoc YAML variant
    "/swagger-ui/index.html",  # springdoc UI (to confirm it exists)
    "/v2/api-docs",           # springfox legacy
    "/openapi.json",          # generic
    "/openapi.yaml",
    "/swagger/v1/swagger.json",  # .NET / Swashbuckle
    "/swagger.json",
    "/swagger.yaml",
]

GREEN_RULES = {
    "DE11_pagination": {
        "id": "DE11", "label": "Pagination", "max_pts": 15,
        "check": "collection_has_pagination_params",
        "description": "Les endpoints de collection doivent supporter la pagination (page/size ou limit/offset).",
        "category": "data-efficiency",
    },
    "DE08_fields": {
        "id": "DE08", "label": "Filtrage de champs", "max_pts": 15,
        "check": "has_fields_param",
        "description": "Supporter un parametre 'fields' pour reduire le payload.",
        "category": "data-efficiency",
    },
    "DE01_compression": {
        "id": "DE01", "label": "Compression", "max_pts": 15,
        "check": "server_supports_gzip",
        "description": "Le serveur doit supporter Accept-Encoding: gzip.",
        "category": "data-efficiency",
    },
    "DE02_DE03_cache": {
        "id": "DE02/DE03", "label": "Cache ETag/304", "max_pts": 15,
        "check": "supports_etag_304",
        "description": "Les ressources unitaires doivent supporter ETag + If-None-Match -> 304.",
        "category": "data-efficiency",
    },
    "DE06_delta": {
        "id": "DE06", "label": "Delta / Changes", "max_pts": 10,
        "check": "has_delta_endpoint",
        "description": "Un endpoint /changes?since= ou equivalent doit exister.",
        "category": "data-efficiency",
    },
    "range_206": {
        "id": "206", "label": "Range / Partial Content", "max_pts": 10,
        "check": "supports_range_206",
        "description": "Supporter le header Range pour les gros payloads.",
        "category": "data-efficiency",
    },
    "AR02_format_cbor": {
        # NOTE: rule id renamed BIN01 (was "AR02") to free the official
        # APIGreenScore AR02 (= "API runtime close to consumer"). The internal
        # rule key is kept unchanged so legacy reports remain readable.
        "id": "BIN01", "label": "Format binaire (CBOR)", "max_pts": 10,
        "check": "has_binary_format",
        "description": "Un endpoint en format binaire (CBOR, protobuf...) doit exister.",
        "category": "data-efficiency",
    },
    "LO01_observability": {
        "id": "LO01", "label": "Observabilite", "max_pts": 5,
        "check": "has_actuator",
        "description": "Actuator / health / metrics doit etre expose.",
        "category": "logs-observability",
    },
    "US07_rate_limit": {
        "id": "US07", "label": "Rate Limiting", "max_pts": 5,
        "check": "assumed_if_running",
        "description": "Un mecanisme de rate limiting doit etre present.",
        "category": "usage",
    },

    # ── Architecture & Infrastructure (APIGreenScore official AR rules) ──
    # Weights confirmed by the user (Option A): AR01=6, AR02=7, AR03=3,
    # AR04=5, AR05=2 → +23 pts on top of the 100-pts legacy budget.
    "AR01_event_driven": {
        "id": "AR01", "label": "Architecture événementielle", "max_pts": 6,
        "check": "external_arch_rules", "category": "architecture",
        "description": "Utiliser une architecture événementielle (callbacks, webhooks, AsyncAPI, SSE, WebSocket, broker) pour éviter le polling.",
    },
    "AR02_runtime_close": {
        "id": "AR02", "label": "Runtime proche du consommateur", "max_pts": 7,
        "check": "external_arch_rules", "category": "architecture",
        "description": "Déployer l'API au plus près des consommateurs (CDN, edge, anycast multi-régions).",
    },
    "AR03_unique_api": {
        "id": "AR03", "label": "Une seule API par besoin", "max_pts": 3,
        "check": "external_arch_rules", "category": "architecture",
        "description": "Éviter la duplication d'APIs servant le même besoin (double infrastructure = double empreinte).",
    },
    "AR04_scalable_infra": {
        "id": "AR04", "label": "Infrastructure scalable", "max_pts": 5,
        "check": "external_arch_rules", "category": "infrastructure",
        "description": "Préférer une infrastructure auto-scalable (HPA, KEDA, autoscale, serverless).",
    },
    "AR05_cloud_footprint": {
        "id": "AR05", "label": "Dashboard d'empreinte cloud", "max_pts": 2,
        "check": "external_arch_rules", "category": "infrastructure",
        "description": "Suivre l'empreinte carbone via le dashboard natif du provider cloud.",
    },
}

DEFAULT_NETWORK_KWH_PER_GB = 0.06
DEFAULT_SERVER_POWER_W = 25.0

# ─── Helpers ────────────────────────────────────────────────────────────────

def log(msg, level="INFO"):
    colors = {"INFO": "\033[0;36m", "OK": "\033[0;32m", "WARN": "\033[1;33m", "ERR": "\033[0;31m"}
    nc = "\033[0m"
    c = colors.get(level, "")
    print(f"{c}[{level}]{nc} {msg}", file=sys.stderr)


def http_get(url, headers=None, timeout=10):
    """Simple GET, returns (status, body_bytes, headers_dict)."""
    hdrs = headers or {}
    req = urllib.request.Request(url, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            resp_headers = {k.lower(): v for k, v in resp.getheaders()}
            return resp.status, body, resp_headers
    except urllib.error.HTTPError as e:
        body = e.read() if hasattr(e, "read") else b""
        return e.code, body, {}
    except Exception:
        return 0, b"", {}


def http_head(url, headers=None, timeout=10):
    hdrs = headers or {}
    req = urllib.request.Request(url, method="HEAD", headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp_headers = {k.lower(): v for k, v in resp.getheaders()}
            return resp.status, resp_headers
    except urllib.error.HTTPError as e:
        return e.code, {}
    except Exception:
        return 0, {}


def parse_spec_text(text, source_label):
    try:
        return json.loads(text)
    except Exception:
        if yaml is not None:
            try:
                return yaml.safe_load(text)
            except Exception:
                pass
        raise ValueError(f"Cannot parse OpenAPI spec from {source_label}")


def load_spec(source):
    if source.startswith("http://") or source.startswith("https://"):
        status, body, _ = http_get(source, timeout=15)
        if status == 200 and body:
            return parse_spec_text(body.decode("utf-8", errors="replace"), source)
        raise ValueError(f"HTTP {status} fetching {source}")
    with open(source, "r", encoding="utf-8") as f:
        return parse_spec_text(f.read(), source)


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def bytes_to_wh(size_bytes, kwh_per_gb):
    return (size_bytes / (1024**3)) * kwh_per_gb * 1000


def seconds_to_wh(seconds, power_w):
    return seconds * (power_w / 3600)


def format_bytes(b):
    if b < 1024:
        return f"{b} B"
    if b < 1024**2:
        return f"{b/1024:.1f} KB"
    if b < 1024**3:
        return f"{b/1024**2:.1f} MB"
    return f"{b/1024**3:.2f} GB"

# ─── Step 1: Discover Swagger ──────────────────────────────────────────────

def discover_swagger(base_url):
    """Try common OpenAPI endpoints to find the spec."""
    log(f"Discovering OpenAPI spec on {base_url}...")
    for path in SWAGGER_DISCOVERY_PATHS:
        url = base_url.rstrip("/") + path
        status, body, hdrs = http_get(url, timeout=5)
        if status == 200 and body and len(body) > 50:
            log(f"Found spec at {url}", "OK")
            try:
                return parse_spec_text(body.decode("utf-8", errors="replace"), url), url
            except ValueError:
                continue
    return None, None


# ─── OpenAPI example extraction helpers ────────────────────────────────────
#
# When the API spec ships examples (for parameters, request bodies, or
# schemas), we use them to drive realistic resource calls. This is critical
# for POST/PUT/PATCH endpoints which would otherwise fail validation with
# 400/415, distorting the Green Score measurements.
#
# Resolution chain we follow (per piece of data):
#   1. Explicit OpenAPI `example` on the field/parameter/media-type
#   2. First entry of `examples` (OpenAPI 3 multi-example map)
#   3. `schema.example` / `schema.default`
#   4. Synthesised value walking the JSON Schema (object → properties)
#
# All `$ref` inside the spec are resolved with a tiny in-memory walker
# (`_resolve_ref`) so we don't pull `jsonschema` / `prance` as dependencies.

_REF_MAX_DEPTH = 6  # guard against cyclic schemas


def _resolve_ref(spec, ref):
    """Resolve a local `#/...` JSON pointer in *spec*. Returns {} on miss."""
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return {}
    node = spec
    for part in ref[2:].split("/"):
        # JSON Pointer unescape
        part = part.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            return {}
    return node if isinstance(node, dict) else {}


def _deref(spec, node, _seen=None, _depth=0):
    """Follow `$ref` once (non-recursively unwraps a single pointer)."""
    if not isinstance(node, dict):
        return node
    ref = node.get("$ref")
    if not ref or _depth >= _REF_MAX_DEPTH:
        return node
    seen = _seen or set()
    if ref in seen:
        return {}
    seen = seen | {ref}
    return _deref(spec, _resolve_ref(spec, ref), seen, _depth + 1)


def _example_from_schema(spec, schema, _depth=0):
    """Synthesize a JSON-serialisable example from a JSON Schema.

    Honours, in order: ``example`` / ``default`` / ``enum[0]`` / type-aware
    fallback. Walks ``properties`` for objects and uses the first item of
    ``items`` for arrays. Returns ``None`` when no example can be inferred.
    """
    if _depth > _REF_MAX_DEPTH or not isinstance(schema, dict):
        return None
    schema = _deref(spec, schema, _depth=_depth)

    if "example" in schema:
        return schema["example"]
    if "default" in schema:
        return schema["default"]
    if isinstance(schema.get("enum"), list) and schema["enum"]:
        return schema["enum"][0]

    # composed schemas — pick the first branch
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
        # Always emit required props; for optional ones we only emit when an
        # example/default is reachable to keep the payload minimal.
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


def _scalar_for_type(schema):
    """Best-effort scalar placeholder when no example is provided."""
    if not isinstance(schema, dict):
        return None
    t = schema.get("type")
    fmt = schema.get("format", "")
    if t == "string":
        if fmt == "date":
            return "2024-01-01"
        if fmt == "date-time":
            return "2024-01-01T00:00:00Z"
        if fmt == "uuid":
            return "00000000-0000-0000-0000-000000000000"
        if fmt == "email":
            return "user@example.com"
        if fmt in ("byte", "binary", "password"):
            return ""
        return "string"
    if t == "integer":
        return 1
    if t == "number":
        return 1.0
    if t == "boolean":
        return True
    if t == "array":
        return []
    if t == "object":
        return {}
    return None


def _param_example(spec, param):
    """Extract an example value from an OpenAPI parameter object."""
    param = _deref(spec, param)
    if not isinstance(param, dict):
        return None
    if "example" in param:
        return param["example"]
    examples = param.get("examples")
    if isinstance(examples, dict) and examples:
        first = next(iter(examples.values()))
        first = _deref(spec, first)
        if isinstance(first, dict) and "value" in first:
            return first["value"]
    schema = param.get("schema") or {}
    if param.get("type") and not schema:  # Swagger 2.0 inline type
        schema = {k: param[k] for k in ("type", "format", "enum", "default", "example")
                  if k in param}
    ex = _example_from_schema(spec, schema)
    return ex


def _request_body_example(spec, op):
    """Best-effort example payload for an operation's request body.

    Supports OpenAPI 3 (``requestBody.content``) and Swagger 2.0
    (``parameters[in=body].schema``).
    """
    # OpenAPI 3
    rb = _deref(spec, op.get("requestBody") or {})
    content = rb.get("content") if isinstance(rb, dict) else None
    if isinstance(content, dict) and content:
        # Prefer JSON, then any media type
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

    # Swagger 2.0 — body comes through `parameters[in=body]`
    for p in op.get("parameters") or []:
        p = _deref(spec, p)
        if isinstance(p, dict) and p.get("in") == "body":
            if "example" in p:
                return p["example"]
            return _example_from_schema(spec, p.get("schema") or {})
    return None


def extract_endpoints(spec, base_url=""):
    """Extract all endpoints with their methods and parameters from the spec.

    Each endpoint is stamped with ``_base_url`` so we know which target server
    to call when measuring it (multi-target support).

    We also pre-compute, from any OpenAPI ``example`` / ``examples`` /
    ``schema.default`` shipped in the spec:
      - ``_example_path_params`` — dict of path param → value
      - ``_example_query_params`` — dict of *required* query param → value
      - ``_example_body`` — JSON-serialisable payload for POST/PUT/PATCH

    The runtime measurement loop uses these as a fallback when the optional
    test scenario doesn't ship an explicit value, so resource calls are made
    with realistic payloads instead of failing 400/415.
    """
    endpoints = []
    base_path = ""
    # Swagger 2.0
    if spec.get("swagger") == "2.0":
        base_path = spec.get("basePath", "")
    for path, ops in (spec.get("paths") or {}).items():
        full_path = base_path + path if base_path else path
        for method in ("get", "post", "put", "patch", "delete", "head"):
            if method not in ops:
                continue
            op = ops[method]
            params = op.get("parameters") or []
            # Merge path-level parameters
            if isinstance(ops.get("parameters"), list):
                param_names = {p.get("name") for p in params}
                for p in ops["parameters"]:
                    if p.get("name") not in param_names:
                        params.append(p)

            # ── Pre-compute examples from the spec ──
            example_path_params = {}
            example_query_params = {}
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

            endpoints.append({
                "path": full_path,
                "method": method,
                "operationId": op.get("operationId", f"{method}_{full_path}"),
                "summary": op.get("summary", ""),
                "parameters": params,
                "tags": op.get("tags", []),
                "produces": op.get("produces", []),
                "responses": op.get("responses", {}),
                "requestBody": op.get("requestBody"),
                "_base_url": base_url or "",
                "_example_path_params": example_path_params,
                "_example_query_params": example_query_params,
                "_example_body": example_body,
            })
    return endpoints


def merge_specs(sources):
    """Merge several (base_url, spec, source_label) tuples into a single OpenAPI
    document used as the unified *discovery resource*.

    Path collisions across targets are resolved by keeping the first occurrence
    and storing subsequent ones under a synthetic prefix ``/__t<i>__/<path>``
    so that every operation remains addressable in the merged spec.  Each path
    item is also annotated with ``x-source-base-url`` for traceability.
    """
    merged = {
        "openapi": "3.0.3",
        "info": {
            "title": "Merged Green Analyzer discovery",
            "version": "1.0.0",
            "description": (
                "Aggregated OpenAPI specs discovered from "
                f"{len(sources)} target(s): "
                + ", ".join(s[0] or s[2] for s in sources)
            ),
        },
        "servers": [{"url": s[0]} for s in sources if s[0]],
        "paths": {},
        "x-discovery-sources": [
            {"base_url": b, "swagger_source": src} for (b, _spec, src) in sources
        ],
    }
    for idx, (base_url, spec, _src_label) in enumerate(sources):
        base_path = ""
        if spec.get("swagger") == "2.0":
            base_path = spec.get("basePath", "")
        for path, ops in (spec.get("paths") or {}).items():
            full_path = (base_path + path) if base_path else path
            target_path = full_path
            if target_path in merged["paths"]:
                target_path = f"/__t{idx}__{full_path}"
            try:
                ops_copy = dict(ops)
            except Exception:
                ops_copy = ops
            if isinstance(ops_copy, dict):
                ops_copy["x-source-base-url"] = base_url
                ops_copy["x-source-original-path"] = full_path
            merged["paths"][target_path] = ops_copy
    return merged


# ─── Step 2: Spectral Linting ──────────────────────────────────────────────

def _ensure_spectral_installed():
    """Return the command prefix to invoke Spectral, installing it if needed."""
    spectral_bin = shutil.which("spectral")
    if spectral_bin:
        return [spectral_bin]

    npx_bin = shutil.which("npx")
    if npx_bin:
        # Check whether the package is already available via npx
        try:
            probe = subprocess.run(
                [npx_bin, "--yes", "@stoplight/spectral-cli", "--version"],
                capture_output=True, text=True, timeout=120,
            )
            if probe.returncode == 0:
                return [npx_bin, "--yes", "@stoplight/spectral-cli"]
        except Exception:
            pass

    npm_bin = shutil.which("npm")
    if npm_bin:
        log("Spectral CLI not found — installing globally via npm…", "WARN")
        try:
            subprocess.run(
                [npm_bin, "install", "-g", "@stoplight/spectral-cli"],
                capture_output=True, text=True, timeout=120, check=True,
            )
            spectral_bin = shutil.which("spectral")
            if spectral_bin:
                log("Spectral installed successfully", "OK")
                return [spectral_bin]
        except Exception as e:
            log(f"npm global install failed ({e}), trying npx…", "WARN")

    if npx_bin:
        return [npx_bin, "--yes", "@stoplight/spectral-cli"]

    return None


def run_spectral(spec_source, spectral_config, output_file):
    """Run Spectral CLI. Returns list of issues or None.

    If *spectral_config* is None/empty the built-in ``spectral:oas``
    ruleset is used so that linting always executes.
    """
    cmd_prefix = _ensure_spectral_installed()
    if not cmd_prefix:
        log("Spectral CLI not found and could not be installed "
            "(install: npm i -g @stoplight/spectral-cli). Skipping lint.", "ERR")
        return None

    cmd = cmd_prefix + ["lint", spec_source, "--format", "json", "--output", output_file]
    if spectral_config:
        cmd += ["--ruleset", spectral_config]
    # else: Spectral uses its built-in spectral:oas ruleset

    log(f"Running Spectral: {' '.join(cmd)}")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if os.path.isfile(output_file):
            with open(output_file, "r", encoding="utf-8") as f:
                issues = json.load(f)
            log(f"Spectral found {len(issues)} issue(s)", "OK" if len(issues) == 0 else "WARN")
            return issues
        # Spectral may output to stdout on some versions
        if result.stdout.strip().startswith("["):
            issues = json.loads(result.stdout)
            with open(output_file, "w", encoding="utf-8") as f:
                json.dump(issues, f, indent=2)
            return issues
        # If output file is missing and no JSON on stdout, log stderr
        if result.stderr.strip():
            log(f"Spectral stderr: {result.stderr[:500]}", "WARN")
    except subprocess.TimeoutExpired:
        log("Spectral timed out after 120 s", "ERR")
    except Exception as e:
        log(f"Spectral error: {e}", "ERR")
    return None


# ─── Step 3: Measure Endpoints ─────────────────────────────────────────────

def measure_endpoint(url, method="GET", headers=None, repeat=3, timeout=30, body=None):
    """Measure an endpoint: avg response time, avg payload size, status.

    If *body* is provided (dict or str), it is sent as JSON with the
    appropriate Content-Type header for POST/PUT/PATCH methods.
    """
    total_time = 0.0
    total_bytes = 0
    last_status = 0
    last_headers = {}
    hdrs = dict(headers or {})

    body_bytes = None
    if body is not None:
        if isinstance(body, (dict, list)):
            body_bytes = json.dumps(body).encode("utf-8")
        elif isinstance(body, str):
            body_bytes = body.encode("utf-8")
        else:
            body_bytes = body
        hdrs.setdefault("Content-Type", "application/json")

    for _ in range(max(1, repeat)):
        req = urllib.request.Request(url, method=method.upper(), headers=hdrs, data=body_bytes)
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                resp_body = resp.read()
                elapsed = time.perf_counter() - start
                last_status = resp.status
                last_headers = {k.lower(): v for k, v in resp.getheaders()}
                total_time += elapsed
                total_bytes += len(resp_body)
        except urllib.error.HTTPError as e:
            elapsed = time.perf_counter() - start
            last_status = e.code
            resp_body = e.read() if hasattr(e, "read") else b""
            total_time += elapsed
            total_bytes += len(resp_body)
        except Exception:
            elapsed = time.perf_counter() - start
            total_time += elapsed

    n = max(1, repeat)
    return {
        "http_code": last_status,
        "size_download": int(total_bytes / n),
        "time_total": round(total_time / n, 6),
        "speed_download": int((total_bytes / n) / max(total_time / n, 0.001)),
        "response_headers": last_headers,
    }


def build_url(base, path, user_params, query_params=None):
    """Build a callable URL, filling path params and required query params.

    *query_params* (optional) is a dict of query name → value appended as a
    query string. Existing ``?`` in *path* is preserved.
    """
    filled = re.sub(r"\{([^}]+)\}", lambda m: str(user_params.get(m.group(1), "1")), path)
    url = base.rstrip("/") + (filled if filled.startswith("/") else "/" + filled)
    if query_params:
        try:
            from urllib.parse import urlencode, quote_plus
            # Stringify non-scalar values as JSON so arrays/objects survive.
            flat = {}
            for k, v in query_params.items():
                if isinstance(v, (dict, list)):
                    flat[k] = json.dumps(v)
                elif v is None:
                    continue
                else:
                    flat[k] = v
            if flat:
                sep = "&" if "?" in url else "?"
                url = url + sep + urlencode(flat, quote_via=quote_plus)
        except Exception:
            pass
    return url


# ─── Step 4: Green Score Analysis (static + runtime) ──────────────────────

def analyze_green_rules(spec, endpoints, base_url, measurements, auth_headers):
    """Analyze Green API rules against the spec and live measurements.

    Produces a **bidirectional mapping** between rules and API resources:
      - ``rule_resource_mapping``: for each rule → list of candidate endpoints
        with ``matched`` status and ``reason``.
      - ``endpoint_rules``: reverse index — for each endpoint → list of rules
        that reference it.

    A rule is *validated* when **at least one** of its candidate endpoints
    matches the check.  One endpoint can appear in several rules.
    """
    scores = {}
    details = {}
    mapping = {}  # rule_key -> { ...rule meta, candidates: [...] }

    # ── helpers ──────────────────────────────────────────────────────────

    def _init_rule(rule_key):
        """Ensure the rule entry exists in *mapping*."""
        if rule_key not in mapping:
            r = GREEN_RULES[rule_key]
            mapping[rule_key] = {
                "id": r["id"],
                "label": r["label"],
                "description": r["description"],
                "max_pts": r["max_pts"],
                "candidates": [],
            }

    def register(rule_key, method, path, matched, reason):
        """Register an endpoint as candidate for *rule_key*."""
        _init_rule(rule_key)
        mapping[rule_key]["candidates"].append({
            "method": method.upper(),
            "path": path,
            "matched": matched,
            "reason": reason,
        })

    def _matched_count(rule_key):
        return sum(1 for c in mapping.get(rule_key, {}).get("candidates", [])
                   if c["matched"])

    # ── categorise endpoints ─────────────────────────────────────────────

    collection_eps = [
        e for e in endpoints
        if e["method"] == "get" and "{" not in e["path"]
        and not e["path"].endswith("/health")
    ]
    single_eps = [
        e for e in endpoints
        if e["method"] == "get" and "{" in e["path"]
    ]
    all_get_eps = [e for e in endpoints if e["method"] == "get"]

    # ═══════════════════════════════════════════════════════════════════
    # DE11 — Pagination
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("DE11_pagination")
    for e in collection_eps:
        pnames = {p.get("name", "").lower() for p in e.get("parameters", [])}
        pag = pnames & {"page", "size", "limit", "offset", "cursor"}
        register(
            "DE11_pagination", e["method"], e["path"], bool(pag),
            f"Pagination params: {', '.join(sorted(pag))}" if pag
            else "No pagination params (page/size/limit/offset/cursor)",
        )
    n = _matched_count("DE11_pagination")
    scores["DE11_pagination"] = 15 if n else 0
    details["DE11_pagination"] = {
        "note": f"Pagination on {n}/{len(collection_eps)} collection endpoint(s)" if n
        else "No pagination on collection endpoints",
    }

    # ═══════════════════════════════════════════════════════════════════
    # DE08 — Field filtering
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("DE08_fields")
    for e in all_get_eps:
        pnames = {p.get("name", "").lower() for p in e.get("parameters", [])}
        fp = pnames & {"fields", "select"}
        has_select_path = "/select" in e["path"]
        matched = bool(fp) or has_select_path
        reason = (
            f"Field filter params: {', '.join(sorted(fp))}" if fp
            else "Path contains /select" if has_select_path
            else "No field filter param (fields/select)"
        )
        register("DE08_fields", e["method"], e["path"], matched, reason)
    n = _matched_count("DE08_fields")
    scores["DE08_fields"] = 15 if n else 0
    details["DE08_fields"] = {
        "note": f"Field filtering on {n} endpoint(s)" if n
        else "No field filter found",
    }

    # ═══════════════════════════════════════════════════════════════════
    # DE01 — Compression (gzip)
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("DE01_compression")
    gzip_ok = False
    gzip_reason_spec = None

    # 0) Spec-level detection — check OpenAPI spec for gzip declarations
    #    a) servers[*].x-server-compression.enabled
    for srv in (spec.get("servers") or []):
        xcomp = (srv.get("x-server-compression") or
                 srv.get("extensions", {}).get("x-server-compression") or {})
        if isinstance(xcomp, dict) and xcomp.get("enabled") is True:
            algos = xcomp.get("algorithms", [])
            if not algos or "gzip" in [a.lower() for a in algos]:
                gzip_ok = True
                gzip_reason_spec = "OpenAPI servers.x-server-compression.enabled=true"

    #    b) info.description mentions gzip
    if not gzip_ok:
        info_desc = (spec.get("info") or {}).get("description") or ""
        if "gzip" in info_desc.lower():
            gzip_ok = True
            gzip_reason_spec = "OpenAPI info.description mentions gzip compression"

    #    c) response headers in spec contain Content-Encoding with gzip
    if not gzip_ok:
        for _path, ops in (spec.get("paths") or {}).items():
            if gzip_ok:
                break
            for _method in ("get", "post", "put", "patch", "delete", "head"):
                op = ops.get(_method) if isinstance(ops, dict) else None
                if not op or not isinstance(op, dict):
                    continue
                for _code, resp in (op.get("responses") or {}).items():
                    if not isinstance(resp, dict):
                        continue
                    ce_hdr = (resp.get("headers") or {}).get("Content-Encoding")
                    if not ce_hdr:
                        continue
                    schema = ce_hdr.get("schema") or {}
                    enum_vals = schema.get("enum") or []
                    desc = (ce_hdr.get("description") or "").lower()
                    if "gzip" in desc or "gzip" in [str(v).lower() for v in enum_vals]:
                        gzip_ok = True
                        gzip_reason_spec = "OpenAPI response header Content-Encoding declares gzip"
                        break
                if gzip_ok:
                    break

    # 1) Check existing measurement headers for passive gzip
    for e in endpoints:
        key = f"{e['method']}:{e['path']}"
        m = measurements.get(key, {})
        ce = m.get("response_headers", {}).get("content-encoding", "")
        if "gzip" in ce.lower():
            gzip_ok = True

    # 2) Explicit gzip probe on first collection endpoint per unique base_url
    gzip_probe_ep = None
    gzip_probe_compressed = 0
    if not gzip_ok and collection_eps:
        per_base = {}
        for e in collection_eps:
            b = e.get("_base_url") or base_url
            if b:
                per_base.setdefault(b, e)
        for b, ep in per_base.items():
            url = build_url(b, ep["path"], {})
            m_gz = measure_endpoint(
                url, headers={**auth_headers, "Accept-Encoding": "gzip"},
                repeat=1, timeout=15,
            )
            ce = m_gz.get("response_headers", {}).get("content-encoding", "")
            raw_key = f"get:{ep['path']}"
            raw_size = measurements.get(raw_key, {}).get("size_download", 0)
            gzip_probe_compressed = m_gz["size_download"]
            if "gzip" in ce.lower():
                gzip_ok = True
                gzip_probe_ep = ep
                break
            if (gzip_probe_compressed > 0 and raw_size > 0
                    and gzip_probe_compressed < raw_size * 0.9):
                gzip_ok = True
                gzip_probe_ep = ep
                break

    # Register every measured endpoint (gzip is typically server-wide)
    for e in endpoints:
        key = f"{e['method']}:{e['path']}"
        m = measurements.get(key, {})
        ce = m.get("response_headers", {}).get("content-encoding", "")
        ep_has_gzip = "gzip" in ce.lower()
        if ep_has_gzip:
            register("DE01_compression", e["method"], e["path"], True,
                     "Content-Encoding: gzip in response")
        elif gzip_ok:
            reason = gzip_reason_spec or "Server supports gzip (confirmed on another endpoint)"
            register("DE01_compression", e["method"], e["path"], True, reason)
        else:
            register("DE01_compression", e["method"], e["path"], False,
                     "No gzip compression detected")

    scores["DE01_compression"] = 15 if gzip_ok else 0
    details["DE01_compression"] = {
        "note": ("Gzip compression active"
                 + (f" ({gzip_reason_spec})" if gzip_reason_spec else ""))
        if gzip_ok else "Gzip not detected",
    }

    # ═══════════════════════════════════════════════════════════════════
    # DE02 / DE03 — Cache ETag + 304
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("DE02_DE03_cache")
    etag_ok = False
    etag_reason_spec = None

    # 0) Spec-level detection — check OpenAPI spec for ETag declarations
    #    a) servers[*].x-server-etag-support.enabled
    for srv in (spec.get("servers") or []):
        xetag = (srv.get("x-server-etag-support") or
                 srv.get("extensions", {}).get("x-server-etag-support") or {})
        if isinstance(xetag, dict) and xetag.get("enabled") is True:
            etag_ok = True
            etag_reason_spec = "OpenAPI servers.x-server-etag-support.enabled=true"

    #    b) response headers in spec contain ETag header
    if not etag_ok:
        for _path, ops in (spec.get("paths") or {}).items():
            if etag_ok:
                break
            for _method in ("get",):
                op = ops.get(_method) if isinstance(ops, dict) else None
                if not op or not isinstance(op, dict):
                    continue
                for _code, resp in (op.get("responses") or {}).items():
                    if not isinstance(resp, dict):
                        continue
                    resp_hdrs = resp.get("headers") or {}
                    if any(k.lower() == "etag" for k in resp_hdrs):
                        etag_ok = True
                        etag_reason_spec = "OpenAPI response header ETag declared"
                        break
                if etag_ok:
                    break

    #    c) 304 response code in spec
    if not etag_ok:
        for _path, ops in (spec.get("paths") or {}).items():
            if etag_ok:
                break
            for _method in ("get",):
                op = ops.get(_method) if isinstance(ops, dict) else None
                if not op or not isinstance(op, dict):
                    continue
                if "304" in (op.get("responses") or {}):
                    etag_ok = True
                    etag_reason_spec = "OpenAPI spec declares 304 Not Modified response"
                    break

    if base_url:
        tested_paths = set()
        # Test up to 5 single-resource endpoints
        for test_ep in single_eps[:5]:
            tested_paths.add(test_ep["path"])
            ep_base = test_ep.get("_base_url") or base_url
            url = build_url(ep_base, test_ep["path"], {})
            _, head_hdrs = http_head(url, headers=auth_headers, timeout=10)
            etag_val = head_hdrs.get("etag", "")
            # Fallback: if HEAD didn't return ETag, try GET
            if not etag_val:
                m_get = measure_endpoint(url, headers=auth_headers, repeat=1, timeout=10)
                etag_val = m_get.get("response_headers", {}).get("etag", "")
            if etag_val:
                m304 = measure_endpoint(
                    url,
                    headers={**auth_headers, "If-None-Match": etag_val},
                    repeat=1,
                )
                if m304["http_code"] == 304:
                    register("DE02_DE03_cache", test_ep["method"], test_ep["path"],
                             True,
                             f"ETag={etag_val[:40]}… → 304 Not Modified")
                    etag_ok = True
                else:
                    register("DE02_DE03_cache", test_ep["method"], test_ep["path"],
                             False,
                             f"ETag present but If-None-Match → {m304['http_code']}")
            elif etag_ok:
                register("DE02_DE03_cache", test_ep["method"], test_ep["path"],
                         True,
                         etag_reason_spec or "ETag support declared in spec")
            else:
                register("DE02_DE03_cache", test_ep["method"], test_ep["path"],
                         False, "No ETag header in HEAD/GET response")

        # Register remaining single-resource endpoints as not individually tested
        for e in single_eps:
            if e["path"] not in tested_paths:
                if etag_ok:
                    register(
                        "DE02_DE03_cache", e["method"], e["path"], True,
                        etag_reason_spec or "ETag supported on other endpoints",
                    )
                else:
                    register(
                        "DE02_DE03_cache", e["method"], e["path"], False,
                        "Not individually tested",
                    )
    else:
        for e in single_eps:
            if etag_ok:
                register("DE02_DE03_cache", e["method"], e["path"], True,
                         etag_reason_spec or "ETag support declared in spec")
            else:
                register("DE02_DE03_cache", e["method"], e["path"], False,
                         "No base_url — cannot test")

    scores["DE02_DE03_cache"] = 15 if etag_ok else 0
    details["DE02_DE03_cache"] = (
        {"http_code": 304, "note": "ETag + 304 supported"
         + (f" ({etag_reason_spec})" if etag_reason_spec else "")}
        if etag_ok
        else {"note": "ETag/304 not detected"}
    )

    # ═══════════════════════════════════════════════════════════════════
    # DE06 — Delta / Changes
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("DE06_delta")
    for e in all_get_eps:
        pl = e["path"].lower()
        is_delta = "change" in pl or "delta" in pl or "since" in pl
        register(
            "DE06_delta", e["method"], e["path"], is_delta,
            "Path contains 'change', 'delta' or 'since'" if is_delta
            else "Not a delta/changes endpoint",
        )
    # Also check query params for 'since' on collection endpoints
    for e in collection_eps:
        pnames = {p.get("name", "").lower() for p in e.get("parameters", [])}
        if "since" in pnames or "updatedSince" in pnames:
            # Update the existing candidate to matched if not already
            for c in mapping["DE06_delta"]["candidates"]:
                if c["path"] == e["path"] and c["method"] == e["method"].upper():
                    if not c["matched"]:
                        c["matched"] = True
                        c["reason"] = "Has 'since' query parameter"

    n = _matched_count("DE06_delta")
    scores["DE06_delta"] = 10 if n else 0
    details["DE06_delta"] = {
        "note": f"Delta endpoint(s) found: {n}" if n
        else "No delta endpoint found",
    }

    # ═══════════════════════════════════════════════════════════════════
    # Range 206 — Partial Content
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("range_206")
    range_ok = False
    range_reason_spec = None

    # 0) Spec-level detection — check OpenAPI spec for Range/206 declarations
    #    a) servers[*].x-server-range-support.enabled
    for srv in (spec.get("servers") or []):
        xrange = (srv.get("x-server-range-support") or
                  srv.get("extensions", {}).get("x-server-range-support") or {})
        if isinstance(xrange, dict) and xrange.get("enabled") is True:
            range_ok = True
            range_reason_spec = "OpenAPI servers.x-server-range-support.enabled=true"

    #    b) info.description mentions range / partial content / 206
    if not range_ok:
        info_desc = (spec.get("info") or {}).get("description") or ""
        info_lower = info_desc.lower()
        if ("range" in info_lower and "partial content" in info_lower) or "206" in info_lower:
            range_ok = True
            range_reason_spec = "OpenAPI info.description mentions Range / Partial Content"

    #    c) Any operation has a 206 response code
    if not range_ok:
        for _path, ops in (spec.get("paths") or {}).items():
            if range_ok:
                break
            for _method in ("get", "post", "put", "patch", "delete", "head"):
                op = ops.get(_method) if isinstance(ops, dict) else None
                if not op or not isinstance(op, dict):
                    continue
                if "206" in (op.get("responses") or {}):
                    range_ok = True
                    range_reason_spec = f"OpenAPI operation {_method.upper()} {_path} declares 206 response"
                    break

    #    d) Response headers contain Accept-Ranges: bytes
    if not range_ok:
        for _path, ops in (spec.get("paths") or {}).items():
            if range_ok:
                break
            for _method in ("get", "post", "put", "patch", "delete", "head"):
                op = ops.get(_method) if isinstance(ops, dict) else None
                if not op or not isinstance(op, dict):
                    continue
                for _code, resp in (op.get("responses") or {}).items():
                    if not isinstance(resp, dict):
                        continue
                    ar_hdr = (resp.get("headers") or {}).get("Accept-Ranges")
                    if not ar_hdr:
                        continue
                    schema = ar_hdr.get("schema") or {}
                    enum_vals = schema.get("enum") or []
                    desc = (ar_hdr.get("description") or "").lower()
                    if "bytes" in desc or "bytes" in [str(v).lower() for v in enum_vals]:
                        range_ok = True
                        range_reason_spec = "OpenAPI response header Accept-Ranges declares bytes"
                        break
                if range_ok:
                    break

    if base_url and not range_ok:
        test_candidates = (single_eps + collection_eps)[:5]
        tested_paths = set()
        for test_ep in test_candidates:
            tested_paths.add(test_ep["path"])
            ep_base = test_ep.get("_base_url") or base_url
            url = build_url(ep_base, test_ep["path"], {})
            mr = measure_endpoint(
                url,
                headers={**auth_headers, "Range": "bytes=0-99"},
                repeat=1,
            )
            if mr["http_code"] == 206:
                register("range_206", test_ep["method"], test_ep["path"], True,
                         "Range: bytes=0-99 → 206 Partial Content")
                range_ok = True
            else:
                register("range_206", test_ep["method"], test_ep["path"], False,
                         f"Range: bytes=0-99 → {mr['http_code']} (not 206)")
        # Register remaining GET endpoints
        for e in all_get_eps:
            if e["path"] not in tested_paths:
                register("range_206", e["method"], e["path"], False,
                         "Not individually tested"
                         + (" (Range supported on other endpoints)" if range_ok else ""))
    elif range_ok:
        # Spec-level detection succeeded — register all GET endpoints as matched
        for e in all_get_eps:
            register("range_206", e["method"], e["path"], True,
                     range_reason_spec or "Range/206 declared in OpenAPI spec")
    else:
        for e in all_get_eps:
            register("range_206", e["method"], e["path"], False,
                     "No base_url — cannot test")

    scores["range_206"] = 10 if range_ok else 0
    details["range_206"] = (
        {"http_code": 206, "note": "Range/206 supported"
         + (f" ({range_reason_spec})" if range_reason_spec else "")} if range_ok
        else {"note": "Range not supported"}
    )

    # ═══════════════════════════════════════════════════════════════════
    # AR02 — Binary format (CBOR / Protobuf)
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("AR02_format_cbor")
    for e in endpoints:
        pl = e["path"].lower()
        produces = str(e.get("produces", []))
        responses_str = json.dumps(e.get("responses", {})).lower()
        is_binary = (
            "cbor" in pl or "protobuf" in pl or "grpc" in pl
            or "application/cbor" in produces
            or "application/cbor" in responses_str
            or "application/protobuf" in produces
            or "application/x-protobuf" in produces
            or "application/octet-stream" in responses_str
        )
        register(
            "AR02_format_cbor", e["method"], e["path"], is_binary,
            "Binary format (CBOR/protobuf/octet-stream)" if is_binary
            else "Standard JSON format",
        )
    n = _matched_count("AR02_format_cbor")
    scores["AR02_format_cbor"] = 10 if n else 0
    details["AR02_format_cbor"] = {
        "note": f"Binary format on {n} endpoint(s)" if n
        else "No binary format endpoint",
    }

    # ═══════════════════════════════════════════════════════════════════
    # LO01 — Observability (actuator / health)
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("LO01_observability")
    actuator_ok = False

    # Check well-known actuator/health paths (may not be in spec) on every
    # unique target base_url discovered.
    unique_bases = []
    seen_b = set()
    for e in endpoints:
        b = e.get("_base_url") or base_url
        if b and b not in seen_b:
            seen_b.add(b)
            unique_bases.append(b)
    if not unique_bases and base_url:
        unique_bases = [base_url]

    for b in unique_bases:
        for p in ["/actuator/health", "/health", "/actuator",
                  "/actuator/metrics", "/actuator/info"]:
            s, _, _ = http_get(b.rstrip("/") + p, timeout=5)
            display_path = (p if len(unique_bases) == 1 else f"{b}{p}")
            if s == 200:
                register("LO01_observability", "GET", display_path, True,
                         f"HTTP {s} OK")
                actuator_ok = True
            else:
                register("LO01_observability", "GET", display_path, False,
                         f"HTTP {s}" if s else "Unreachable")

    # Also register any spec endpoint matching health/actuator/metrics
    for e in endpoints:
        keywords = ("health", "actuator", "metrics", "info", "status")
        if any(kw in e["path"].lower() for kw in keywords):
            already = any(
                c["path"] == e["path"]
                for c in mapping["LO01_observability"]["candidates"]
            )
            if not already:
                register("LO01_observability", e["method"], e["path"], True,
                         "Health/observability endpoint in OpenAPI spec")
                actuator_ok = True

    scores["LO01_observability"] = 5 if actuator_ok else 0
    details["LO01_observability"] = {
        "note": "Actuator/health detected" if actuator_ok
        else "No health endpoint",
    }

    # ═══════════════════════════════════════════════════════════════════
    # US07 — Rate Limiting
    # ═══════════════════════════════════════════════════════════════════
    _init_rule("US07_rate_limit")
    rl_detected = False

    # Check every measurement for rate-limit response headers
    for e in endpoints:
        key = f"{e['method']}:{e['path']}"
        m = measurements.get(key, {})
        hdrs = m.get("response_headers", {})
        rl_hdrs = {
            k: v for k, v in hdrs.items()
            if any(tok in k.lower() for tok in
                   ("ratelimit", "x-rate-limit", "retry-after",
                    "x-ratelimit", "ratelimit-limit"))
        }
        if rl_hdrs:
            register("US07_rate_limit", e["method"], e["path"], True,
                     f"Rate-limit headers: {', '.join(rl_hdrs.keys())}")
            rl_detected = True
        else:
            register("US07_rate_limit", e["method"], e["path"], False,
                     "No rate-limit headers in response")

    # Heuristic fallback: assumed if API is running with data
    full_payload_size = max(
        (measurements.get(f"get:{e['path']}", {}).get("size_download", 0)
         for e in collection_eps),
        default=0,
    )
    heuristic_ok = (not rl_detected and base_url and full_payload_size > 0)

    if rl_detected:
        note = "Rate-limit headers detected"
    elif heuristic_ok:
        note = "Assumed present (API running, no explicit headers)"
    else:
        note = "Cannot verify"

    scores["US07_rate_limit"] = 5 if (rl_detected or heuristic_ok) else 0
    details["US07_rate_limit"] = {"note": note}

    # ═══════════════════════════════════════════════════════════════════
    # Finalize mapping: add validated/score/counts + build reverse index
    # ═══════════════════════════════════════════════════════════════════
    for rule_key in GREEN_RULES:
        _init_rule(rule_key)  # ensure entry even if no candidates
        rd = mapping[rule_key]
        matched = [c for c in rd["candidates"] if c["matched"]]
        total_candidates = len(rd["candidates"])
        matched_count = len(matched)

        # Proportional scoring: score = max_pts × matched / candidates
        max_pts = rd["max_pts"]
        if total_candidates > 0:
            proportional = round(max_pts * matched_count / total_candidates)
        else:
            proportional = 0

        rd["validated"] = matched_count > 0
        rd["score"] = proportional
        rd["matched_count"] = matched_count
        rd["candidate_count"] = total_candidates
        # Override the flat scores dict with the proportional score
        scores[rule_key] = proportional

    # ═══════════════════════════════════════════════════════════════════
    # Generate improvement suggestions for unvalidated rules
    # ═══════════════════════════════════════════════════════════════════
    _generate_suggestions(mapping, collection_eps, single_eps, all_get_eps, endpoints)

    # Build reverse index: endpoint → [rule_keys]
    endpoint_rules = {}
    for rule_key, rd in mapping.items():
        for c in rd["candidates"]:
            ep_key = f"{c['method'].lower()}:{c['path']}"
            endpoint_rules.setdefault(ep_key, [])
            if rule_key not in endpoint_rules[ep_key]:
                endpoint_rules[ep_key].append(rule_key)

    total = sum(scores.values())
    max_score = sum(r["max_pts"] for r in GREEN_RULES.values())
    grade = ("A+" if total >= 90 else "A" if total >= 80 else "B" if total >= 65
             else "C" if total >= 50 else "D" if total >= 30 else "E")

    return {
        "total": total,
        "max": max_score,
        "grade": grade,
        "breakdown": scores,
        "details": details,
        "rule_resource_mapping": mapping,
        "endpoint_rules": endpoint_rules,
    }


def _generate_suggestions(mapping, collection_eps, single_eps, all_get_eps, all_eps):
    """Populate ``suggestions`` for every rule that has unmatched endpoints.

    With proportional scoring (score = max_pts × matched / candidates),
    suggestions are generated for *partially* validated rules too — not only
    fully unvalidated ones.  Each suggestion targets a specific API resource
    and explains *what* to change and *how* (code-level guidance), with a
    priority and impact note.
    """

    # Helpers — pick the N most relevant collection / single endpoints
    def _top_collections(n=3):
        return [e["path"] for e in collection_eps[:n]]

    def _top_singles(n=3):
        return [e["path"] for e in single_eps[:n]]

    for rule_key, rd in mapping.items():
        unmatched = [c for c in rd["candidates"] if not c["matched"]]

        # No unmatched endpoints → nothing to suggest (perfect score)
        if not unmatched:
            rd["suggestions"] = []
            continue

        suggestions = []

        # Compute potential gain: how many pts each additional endpoint is worth
        max_pts = rd["max_pts"]
        total_candidates = rd["candidate_count"]
        current_score = rd["score"]
        remaining_gap = max_pts - current_score
        per_ep_gain = round(max_pts / total_candidates, 1) if total_candidates > 0 else 0
        gain_label = f"+{per_ep_gain} pts/endpoint (total gap: {remaining_gap} pts)"

        # ── DE11 — Pagination ─────────────────────────────────────────
        if rule_key == "DE11_pagination":
            # Only suggest for true collection endpoints (not /config, /me)
            real_collections = [
                c for c in unmatched
                if not any(skip in c["path"] for skip in ("/config", "/me", "/auth", "/health"))
            ]
            for c in real_collections[:5]:
                suggestions.append({
                    "target": f"{c['method'].upper()} {c['path']}",
                    "action": "Add pagination parameters (page & size)",
                    "priority": "high",
                    "impact": f"{gain_label} — reduces payload size for large collections",
                    "how": (
                        "Spring Boot: Change return type from List<T> to Page<T> and add "
                        "@RequestParam defaultValue parameters:\n"
                        "  @GetMapping\n"
                        "  public ApiResponse<Page<T>> list(\n"
                        "      @RequestParam(defaultValue = \"0\") int page,\n"
                        "      @RequestParam(defaultValue = \"20\") int size) {\n"
                        "    return ApiResponse.success(repository.findAll(PageRequest.of(page, size)));\n"
                        "  }\n"
                        "OpenAPI: params 'page' and 'size' will appear automatically via springdoc."
                    ),
                })

        # ── DE08 — Field filtering ────────────────────────────────────
        elif rule_key == "DE08_fields":
            top_targets = [
                c for c in unmatched
                if c["method"] == "GET"
                and not any(skip in c["path"] for skip in ("/config", "/download"))
            ]
            for c in top_targets[:5]:
                is_collection = "{" not in c["path"]
                suggestions.append({
                    "target": f"{c['method'].upper()} {c['path']}",
                    "action": "Add a 'fields' query parameter for sparse fieldsets",
                    "priority": "high" if is_collection else "medium",
                    "impact": f"{gain_label} — lets clients request only needed fields, reducing payload",
                    "how": (
                        "Spring Boot: Add an optional @RequestParam and filter the DTO:\n"
                        "  @GetMapping\n"
                        "  public ApiResponse<?> list(\n"
                        "      @RequestParam(required = false) String fields) {\n"
                        "    // If fields != null, use Jackson @JsonFilter or a projection\n"
                        "    // to return only the requested fields.\n"
                        "  }\n"
                        "Alternative: Use a custom Jackson MappingJacksonValue with a\n"
                        "SimpleFilterProvider that keeps only the requested properties.\n"
                        "OpenAPI: The 'fields' param will appear automatically."
                    ),
                })

        # ── DE01 — Compression (gzip) ─────────────────────────────────
        elif rule_key == "DE01_compression":
            # Gzip is typically a server-level setting, not per-endpoint
            suggestions.append({
                "target": "ALL endpoints (server-level)",
                "action": "Enable gzip compression on the server",
                "priority": "high",
                "impact": f"{gain_label} — typically 60-80% payload reduction",
                "how": (
                    "Option 1 — Spring Boot application.yml:\n"
                    "  server:\n"
                    "    compression:\n"
                    "      enabled: true\n"
                    "      min-response-size: 1024\n"
                    "      mime-types: application/json,application/xml,text/html,text/plain\n\n"
                    "Option 2 — Nginx (if reverse proxy):\n"
                    "  gzip on;\n"
                    "  gzip_types application/json application/xml text/plain;\n"
                    "  gzip_min_length 1024;\n"
                    "  gzip_comp_level 6;\n\n"
                    "Both options apply to ALL endpoints automatically."
                ),
            })

        # ── DE02/DE03 — Cache ETag + 304 ──────────────────────────────
        elif rule_key == "DE02_DE03_cache":
            for c in unmatched[:5]:
                suggestions.append({
                    "target": f"{c['method'].upper()} {c['path']}",
                    "action": "Add ETag support and If-None-Match → 304 Not Modified",
                    "priority": "high",
                    "impact": f"{gain_label} — avoids resending unchanged resources, saves bandwidth",
                    "how": (
                        "Spring Boot: Use ShallowEtagHeaderFilter (zero-code) or manual ETags:\n\n"
                        "  Option A — Global filter (easiest):\n"
                        "  @Bean\n"
                        "  public FilterRegistrationBean<ShallowEtagHeaderFilter> etagFilter() {\n"
                        "    FilterRegistrationBean<ShallowEtagHeaderFilter> reg = new FilterRegistrationBean<>();\n"
                        "    reg.setFilter(new ShallowEtagHeaderFilter());\n"
                        "    reg.addUrlPatterns(\"/api/*\");\n"
                        "    return reg;\n"
                        "  }\n\n"
                        "  Option B — Manual per endpoint:\n"
                        "  String etag = '\"' + DigestUtils.md5DigestAsHex(body.getBytes()) + '\"';\n"
                        "  if (request.checkNotModified(etag)) return null; // → 304\n"
                        "  return ResponseEntity.ok().eTag(etag).body(body);"
                    ),
                })

        # ── DE06 — Delta / Changes ────────────────────────────────────
        elif rule_key == "DE06_delta":
            for path in _top_collections(3):
                suggestions.append({
                    "target": f"GET {path}/changes  (new endpoint)",
                    "action": "Add a delta/changes endpoint with a 'since' parameter",
                    "priority": "medium",
                    "impact": f"{gain_label} — clients fetch only what changed since last sync",
                    "how": (
                        "Spring Boot: Add a new endpoint that filters by updatedAt:\n"
                        "  @GetMapping(\"/changes\")\n"
                        "  public ApiResponse<List<T>> getChanges(\n"
                        "      @RequestParam @DateTimeFormat(iso = ISO.DATE_TIME) LocalDateTime since) {\n"
                        "    return ApiResponse.success(\n"
                        "        repository.findByUpdatedAtAfter(since));\n"
                        "  }\n\n"
                        "Prerequisite: Add an 'updatedAt' column with @UpdateTimestamp\n"
                        "to your entity, and a repository method findByUpdatedAtAfter().\n"
                        f"Alternative: Add @RequestParam 'since' to existing {path}."
                    ),
                })

        # ── Range 206 — Partial Content ───────────────────────────────
        elif rule_key == "range_206":
            # Best candidate is the download endpoint
            download_eps = [c for c in unmatched if "download" in c["path"].lower()]
            other_eps = [c for c in unmatched if "download" not in c["path"].lower()]
            targets = download_eps + other_eps[:2]
            for c in targets[:3]:
                is_download = "download" in c["path"].lower()
                suggestions.append({
                    "target": f"{c['method'].upper()} {c['path']}",
                    "action": "Support HTTP Range header for partial content (206)",
                    "priority": "high" if is_download else "low",
                    "impact": f"+{rd['max_pts']} pts — enables resumable downloads and partial fetches",
                    "how": (
                        "Spring Boot: Use ResourceHttpRequestHandler or manual range parsing:\n\n"
                        "  @GetMapping(\"/{id}/download\")\n"
                        "  public ResponseEntity<Resource> download(\n"
                        "      @PathVariable UUID id,\n"
                        "      @RequestHeader(value = \"Range\", required = false) String range) {\n"
                        "    Resource resource = new FileSystemResource(filePath);\n"
                        "    if (range != null) {\n"
                        "      // Parse 'bytes=start-end', return 206 with Content-Range header\n"
                        "      long start = parseStart(range);\n"
                        "      long end = parseEnd(range, resource.contentLength());\n"
                        "      return ResponseEntity.status(HttpStatus.PARTIAL_CONTENT)\n"
                        "          .header(\"Content-Range\", \"bytes \" + start + \"-\" + end + \"/\" + resource.contentLength())\n"
                        "          .body(new InputStreamResource(rangedStream));\n"
                        "    }\n"
                        "    return ResponseEntity.ok(resource);\n"
                        "  }\n\n"
                        "Alternative: Use Spring's ResourceRegion support for automatic range handling."
                    ) if is_download else (
                        "For JSON endpoints, Range/206 is rarely useful.\n"
                        "Focus on the file download endpoint(s) instead."
                    ),
                })

        # ── AR02 — Binary format (CBOR / Protobuf) ───────────────────
        elif rule_key == "AR02_format_cbor":
            for path in _top_collections(2):
                suggestions.append({
                    "target": f"GET {path}  (add CBOR variant)",
                    "action": "Add a binary format alternative (CBOR or Protobuf)",
                    "priority": "low",
                    "impact": f"+{rd['max_pts']} pts — binary formats are 30-50% smaller than JSON",
                    "how": (
                        "Spring Boot + CBOR:\n"
                        "  1. Add dependency: com.fasterxml.jackson.dataformat:jackson-dataformat-cbor\n"
                        "  2. Register the converter:\n"
                        "     @Bean\n"
                        "     public HttpMessageConverter<Object> cborConverter(ObjectMapper mapper) {\n"
                        "       ObjectMapper cborMapper = new ObjectMapper(new CBORFactory());\n"
                        "       return new MappingJackson2CborHttpMessageConverter(cborMapper);\n"
                        "     }\n"
                        "  3. Clients send: Accept: application/cbor\n\n"
                        "Alternative (Protobuf):\n"
                        "  Add spring-boot-starter-protobuf and define .proto schemas.\n"
                        "  Register ProtobufHttpMessageConverter."
                    ),
                })

        # ── LO01 — Observability ──────────────────────────────────────
        elif rule_key == "LO01_observability":
            suggestions.append({
                "target": "/actuator/health, /actuator/metrics",
                "action": "Expose Spring Boot Actuator endpoints",
                "priority": "high",
                "impact": f"+{rd['max_pts']} pts — essential for production monitoring",
                "how": (
                    "Spring Boot application.yml:\n"
                    "  management:\n"
                    "    endpoints:\n"
                    "      web:\n"
                    "        exposure:\n"
                    "          include: health,info,metrics\n"
                    "    endpoint:\n"
                    "      health:\n"
                    "        show-details: when-authorized\n\n"
                    "Add dependency: spring-boot-starter-actuator (likely already present)."
                ),
            })

        # ── US07 — Rate Limiting ──────────────────────────────────────
        elif rule_key == "US07_rate_limit":
            suggestions.append({
                "target": "ALL endpoints (server-level)",
                "action": "Add rate-limit response headers",
                "priority": "medium",
                "impact": f"+{rd['max_pts']} pts — protects the API from abuse and signals limits to clients",
                "how": (
                    "Option 1 — Spring Boot filter:\n"
                    "  Add a HandlerInterceptor or OncePerRequestFilter that adds:\n"
                    "    X-RateLimit-Limit: 100\n"
                    "    X-RateLimit-Remaining: 97\n"
                    "    X-RateLimit-Reset: 1620000000\n\n"
                    "Option 2 — Use Bucket4j + Spring Boot Starter:\n"
                    "  <dependency>com.bucket4j:bucket4j-spring-boot-starter</dependency>\n"
                    "  Configure rate limits in application.yml per endpoint.\n\n"
                    "Option 3 — Nginx:\n"
                    "  limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;\n"
                    "  location /api/ { limit_req zone=api burst=20; }\n"
                    "  add_header X-RateLimit-Limit 100;"
                ),
            })

        rd["suggestions"] = suggestions


# ─── Step 5: Build Dashboard-Compatible Report ────────────────────────────

def load_previous_report(output_dir):
    """Load the latest-report.json if it exists (for before/after comparison).
    Handles both old flat format and new {appname, report} envelope."""
    latest = output_dir / "latest-report.json"
    if latest.is_file():
        try:
            with open(latest, "r", encoding="utf-8") as f:
                data = json.load(f)
            # Unwrap envelope if present
            if "report" in data and "appname" in data:
                return data["report"]
            return data
        except Exception:
            pass
    return None


def build_dashboard_report(timestamp, green_score, measurements_map, endpoints,
                           base_url, full_key, net_kwh_gb, srv_w, previous_report):
    """Build a report in the same format as green-score-analyzer.sh output.

    If previous_report is None (first analysis), baseline = optimized (before = after).
    Otherwise baseline comes from the previous report's measurements.
    """

    def make_entry(m):
        return {
            "http_code": m.get("http_code", 0),
            "size_download": m.get("size_download", 0),
            "time_total": m.get("time_total", 0),
            "speed_download": m.get("speed_download", 0),
        }

    ZERO = {"http_code": 0, "size_download": 0, "time_total": 0, "speed_download": 0}

    # Find the full naive payload (biggest collection GET)
    full_m = measurements_map.get(full_key, ZERO)

    # Map known optimized keys for dashboard compatibility
    mapped_optimized = {}
    for key, m in measurements_map.items():
        method, path = key.split(":", 1)
        entry = make_entry(m)
        pl = path.lower()
        if "page" in str(m.get("_params", "")) or "page" in pl:
            mapped_optimized.setdefault("pagination", entry)
        elif "select" in pl or "fields" in pl:
            mapped_optimized.setdefault("fields_filter", entry)
        elif "change" in pl or "delta" in pl:
            mapped_optimized.setdefault("delta_changes", entry)
        elif "cbor" in pl:
            mapped_optimized.setdefault("cbor_format", entry)
        elif "summary" in pl:
            mapped_optimized.setdefault("range_206", entry)

    # Full payload = the biggest measured endpoint
    mapped_optimized["full_payload"] = make_entry(full_m)

    # Build all_measurements dict (keyed by method:path)
    all_measurements = {}
    for key, m in measurements_map.items():
        all_measurements[key] = make_entry(m)

    # Build discovered_endpoints list for dynamic dashboard rows
    discovered_endpoints = []
    for ep in endpoints:
        key = f"{ep['method']}:{ep['path']}"
        m = measurements_map.get(key)
        if m:
            discovered_endpoints.append({
                "method": ep["method"].upper(),
                "path": ep["path"],
                "operationId": ep.get("operationId", ""),
                "summary": ep.get("summary", ""),
                "tags": ep.get("tags", []),
                **make_entry(m),
            })

    # ── Baseline logic: first analysis → before = after ──
    if previous_report and previous_report.get("measurements"):
        prev_m = previous_report["measurements"]
        baseline = {
            "full_payload": prev_m.get("baseline", {}).get("full_payload")
                           or prev_m.get("optimized", {}).get("full_payload")
                           or make_entry(full_m),
            "single_resource": prev_m.get("baseline", {}).get("single_resource", ZERO),
            "single_repeat": prev_m.get("baseline", {}).get("single_repeat", ZERO),
        }
    else:
        # First analysis: baseline = current measurements (before = after)
        baseline = {
            "full_payload": make_entry(full_m),
            "single_resource": ZERO,
            "single_repeat": ZERO,
        }

    report = {
        "timestamp": timestamp,
        "green_score": green_score,
        "measurements": {
            "baseline": baseline,
            "optimized": mapped_optimized,
        },
        "auto_discovery": {
            "base_url": base_url,
            "endpoints_discovered": len(endpoints),
            "endpoints_measured": len(measurements_map),
            "all_measurements": all_measurements,
            "discovered_endpoints": discovered_endpoints,
        },
    }
    return report


# ─── Main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Green API Auto-Discover & Analyzer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Auto-discover swagger from running API
  python green-api-auto-discover.py --target http://localhost:8081

  # Explicit swagger file + base URL
  python green-api-auto-discover.py --swagger ./openapi.yaml --target http://localhost:8081

  # Dry-run (no HTTP calls to endpoints)
  python green-api-auto-discover.py --swagger ./openapi.yaml --dry-run

  # With bearer token
  python green-api-auto-discover.py --target http://localhost:8081 --bearer MY_TOKEN
        """,
    )
    parser.add_argument("--appname", default="", help="Application name for reports (default: root folder name)")
    parser.add_argument("--target", action="append", default=[],
                        help="Base URL of a running API. Repeat the flag (or use a comma-separated list) "
                             "to analyze several targets in a single run.")
    parser.add_argument("--swagger", action="append", default=[],
                        help="Path or URL to an OpenAPI spec. Repeat the flag (or use a comma-separated list) "
                             "for several specs (auto-discovered if omitted).")
    parser.add_argument("--bearer", default="", help="Bearer token for authenticated APIs")
    parser.add_argument("--param", action="append", default=[], help="Path/query param key=value (repeatable)")
    parser.add_argument("--repeat", type=int, default=3, help="Number of repetitions per endpoint (default: 3)")
    parser.add_argument("--methods", default="get,post,put,patch,delete", help="Comma-separated HTTP methods to measure (default: get)")
    parser.add_argument("--dry-run", action="store_true", help="List endpoints without calling them")
    parser.add_argument("--spectral-config", default="", help="Path to .spectral.yml (auto-detected)")
    parser.add_argument("--network-kwh-per-gb", type=float, default=DEFAULT_NETWORK_KWH_PER_GB)
    parser.add_argument("--server-power-w", type=float, default=DEFAULT_SERVER_POWER_W)
    parser.add_argument("--output-dir", default="", help="Output directory for reports (default: reports/)")
    parser.add_argument("--skip-spectral", action="store_true", help="Skip Spectral linting")
    parser.add_argument("--skip-dashboard", action="store_true", help="Skip dashboard generation")
    # Architecture rules (AR01–AR05) controls
    parser.add_argument("--cloud-footprint-confirmed", action="store_true",
                        help="Confirm that the cloud provider's carbon dashboard is actively used (required to validate AR05).")
    parser.add_argument("--consumer-region", default="",
                        help="ISO-3166 alpha-2 region of the API consumers (e.g. FR, US). Used by AR02 distance scoring.")
    parser.add_argument("--enable-geoip", action="store_true",
                        help="Enable optional GeoIP lookup (ipinfo.io) to compute consumer<->API distance for AR02.")
    parser.add_argument("--source-dir", default="",
                        help="Path to the API source code (Java/.NET/Node) for AR01/AR04 deps & IaC scan (Phase 2).")
    args = parser.parse_args()

    # ── Resolve paths ──
    script_dir = Path(__file__).resolve().parent
    root_dir = script_dir.parent
    output_dir = Path(args.output_dir) if args.output_dir else root_dir / "reports"
    output_dir.mkdir(parents=True, exist_ok=True)

    # Resolve appname: CLI > root folder name
    appname = args.appname.strip() if args.appname else root_dir.name

    timestamp_str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    timestamp_file = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

    # ── Normalize multi-target / multi-swagger inputs ──
    def _split_csv(items):
        out = []
        for item in items or []:
            for v in str(item).split(","):
                v = v.strip()
                if v:
                    out.append(v)
        return out

    targets = [t.rstrip("/") for t in _split_csv(args.target)]
    swaggers = _split_csv(args.swagger)

    # Parse user params
    user_params = {}
    for item in args.param:
        if "=" in item:
            k, v = item.split("=", 1)
            user_params[k] = v

    # Auth headers
    auth_headers = {}
    if args.bearer:
        auth_headers["Authorization"] = f"Bearer {args.bearer}"

    # ── Banner ──
    log("=" * 60)
    log("  Green API Auto-Discover & Analyzer")
    log(f"  App: {appname}")
    if targets:
        log(f"  Targets ({len(targets)}): {', '.join(targets)}")
    if swaggers:
        log(f"  Swaggers ({len(swaggers)}): {', '.join(swaggers)}")
    log("  Devoxx France 2026 — Green Architecture")
    log("=" * 60)

    # ── Step 1: Load/Discover Swagger for every target ──
    # Build a list of (base_url, spec, source_label) tuples — one per API.
    sources = []  # type: list[tuple[str, dict, str]]

    if swaggers:
        # Pair each --swagger with the matching --target by index when possible
        for i, sw in enumerate(swaggers):
            t = targets[i] if i < len(targets) else (targets[0] if targets else "")
            log(f"Loading spec from: {sw}")
            try:
                sp = load_spec(sw)
            except Exception as e:
                log(f"Failed to load spec {sw}: {e}", "ERR")
                sys.exit(1)
            sources.append((t, sp, sw))
        # Auto-discover for any extra targets not paired with a --swagger
        for t in targets[len(swaggers):]:
            sp, src = discover_swagger(t)
            if not sp:
                log(f"Could not auto-discover OpenAPI spec on {t}", "ERR")
                sys.exit(1)
            sources.append((t, sp, src))
    elif targets:
        for t in targets:
            sp, src = discover_swagger(t)
            if not sp:
                log(f"Could not auto-discover OpenAPI spec on {t}. Provide --swagger.", "ERR")
                sys.exit(1)
            sources.append((t, sp, src))
    else:
        log("Provide --target or --swagger (one or several).", "ERR")
        sys.exit(1)

    # If a swagger-only source has no target, infer base_url from the spec
    fixed_sources = []
    for (t, sp, src) in sources:
        if not t:
            servers = sp.get("servers", [])
            if servers:
                t = (servers[0].get("url") or "").rstrip("/")
            elif sp.get("host"):
                scheme = (sp.get("schemes") or ["http"])[0]
                t = f"{scheme}://{sp['host']}{sp.get('basePath', '')}".rstrip("/")
        fixed_sources.append((t, sp, src))
    sources = fixed_sources

    if not args.dry_run and not all(s[0] for s in sources):
        missing = [s[2] for s in sources if not s[0]]
        log(f"Cannot determine base URL for: {missing}. Provide --target.", "ERR")
        sys.exit(1)

    # Primary base_url (first target) — kept for legacy report fields.
    base_url = sources[0][0] if sources else ""

    # Merge all specs into a single discovery resource and save it.
    if len(sources) == 1:
        spec = sources[0][1]
    else:
        spec = merge_specs(sources)
        log(f"Merged {len(sources)} spec(s) into a single discovery resource", "OK")

    # Save spec locally for Spectral
    spec_local = output_dir / "discovered-openapi.json"
    with open(spec_local, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=2)
    log(f"Spec saved to {spec_local}", "OK")

    # ── Extract endpoints (each tagged with its own _base_url) ──
    endpoints = []
    for (t, sp, _src) in sources:
        endpoints.extend(extract_endpoints(sp, base_url=t))
    methods_filter = {m.strip().lower() for m in args.methods.split(",")}
    filtered_eps = [e for e in endpoints if e["method"] in methods_filter]
    log(f"Discovered {len(endpoints)} total endpoints, {len(filtered_eps)} matching methods {methods_filter}")

    if args.dry_run:
        log("DRY-RUN mode — listing endpoints:")
        for e in filtered_eps:
            ep_base = e.get("_base_url") or base_url or "http://localhost"
            ep_params = {}
            ep_params.update(e.get("_example_path_params") or {})
            ep_params.update(user_params)
            ep_query = {}
            for k, v in (e.get("_example_query_params") or {}).items():
                ep_query[k] = user_params.get(k, v)
            url = build_url(ep_base, e["path"], ep_params, ep_query)
            body_tag = ""
            if e["method"] in ("post", "put", "patch") and e.get("_example_body") is not None:
                body_tag = "  [example body ✓]"
            print(f"  {e['method'].upper():6s} {e['path']:50s} -> {url}{body_tag}")
        sys.exit(0)

    # ── Step 2: Spectral Linting (always runs unless --skip-spectral) ──
    spectral_issues = None
    if not args.skip_spectral:
        spectral_config = args.spectral_config or None
        if not spectral_config:
            candidates = [root_dir / ".spectral.yml", root_dir / ".spectral.yaml"]
            for c in candidates:
                if c.is_file():
                    spectral_config = str(c)
                    log(f"Using Spectral config: {c}", "OK")
                    break
            if not spectral_config:
                log("No .spectral.yml found — using Spectral built-in OAS ruleset", "INFO")
        spectral_output = output_dir / "spectral-results.json"
        spectral_issues = run_spectral(
            str(spec_local), spectral_config, str(spectral_output)
        )

    # ── Step 2b: Load test scenario (Green Score data) ──
    # Resolution order (first match wins):
    #   1) GREEN_INTERACTIVE_SCENARIO env var → JSON file written by the
    #      interactive dashboard bridge (greenapianalyzer-server.py). It
    #      carries the user's per-endpoint payload tweaks from the UI, so it
    #      MUST take precedence over server-side scenarios and OpenAPI
    #      examples to honour the user's intent.
    #   2) HTTP scenario served by a target on /api/test/green-score/scenario
    #      (legacy contract used by the demo backend).
    # When no scenario is found we still fall back to the OpenAPI examples
    # pre-extracted on each endpoint (``_example_body`` / ``_example_path_params``).
    scenario = None
    interactive_scenario_path = os.environ.get("GREEN_INTERACTIVE_SCENARIO", "").strip()
    if interactive_scenario_path and os.path.isfile(interactive_scenario_path):
        try:
            with open(interactive_scenario_path, "r", encoding="utf-8") as f:
                scenario = json.load(f)
            n_params = len(scenario.get("pathParams", {}) or {})
            n_bodies = len(scenario.get("requestBodies", {}) or {})
            log(f"Loaded interactive scenario from {interactive_scenario_path}: "
                f"{n_params} path mappings, {n_bodies} request bodies", "OK")
        except Exception as e:
            log(f"Failed to load interactive scenario {interactive_scenario_path}: {e}", "WARN")
            scenario = None
    if scenario is None:
        # Scenario can be served by any of the targets; try them in order.
        for cand_base in [s[0] for s in sources if s[0]]:
            scenario_url = cand_base.rstrip("/") + "/api/test/green-score/scenario"
            try:
                sc_status, sc_body, _ = http_get(scenario_url, headers=auth_headers, timeout=10)
                if sc_status == 200 and sc_body:
                    scenario = json.loads(sc_body.decode("utf-8", errors="replace"))
                    n_params = len(scenario.get("pathParams", {}))
                    n_bodies = len(scenario.get("requestBodies", {}))
                    log(f"Loaded test scenario from {cand_base}: {n_params} path mappings, {n_bodies} request bodies", "OK")
                    break
            except Exception as e:
                log(f"No test scenario on {cand_base} ({e})", "INFO")

    # Build exclusion set from scenario
    exclude_set = set()
    if scenario:
        for ex in scenario.get("excludeEndpoints", []):
            exclude_set.add(ex.lower())

    # ── Step 3: Measure Endpoints ──
    # Filter out excluded endpoints
    if exclude_set:
        before = len(filtered_eps)
        filtered_eps = [e for e in filtered_eps
                        if f"{e['method']}:{e['path']}".lower() not in exclude_set]
        if len(filtered_eps) < before:
            log(f"Excluded {before - len(filtered_eps)} endpoint(s) per scenario", "INFO")

    log(f"Measuring {len(filtered_eps)} endpoints ({args.repeat} repeats each)...")
    measurements = {}
    endpoint_reports = []

    for i, ep in enumerate(filtered_eps, 1):
        # ── Resolve path params (scenario > user > OpenAPI example > "1") ──
        ep_params = {}
        ep_params.update(ep.get("_example_path_params") or {})  # weakest
        ep_params.update(user_params)                           # CLI overrides
        if scenario:
            path_specific = scenario.get("pathParams", {}).get(ep["path"], {})
            ep_params.update(path_specific)                     # strongest

        # ── Required query params from OpenAPI examples (no scenario hook
        #    for these yet; user_params can still override via plain key=val).
        ep_query = {}
        for k, v in (ep.get("_example_query_params") or {}).items():
            ep_query[k] = user_params.get(k, v)
        # Scenario query overrides (written by the interactive bridge)
        if scenario:
            scen_q = (scenario.get("queryParams") or {}).get(f"{ep['method']}:{ep['path']}")
            if isinstance(scen_q, dict):
                ep_query.update(scen_q)

        url = build_url(ep.get("_base_url") or base_url, ep["path"], ep_params, ep_query)

        # ── Resolve request body (scenario > OpenAPI example) ──
        ep_body = None
        if ep["method"] in ("post", "put", "patch"):
            if scenario:
                body_key = f"{ep['method']}:{ep['path']}"
                ep_body = scenario.get("requestBodies", {}).get(body_key)
            if ep_body is None:
                ep_body = ep.get("_example_body")

        # ── Use repeat=1 for stateful methods (POST/PUT/DELETE/PATCH) ──
        ep_repeat = args.repeat if ep["method"] == "get" else 1

        label = f"[{i}/{len(filtered_eps)}] {ep['method'].upper()} {ep['path']}"
        log(f"  {label}")

        m = measure_endpoint(url, method=ep["method"].upper(), headers=auth_headers,
                             repeat=ep_repeat, timeout=30, body=ep_body)

        net_wh = bytes_to_wh(m["size_download"], args.network_kwh_per_gb)
        srv_wh = seconds_to_wh(m["time_total"], args.server_power_w)
        m["energy_network_wh"] = net_wh
        m["energy_server_wh"] = srv_wh
        m["energy_total_wh"] = net_wh + srv_wh

        key = f"{ep['method']}:{ep['path']}"
        measurements[key] = m

        log(f"    -> {m['http_code']}  {format_bytes(m['size_download'])}  "
            f"{m['time_total']:.3f}s  energy={m['energy_total_wh']:.6f} Wh", "OK")

        # Per-endpoint report
        ep_report = {
            "timestamp": timestamp_str,
            "service_base_url": ep.get("_base_url") or base_url,
            "endpoint": {
                "method": ep["method"],
                "path": ep["path"],
                "url": url,
                **{k: v for k, v in m.items() if k != "response_headers"},
            },
        }
        endpoint_reports.append(ep_report)

        # Save per-endpoint file
        ep_dir = output_dir / "analysis" / "endpoints"
        ep_dir.mkdir(parents=True, exist_ok=True)
        ep_slug = slugify(ep["method"] + "-" + ep["path"])
        ep_file = ep_dir / f"analysis-endpoint-{ep_slug}.json"
        with open(ep_file, "w", encoding="utf-8") as f:
            json.dump(ep_report, f, indent=2)

    # ── Step 4: Green Score ──
    log("Computing Green Score...")
    green_score = analyze_green_rules(spec, endpoints, base_url, measurements, auth_headers)
    log(f"  GREEN SCORE: {green_score['total']}/{green_score['max']}  Grade: {green_score['grade']}", "OK")

    # ── Step 4a: Architecture & Infrastructure rules (AR01..AR05) ──
    if _ARCH_RULES_AVAILABLE:
        # Load thresholds + cloud-dashboard URLs from green-score-threshold.json
        thr_path = root_dir / "green-score-threshold.json"
        thr_cfg: dict = {}
        if thr_path.is_file():
            try:
                thr_cfg = json.loads(thr_path.read_text(encoding="utf-8")) or {}
            except Exception as e:
                log(f"  threshold config unreadable ({e}); falling back to defaults", "WARN")
        arch_thresholds = thr_cfg.get("architecture", {})
        cloud_dashboards = thr_cfg.get("cloud_footprint_dashboards", {})

        # Re-extract per-target measurements for context
        try:
            arch_results = evaluate_architecture_rules(
                spec=spec,
                sources=sources,
                endpoints=endpoints,
                measurements=measurements.get("auto_discovery", {}).get("all_measurements", {}) or {},
                auth_headers=auth_headers,
                thresholds=arch_thresholds,
                cloud_dashboards=cloud_dashboards,
                footprint_confirmed=bool(args.cloud_footprint_confirmed),
                enable_phase2=bool(args.source_dir),
                source_dir=args.source_dir or None,
            )
        except Exception as e:
            log(f"  Architecture rules evaluation failed: {e}", "WARN")
            arch_results = {}

        # Merge architecture results into green_score (mapping/breakdown/total/max)
        rule_mapping_full = green_score.get("rule_resource_mapping", {}) or {}
        scores_full = green_score.get("breakdown", {}) or {}
        endpoint_rules_full = green_score.get("endpoint_rules", {}) or {}
        details_full = green_score.get("details", {}) or {}

        for arch_key, arch_res in arch_results.items():
            meta = GREEN_RULES.get(arch_key, {})
            rule_mapping_full[arch_key] = {
                "id": meta.get("id", arch_res.get("rule_id", arch_key)),
                "label": meta.get("label", arch_key),
                "description": meta.get("description", ""),
                "max_pts": arch_res.get("max_pts", meta.get("max_pts", 0)),
                "category": arch_res.get("category", meta.get("category", "architecture")),
                "validated": bool(arch_res.get("matched")),
                "score": int(arch_res.get("score", 0)),
                "matched_count": 1 if arch_res.get("matched") else 0,
                "candidate_count": max(1, len(arch_res.get("candidates", []))),
                "candidates": arch_res.get("candidates", []),
                "evidence": arch_res.get("evidence", []),
                "recommendations": arch_res.get("recommendations", []),
                # AR01-only — visible by the dashboard if present
                "migration_advice": arch_res.get("migration_advice", []),
                # AR03/AR05 extras
                "duplicates": arch_res.get("duplicates", []),
                "detected_provider": arch_res.get("detected_provider"),
            }
            scores_full[arch_key] = int(arch_res.get("score", 0))
            details_full[arch_key] = {
                "note": " | ".join(arch_res.get("recommendations", []))[:300]
            }

        # Refresh totals & grade with the new 123-pts budget.
        legacy_total = sum(v for k, v in scores_full.items() if k not in arch_results)
        arch_total = sum(int(v) for k, v in scores_full.items() if k in arch_results)
        legacy_max = sum(GREEN_RULES[k]["max_pts"] for k in scores_full
                         if k in GREEN_RULES and k not in arch_results)
        arch_max = sum(GREEN_RULES[k]["max_pts"] for k in arch_results if k in GREEN_RULES)

        total_raw = legacy_total + arch_total
        max_raw = legacy_max + arch_max
        # Normalised score on 100 for backward compatibility with badge/CI gates
        score_normalised = round(100 * total_raw / max_raw) if max_raw else 0
        grade = ("A+" if score_normalised >= 90 else "A" if score_normalised >= 80
                 else "B" if score_normalised >= 65 else "C" if score_normalised >= 50
                 else "D" if score_normalised >= 30 else "E")

        green_score["rule_resource_mapping"] = rule_mapping_full
        green_score["breakdown"] = scores_full
        green_score["details"] = details_full
        green_score["endpoint_rules"] = endpoint_rules_full
        green_score["total"] = total_raw
        green_score["max"] = max_raw
        green_score["grade"] = grade
        green_score["score_normalised_100"] = score_normalised
        green_score["legacy_total"] = legacy_total
        green_score["legacy_max"] = legacy_max
        green_score["architecture_total"] = arch_total
        green_score["architecture_max"] = arch_max

        log(f"  ARCHITECTURE: {arch_total}/{arch_max}  "
            f"(AR01..AR05 → +23 pts budget)", "OK")
        log(f"  GREEN SCORE (normalised /100): {score_normalised}  "
            f"Grade: {grade}", "OK")
    else:
        log(f"  architecture_rules module unavailable: {_ARCH_RULES_IMPORT_ERROR}",
            "WARN")

    # ── Step 4b: Display Rule ↔ Resource Mapping ──
    rule_mapping = green_score.get("rule_resource_mapping", {})
    endpoint_rules = green_score.get("endpoint_rules", {})

    log("")
    log("=" * 60)
    log("  📋 Rule ↔ API Resource Mapping")
    log("=" * 60)
    for rule_key, rd in rule_mapping.items():
        status = "✅" if rd["validated"] else "❌"
        log(f"  {status} [{rd['id']}] {rd['label']}  "
            f"({rd['score']}/{rd['max_pts']} pts)  "
            f"— {rd['matched_count']}/{rd['candidate_count']} resource(s) matched",
            "OK" if rd["validated"] else "WARN")
        for c in rd["candidates"]:
            icon = "🟢" if c["matched"] else "⚪"
            log(f"      {icon} {c['method']:6s} {c['path']}")
            log(f"         └─ {c['reason']}")

    log("")
    log("  📋 Reverse Index: API Resource → Rules")
    log("-" * 60)
    for ep_key in sorted(endpoint_rules.keys()):
        rules_list = endpoint_rules[ep_key]
        rule_ids = [rule_mapping[rk]["id"] for rk in rules_list if rk in rule_mapping]
        log(f"  {ep_key:50s} → {', '.join(rule_ids)}")
    log("=" * 60)

    # ── Step 4c: Display Improvement Suggestions ──
    unvalidated = {k: rd for k, rd in rule_mapping.items()
                   if not rd["validated"] and rd.get("suggestions")}
    if unvalidated:
        log("")
        log("=" * 60)
        log("  💡 Improvement Suggestions (unvalidated rules)")
        log("=" * 60)
        total_potential = sum(rd["max_pts"] for rd in unvalidated.values())
        log(f"  Potential score gain: +{total_potential} pts", "INFO")
        log("")
        for rule_key, rd in unvalidated.items():
            log(f"  ── [{rd['id']}] {rd['label']}  (0/{rd['max_pts']} pts) ──", "WARN")
            for i, s in enumerate(rd["suggestions"], 1):
                prio_icon = {"high": "🔴", "medium": "🟡", "low": "🟢"}.get(s["priority"], "⚪")
                log(f"    {prio_icon} Suggestion {i}: {s['action']}")
                log(f"       Target:   {s['target']}")
                log(f"       Priority: {s['priority'].upper()}")
                log(f"       Impact:   {s['impact']}")
                # Show 'how' with proper indentation
                for line in s["how"].split("\n"):
                    log(f"       {line}")
                log("")
        log("=" * 60)
    else:
        log("")
        log("  🎉 All rules validated — no suggestions needed!", "OK")
    log("")

    # Save rule-resource mapping as a separate report file
    all_base_urls = [s[0] for s in sources if s[0]]
    mapping_report = {
        "appname": appname,
        "timestamp": timestamp_str,
        "service_base_url": base_url,
        "service_base_urls": all_base_urls,
        "green_score_summary": {
            "total": green_score["total"],
            "max": green_score["max"],
            "grade": green_score["grade"],
        },
        "rule_resource_mapping": rule_mapping,
        "endpoint_rules": endpoint_rules,
    }
    mapping_file = output_dir / "analysis" / "rule-resource-mapping.json"
    mapping_file.parent.mkdir(parents=True, exist_ok=True)
    with open(mapping_file, "w", encoding="utf-8") as f:
        json.dump(mapping_report, f, indent=2)
    log(f"Rule-Resource mapping saved: {mapping_file}", "OK")

    # Find the full payload key (largest GET)
    full_key = max(measurements.keys(),
                   key=lambda k: measurements[k].get("size_download", 0)) if measurements else ""

    # ── Step 5: Build Reports ──
    # Load previous report for before/after comparison
    previous_report = load_previous_report(output_dir)
    if previous_report:
        log("Previous report found — will use as baseline (before)", "OK")
    else:
        log("No previous report — first analysis: before = after", "INFO")

    # Dashboard-compatible report
    dashboard_report = build_dashboard_report(
        timestamp_str, green_score, measurements, filtered_eps,
        base_url, full_key, args.network_kwh_per_gb, args.server_power_w,
        previous_report,
    )

    # Add spectral results
    if spectral_issues is not None:
        dashboard_report["spectral"] = {
            "issues_count": len(spectral_issues),
            "errors": sum(1 for i in spectral_issues if i.get("severity") == 0),
            "warnings": sum(1 for i in spectral_issues if i.get("severity") == 1),
            "infos": sum(1 for i in spectral_issues if (i.get("severity") or 99) >= 2),
            "issues": spectral_issues[:100],
        }

    # Wrap report with appname envelope
    wrapped_report = {
        "appname": appname,
        "report": dashboard_report,
    }

    # Save reports
    report_file = output_dir / f"green-score-report-{timestamp_file}.json"
    latest_file = output_dir / "latest-report.json"

    with open(report_file, "w", encoding="utf-8") as f:
        json.dump(wrapped_report, f, indent=2)
    with open(latest_file, "w", encoding="utf-8") as f:
        json.dump(wrapped_report, f, indent=2)

    log(f"Report: {report_file}", "OK")
    log(f"Latest: {latest_file}", "OK")

    # Purge old reports: keep only the 5 most recent (+ latest-report.json)
    log("🧹 Purge des anciens rapports (conservation des 5 derniers)...", "INFO")
    all_reports = sorted(
        output_dir.glob("green-score-report-*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for old_report in all_reports[5:]:
        log(f"  🗑️  Suppression : {old_report.name}", "INFO")
        old_report.unlink(missing_ok=True)

    # Analysis summary
    summary = {
        "appname": appname,
        "timestamp": timestamp_str,
        "service_base_url": base_url,
        "service_base_urls": all_base_urls,
        "green_score": green_score,
        "totals": {
            "endpoints_discovered": len(endpoints),
            "endpoints_measured": len(measurements),
            "total_bytes": sum(m["size_download"] for m in measurements.values()),
            "total_time_s": sum(m["time_total"] for m in measurements.values()),
            "energy_total_wh": sum(m.get("energy_total_wh", 0) for m in measurements.values()),
        },
        "endpoints": [{k: v for k, v in m.items() if k != "response_headers"}
                      for m in measurements.values()],
    }
    summary_file = output_dir / "analysis" / "latest-summary.json"
    summary_file.parent.mkdir(parents=True, exist_ok=True)
    with open(summary_file, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    # ── Step 6: Generate Dashboard ──
    if not args.skip_dashboard:
        dashboard_py = script_dir / "generate-dashboard.py"
        template = root_dir / "dashboard" / "index.save.html"
        out_html = root_dir / "dashboard" / "index.html"
        if dashboard_py.is_file() and template.is_file():
            log("Generating dashboard...")
            try:
                subprocess.run([
                    sys.executable, str(dashboard_py),
                    "--report", str(latest_file),
                    "--template", str(template),
                    "--output", str(out_html),
                ], check=True, capture_output=True, text=True, timeout=30)
                log(f"Dashboard written to {out_html}", "OK")
            except Exception as e:
                log(f"Dashboard generation error: {e}", "WARN")
        else:
            log("Dashboard template or generator not found. Skipping.", "WARN")

    # ── Final Summary ──
    print()
    print("=" * 60)
    print(f"  APP: {appname}")
    print(f"  GREEN SCORE: {green_score['total']}/{green_score['max']}   Grade: {green_score['grade']}")
    print(f"  Endpoints discovered: {len(endpoints)}")
    print(f"  Endpoints measured:   {len(measurements)}")
    print()
    print("  Rules breakdown:")
    for rk, rd in rule_mapping.items():
        icon = "✅" if rd["validated"] else "❌"
        print(f"    {icon} {rd['id']:20s} {rd['score']:3d}/{rd['max_pts']:3d}  "
              f"({rd['matched_count']}/{rd['candidate_count']} resources)")
    print()
    print(f"  Report:    {report_file}")
    print(f"  Mapping:   {mapping_file}")
    print(f"  Dashboard: dashboard/index.html")
    print("=" * 60)

    # Return non-zero if below threshold
    threshold_file = root_dir / "green-score-threshold.json"
    if threshold_file.is_file():
        threshold = json.loads(threshold_file.read_text(encoding="utf-8"))
        min_score = threshold.get("minScore", 0)
        if green_score["total"] < min_score:
            log(f"FAIL: Score {green_score['total']} < threshold {min_score}", "ERR")
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

