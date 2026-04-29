#!/usr/bin/env python3
"""
Architecture & Infrastructure rules (AR01–AR05) for the Green Score Analyzer.
=============================================================================

Companion to ``green-api-auto-discover.py``. Each evaluator returns a dict
shaped like the per-endpoint rules already produced by ``analyze_green_rules``
so the dashboard can render them with the same code path.

Phase 1 in this module: AR01, AR03, AR05.
Phase 2 in this module: AR04 (IaC + serverless deps scan via ``--source-dir``)
and AR01 enrichment with messaging-broker dependency signals.
Phase 3 in this module: AR02 (TLS handshake latency, CDN edge headers,
multi-region spec, anycast ASN via optional ``--enable-geoip`` and
consumer distance via ``--consumer-region``).

Design rules — strict:
  • stdlib-only (no requests/numpy/yaml unless already optional in the parent)
  • every detection signal MUST be cross-validatable (no single weak hint
    is allowed to push a rule from "not matched" to "matched")
  • emits an ``evidence`` list — ``{kind, where, value}`` — so the dashboard
    can show *why* a rule passed/failed
  • emits ``recommendations`` and, for AR01, an ``EDA Migration Advisor``
    that suggests where to migrate polling endpoints to events/streams
"""
from __future__ import annotations

import json
import os
import re
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


# ─── Public catalogue ──────────────────────────────────────────────────────
#
# Weights confirmed by the user (Option A — additive on top of the 100-pts
# legacy score). Total architecture+infrastructure budget = 23 pts.
ARCH_RULES: dict[str, dict] = {
    "AR01_event_driven": {
        "id": "AR01",
        "label": "Event-Driven Architecture",
        "max_pts": 6,
        "category": "architecture",
        "description": (
            "Utiliser une architecture événementielle (callbacks/webhooks, AsyncAPI, "
            "SSE, WebSocket, broker de messages) pour éviter le polling et "
            "réduire la pression réseau côté consommateurs."
        ),
    },
    "AR02_runtime_close": {
        "id": "AR02",
        "label": "Runtime proche du consommateur",
        "max_pts": 7,
        "category": "architecture",
        "description": (
            "Déployer l'API au plus près des consommateurs (CDN, edge, "
            "anycast multi-régions) pour réduire l'empreinte réseau."
        ),
    },
    "AR03_unique_api": {
        "id": "AR03",
        "label": "Une seule API par besoin",
        "max_pts": 3,
        "category": "architecture",
        "description": (
            "Éviter la duplication d'APIs servant le même besoin "
            "(double infrastructure = double empreinte)."
        ),
    },
    "AR04_scalable_infra": {
        "id": "AR04",
        "label": "Infrastructure scalable",
        "max_pts": 5,
        "category": "infrastructure",
        "description": (
            "Préférer une infrastructure auto-scalable (HPA, KEDA, autoscale, "
            "serverless) pour éviter le sur-provisionnement."
        ),
    },
    "AR05_cloud_footprint": {
        "id": "AR05",
        "label": "Dashboard d'empreinte du cloud provider",
        "max_pts": 2,
        "category": "infrastructure",
        "description": (
            "Suivre l'empreinte carbone via le dashboard natif du provider "
            "(AWS Customer Carbon Footprint Tool, Azure Emissions Impact "
            "Dashboard, GCP Carbon Footprint…)."
        ),
    },
}


# ─── Helpers ───────────────────────────────────────────────────────────────

# AsyncAPI discovery paths (similar in spirit to SWAGGER_DISCOVERY_PATHS).
ASYNCAPI_DISCOVERY_PATHS = [
    "/asyncapi.json",
    "/asyncapi.yaml",
    "/asyncapi",
    "/v3/asyncapi",
    "/.well-known/asyncapi",
]

# Headers that strongly indicate a CDN / edge proxy / cloud provider.
# Matching is case-insensitive — header dicts in the analyzer are lowered.
CDN_HEADER_PATTERNS: list[tuple[str, str, str]] = [
    # (provider, header_name_lower, regex_value_or_"*")
    ("cloudflare", "cf-ray", r".+"),
    ("cloudflare", "cf-cache-status", r".+"),
    ("cloudflare", "server", r"cloudflare"),
    ("aws-cloudfront", "x-amz-cf-id", r".+"),
    ("aws-cloudfront", "x-amz-cf-pop", r".+"),
    ("aws-cloudfront", "via", r"cloudfront"),
    ("aws", "x-amzn-requestid", r".+"),
    ("aws", "x-amz-request-id", r".+"),
    ("azure-frontdoor", "x-azure-ref", r".+"),
    ("azure-frontdoor", "x-azure-fdid", r".+"),
    ("azure", "x-ms-request-id", r".+"),
    ("azure", "x-msedge-ref", r".+"),
    ("gcp", "x-goog-trace", r".+"),
    ("gcp", "x-cloud-trace-context", r".+"),
    ("gcp-loadbalancer", "via", r"google"),
    ("akamai", "x-akamai-request-id", r".+"),
    ("akamai", "x-akamai-staging", r".+"),
    ("fastly", "x-served-by", r"cache-"),
    ("fastly", "x-fastly-request-id", r".+"),
    ("fastly", "fastly-debug-digest", r".+"),
    ("varnish-edge", "x-varnish", r".+"),
]


def _http_head_only(url: str, headers: dict | None = None, timeout: int = 5) -> dict:
    """HEAD probe returning lowercase response headers (or {} on failure)."""
    req = urllib.request.Request(url, method="HEAD", headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return {k.lower(): v for k, v in resp.getheaders()}
    except urllib.error.HTTPError as e:
        try:
            return {k.lower(): v for k, v in e.headers.items()}
        except Exception:
            return {}
    except Exception:
        return {}


def _http_get_bytes(url: str, headers: dict | None = None, timeout: int = 6) -> tuple[int, bytes, dict]:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), {k.lower(): v for k, v in resp.getheaders()}
    except urllib.error.HTTPError as e:
        body = e.read() if hasattr(e, "read") else b""
        return e.code, body, {}
    except Exception:
        return 0, b"", {}


# ═══════════════════════════════════════════════════════════════════════════
# AR01 — Event-Driven Architecture
# ═══════════════════════════════════════════════════════════════════════════

# Poll-ish path tokens that suggest an endpoint exists *because* the API has no
# events. Used by the EDA Migration Advisor.
_POLLING_PATH_RE = re.compile(
    r"/(changes|since|events|notifications|updates|polls?|tail|delta)\b",
    flags=re.IGNORECASE,
)
_LONGPOLL_QUERY_NAMES = {"wait", "timeout", "polltimeout", "poll_timeout",
                         "longpoll", "long_poll", "since", "after"}


def _collect_callbacks(spec: dict) -> list[dict]:
    """OAS 3.x callbacks declared on operations.

    A *callback* is a strong proof that the API publishes events to consumers.
    """
    out = []
    for path, ops in (spec.get("paths") or {}).items():
        if not isinstance(ops, dict):
            continue
        for method, op in ops.items():
            if not isinstance(op, dict):
                continue
            cb = op.get("callbacks")
            if isinstance(cb, dict) and cb:
                out.append({
                    "path": path, "method": method.upper(),
                    "callbacks": list(cb.keys()),
                })
    return out


def _collect_webhooks(spec: dict) -> list[str]:
    """OAS 3.1 top-level ``webhooks`` keys."""
    wh = spec.get("webhooks")
    return list(wh.keys()) if isinstance(wh, dict) else []


def _detect_streaming_endpoints(spec: dict, measurements: dict) -> list[dict]:
    """Cross-validation spec + runtime: endpoints declaring text/event-stream
    in OAS *and* confirmed by the runtime Content-Type observed during the
    measurement step. Strong signal for SSE."""
    declared = []
    for path, ops in (spec.get("paths") or {}).items():
        if not isinstance(ops, dict):
            continue
        for method, op in ops.items():
            if not isinstance(op, dict):
                continue
            for resp in (op.get("responses") or {}).values():
                if not isinstance(resp, dict):
                    continue
                for media_type in (resp.get("content") or {}).keys():
                    if "event-stream" in media_type.lower():
                        declared.append({
                            "path": path, "method": method.lower(),
                            "media_type": media_type,
                        })
                        break
    confirmed = []
    for d in declared:
        key = f"{d['method']}:{d['path']}"
        m = measurements.get(key) or {}
        ct = (m.get("response_headers") or {}).get("content-type", "")
        if "event-stream" in ct.lower():
            confirmed.append({**d, "runtime_content_type": ct})
    return confirmed


def _discover_asyncapi(base_urls: list[str]) -> list[dict]:
    """Probe every base_url for an AsyncAPI document.

    AsyncAPI is the canonical proof of a documented event-driven contract.
    """
    out = []
    for base in base_urls:
        if not base:
            continue
        for p in ASYNCAPI_DISCOVERY_PATHS:
            url = base.rstrip("/") + p
            code, body, hdrs = _http_get_bytes(url, timeout=4)
            if code != 200 or not body:
                continue
            txt = body.decode("utf-8", errors="replace")
            # Heuristic: must mention "asyncapi" version key in JSON or YAML
            if re.search(r'(?i)["\']?asyncapi["\']?\s*[:=]\s*["\']?\d', txt):
                out.append({"base_url": base, "asyncapi_url": url})
                break
    return out


def _eda_migration_advisor(spec: dict, endpoints: list[dict],
                            measurements: dict) -> list[dict]:
    """Produce per-endpoint suggestions to migrate to event/stream patterns.

    Each suggestion is anchored to a concrete *condition* with evidence so
    the dashboard can render it with traceability.
    """
    advice: list[dict] = []

    for ep in endpoints:
        path = ep.get("path", "")
        method = ep.get("method", "").lower()
        params = ep.get("parameters") or []
        key = f"{method}:{path}"
        m = measurements.get(key) or {}
        m_headers = m.get("response_headers") or {}

        # Condition 1 — polling-flavoured path (changes/events/notifications/…)
        if _POLLING_PATH_RE.search(path):
            advice.append({
                "endpoint": {"method": method.upper(), "path": path},
                "condition": "polling-path-token",
                "evidence": f"Path matches /(changes|since|events|notifications|updates|polls)/",
                "suggestion": (
                    "Remplacer le polling par un flux d'événements: exposer le "
                    "même besoin via SSE (text/event-stream) ou un sujet "
                    "AsyncAPI/Kafka pour pousser les changements aux abonnés."
                ),
                "target_pattern": "SSE or AsyncAPI subscription",
            })

        # Condition 2 — long-polling query parameters
        param_names = {(p or {}).get("name", "").lower() for p in params}
        if param_names & _LONGPOLL_QUERY_NAMES and method == "get":
            present = sorted(param_names & _LONGPOLL_QUERY_NAMES)
            advice.append({
                "endpoint": {"method": method.upper(), "path": path},
                "condition": "long-polling-query",
                "evidence": f"Query params suggesting long-poll: {', '.join(present)}",
                "suggestion": (
                    "Long-polling détecté → migrer vers WebSocket ou SSE. "
                    "Le client ouvre une seule connexion et reçoit les "
                    "événements push, divisant les RTT/CPU par 10 à 100×."
                ),
                "target_pattern": "WebSocket or SSE",
            })

        # Condition 3 — Retry-After observed at runtime (rate-limited)
        ra = m_headers.get("retry-after") or m_headers.get("x-ratelimit-reset")
        if ra:
            advice.append({
                "endpoint": {"method": method.upper(), "path": path},
                "condition": "rate-limited",
                "evidence": f"Server returned Retry-After/X-RateLimit-Reset = {ra}",
                "suggestion": (
                    "L'endpoint est rate-limité, signe d'une charge en polling. "
                    "Publier un événement domaine et laisser les consommateurs "
                    "s'abonner réduira la pression et les rejets."
                ),
                "target_pattern": "Domain Event / AsyncAPI",
            })

        # Condition 4 — x-poll-interval extension (explicit polling contract)
        # We look at the per-operation node by reading from the spec.
        try:
            op = ((spec.get("paths") or {}).get(path) or {}).get(method) or {}
        except Exception:
            op = {}
        if isinstance(op, dict):
            for ext_key in op.keys():
                if isinstance(ext_key, str) and ext_key.lower() in (
                    "x-poll-interval", "x-polling-interval", "x-polling"
                ):
                    advice.append({
                        "endpoint": {"method": method.upper(), "path": path},
                        "condition": "explicit-polling-extension",
                        "evidence": f"OpenAPI extension {ext_key} present on the operation",
                        "suggestion": (
                            "Une extension explicite de polling indique un cas "
                            "d'usage parfait pour AsyncAPI/EventGrid/EventBridge."
                        ),
                        "target_pattern": "AsyncAPI subscription",
                    })

        # Condition 5 — mutating endpoint without callbacks/webhooks
        if method in ("post", "put", "patch", "delete") and isinstance(op, dict):
            has_cb = isinstance(op.get("callbacks"), dict) and op["callbacks"]
            if not has_cb:
                advice.append({
                    "endpoint": {"method": method.upper(), "path": path},
                    "condition": "mutating-without-callback",
                    "evidence": "Mutation declared but no OAS callbacks/webhooks",
                    "suggestion": (
                        "Publier un événement domaine après mutation "
                        "(Kafka/RabbitMQ/Azure Service Bus/EventBridge) "
                        "pour découpler les consommateurs. Documenter via "
                        "callbacks (OAS 3.x) ou un AsyncAPI dédié."
                    ),
                    "target_pattern": "Domain Event publication",
                })

    # Dedupe (same endpoint, same condition)
    seen = set()
    deduped = []
    for a in advice:
        k = (a["endpoint"]["method"], a["endpoint"]["path"], a["condition"])
        if k in seen:
            continue
        seen.add(k)
        deduped.append(a)
    return deduped


def evaluate_AR01(spec: dict, base_urls: list[str], endpoints: list[dict],
                  measurements: dict) -> dict:
    """AR01 — Event-Driven Architecture.

    Strong signals (Phase 1, spec + runtime only):
      • OAS callbacks on at least 1 operation
      • OAS 3.1 webhooks
      • AsyncAPI document discovered on any base URL
      • SSE: declared in spec ``content`` AND confirmed by runtime Content-Type
    """
    callbacks = _collect_callbacks(spec)
    webhooks = _collect_webhooks(spec)
    asyncapi_docs = _discover_asyncapi(base_urls)
    sse_endpoints = _detect_streaming_endpoints(spec, measurements)

    evidence: list[dict] = []
    candidates: list[dict] = []
    for cb in callbacks:
        evidence.append({"kind": "spec", "where": f"{cb['method']} {cb['path']}",
                         "value": f"callbacks: {', '.join(cb['callbacks'])}"})
        candidates.append({"method": cb["method"], "path": cb["path"],
                           "matched": True, "reason": "OAS callbacks declared"})
    for w in webhooks:
        evidence.append({"kind": "spec", "where": "webhooks",
                         "value": f"webhook: {w}"})
        candidates.append({"method": "POST", "path": f"webhook:{w}",
                           "matched": True, "reason": "OAS 3.1 webhook declared"})
    for a in asyncapi_docs:
        evidence.append({"kind": "asyncapi", "where": a["base_url"],
                         "value": a["asyncapi_url"]})
    for s in sse_endpoints:
        evidence.append({"kind": "runtime+spec", "where": f"{s['method'].upper()} {s['path']}",
                         "value": f"SSE confirmed (Content-Type: {s['runtime_content_type']})"})
        candidates.append({"method": s["method"].upper(), "path": s["path"],
                           "matched": True, "reason": "SSE declared & confirmed at runtime"})

    matched = bool(callbacks or webhooks or asyncapi_docs or sse_endpoints)
    max_pts = ARCH_RULES["AR01_event_driven"]["max_pts"]
    score = max_pts if matched else 0

    advice = _eda_migration_advisor(spec, endpoints, measurements)
    recommendations: list[str] = []
    if not matched:
        if advice:
            recommendations.append(
                f"Aucun signal EDA détecté mais {len(advice)} opportunité(s) "
                "de migration vers SSE/AsyncAPI/WebSocket trouvées (cf. EDA Advisor)."
            )
        else:
            recommendations.append(
                "Aucun signal EDA détecté. Documentez vos flux d'événements via "
                "AsyncAPI ou ajoutez des callbacks/webhooks dans votre OpenAPI."
            )
    else:
        recommendations.append(
            "Architecture événementielle détectée. Vérifiez que la documentation "
            "(AsyncAPI/callbacks) couvre tous les flux asynchrones."
        )

    return {
        "rule_id": "AR01",
        "score": score,
        "max_pts": max_pts,
        "matched": matched,
        "category": "architecture",
        "candidates": candidates,
        "evidence": evidence,
        "recommendations": recommendations,
        "migration_advice": advice,
    }


# ═══════════════════════════════════════════════════════════════════════════
# AR03 — Ensure only one API fits the same need
# ═══════════════════════════════════════════════════════════════════════════

_VERSION_PREFIX_RE = re.compile(r"^/v\d+(?=/)", flags=re.IGNORECASE)


def _normalise_path(path: str) -> str:
    """Replace ``{name}`` placeholders by ``{}`` and strip a leading version
    segment so that ``/v1/books/{id}`` and ``/v2/books/{id}`` look the same.
    """
    p = _VERSION_PREFIX_RE.sub("", path or "")
    p = re.sub(r"\{[^}]+\}", "{}", p)
    return p


def _operation_signature(method: str, path: str, op: dict) -> tuple:
    norm_path = _normalise_path(path)
    params = op.get("parameters") or []
    required_params = sorted(
        (p.get("name", "") for p in params if isinstance(p, dict) and p.get("required"))
    )
    responses = sorted((op.get("responses") or {}).keys())
    return (method.upper(), norm_path, tuple(required_params), tuple(responses))


def _all_operation_signatures(spec: dict) -> set[tuple]:
    sigs = set()
    for path, ops in (spec.get("paths") or {}).items():
        if not isinstance(ops, dict):
            continue
        for method, op in ops.items():
            if not isinstance(op, dict):
                continue
            if method not in ("get", "post", "put", "patch", "delete", "head"):
                continue
            sigs.add(_operation_signature(method, path, op))
    return sigs


def _all_tags(spec: dict) -> set[str]:
    tags = set()
    for ops in (spec.get("paths") or {}).values():
        if not isinstance(ops, dict):
            continue
        for op in ops.values():
            if isinstance(op, dict):
                for t in op.get("tags") or []:
                    if isinstance(t, str):
                        tags.add(t.lower())
    return tags


def _summary_tokens(spec: dict) -> dict[str, int]:
    """Tiny TF-light bag of words from operation summaries (for cosine-ish)."""
    bow: dict[str, int] = {}
    for ops in (spec.get("paths") or {}).values():
        if not isinstance(ops, dict):
            continue
        for op in ops.values():
            if not isinstance(op, dict):
                continue
            text = (op.get("summary") or "") + " " + (op.get("description") or "")
            for tok in re.findall(r"[A-Za-z]{3,}", text.lower()):
                bow[tok] = bow.get(tok, 0) + 1
    return bow


def _cosine_bow(a: dict[str, int], b: dict[str, int]) -> float:
    if not a or not b:
        return 0.0
    common = set(a) & set(b)
    if not common:
        return 0.0
    dot = sum(a[k] * b[k] for k in common)
    na = sum(v * v for v in a.values()) ** 0.5
    nb = sum(v * v for v in b.values()) ** 0.5
    return dot / (na * nb) if na and nb else 0.0


def _jaccard(a: set, b: set) -> float:
    if not a and not b:
        return 0.0
    union = a | b
    return len(a & b) / len(union) if union else 0.0


# ═══════════════════════════════════════════════════════════════════════════
# AR02 — Runtime close to the consumer (Phase 3)
# ═══════════════════════════════════════════════════════════════════════════

# Tokens commonly embedded in regional hostnames / server URLs.
_REGION_TOKEN_RE = re.compile(
    r"\b("
    r"us-?(?:east|west|central|north|south)(?:-\d)?|"
    r"eu-?(?:west|central|north|south)(?:-\d)?|"
    r"ap-?(?:south|southeast|northeast|east)(?:-\d)?|"
    r"ca-?central(?:-\d)?|sa-?east(?:-\d)?|af-?south(?:-\d)?|me-?(?:south|central)(?:-\d)?|"
    r"westeurope|northeurope|eastus2?|westus[23]?|centralus|southcentralus|"
    r"francecentral|germanywestcentral|uksouth|ukwest|"
    r"asia-?(?:east|southeast|south|northeast)(?:\d)?|"
    r"europe-?(?:west|north|central)(?:\d)?"
    r")\b",
    flags=re.IGNORECASE,
)

# ASN / org tokens that strongly imply an anycast / global edge network.
_ANYCAST_ORG_TOKENS = (
    "cloudflare", "fastly", "akamai", "google", "amazon", "microsoft",
    "azure", "cloudfront", "cdnetworks", "stackpath", "edgecast",
    "incapsula", "imperva", "bunny", "keycdn",
)


def _tls_handshake_seconds(host: str, port: int = 443, timeout: float = 5.0,
                           samples: int = 3) -> dict:
    """Measure the TLS handshake duration (median over `samples` runs).

    Returns ``{"median_ms": float, "samples_ms": [...], "ok": bool}``.
    A failed probe returns ``{"ok": False, "error": "..."}``.
    """
    timings: list[float] = []
    err = None
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # latency probe only — no PKI assertion
    for _ in range(max(1, samples)):
        try:
            t0 = time.perf_counter()
            with socket.create_connection((host, port), timeout=timeout) as raw:
                with ctx.wrap_socket(raw, server_hostname=host) as _ssock:
                    pass
            timings.append((time.perf_counter() - t0) * 1000.0)
        except Exception as e:  # noqa: BLE001
            err = str(e)
            break
    if not timings:
        return {"ok": False, "error": err or "no samples"}
    timings.sort()
    median = timings[len(timings) // 2]
    return {"ok": True, "median_ms": round(median, 1),
            "samples_ms": [round(t, 1) for t in timings]}


def _resolve_ips(host: str) -> list[str]:
    """Best-effort DNS A/AAAA resolution. Returns deduped IP strings."""
    ips: set[str] = set()
    try:
        for fam, _stype, _proto, _cn, sa in socket.getaddrinfo(host, None):
            if fam in (socket.AF_INET, socket.AF_INET6) and sa and sa[0]:
                ips.add(sa[0])
    except Exception:
        return []
    return sorted(ips)


def _ipinfo_lookup(ip: str, timeout: int = 4) -> dict:
    """Optional GeoIP lookup via ipinfo.io (no API key — anonymous tier).

    Returns ``{country, region, city, org}`` (best effort; empty on failure).
    Only called when the user opts in with ``--enable-geoip``.
    """
    if not ip:
        return {}
    url = f"https://ipinfo.io/{ip}/json"
    code, body, _ = _http_get_bytes(url, timeout=timeout)
    if code != 200 or not body:
        return {}
    try:
        return json.loads(body.decode("utf-8", errors="replace")) or {}
    except Exception:
        return {}


def _spec_servers(spec: dict) -> list[str]:
    """Return raw `servers[].url` from an OpenAPI spec (deduped, order-stable)."""
    out: list[str] = []
    seen: set[str] = set()
    for s in (spec.get("servers") or []):
        if not isinstance(s, dict):
            continue
        u = (s.get("url") or "").strip()
        if u and u not in seen:
            seen.add(u)
            out.append(u)
    return out


def evaluate_AR02(spec: dict, base_urls: list[str], measurements: dict,
                  *, consumer_region: str = "",
                  enable_geoip: bool = False) -> dict:
    """AR02 — Runtime close to the consumer.

    Cross-validated signals (max 7 pts):
      • CDN/edge headers (2 pts)        — confirmed by ≥1 measurement AND
                                          a fresh HEAD probe to the base URL.
      • Multi-region servers (2 pts)    — OAS `servers` lists ≥2 hostnames
                                          AND distinct DNS resolution OR
                                          recognised regional tokens.
      • TLS handshake latency (2 pts)   — median over 3 samples vs base host.
                                          <150 ms → 2 pts, <300 ms → 1 pt.
      • Anycast ASN (1 pt, optional)    — only when ``enable_geoip`` is set;
                                          ipinfo.io org/ASN matches a known
                                          anycast/CDN provider AND the same
                                          provider was already seen in
                                          edge headers.
    """
    max_pts = ARCH_RULES["AR02_runtime_close"]["max_pts"]
    score = 0
    evidence: list[dict] = []
    recs: list[str] = []
    candidates: list[str] = []

    # ── 1) CDN / edge headers ──────────────────────────────────────────────
    runtime_providers = _detect_cloud_providers(measurements)
    head_providers: dict[str, list[str]] = {}
    for base in base_urls:
        if not base:
            continue
        h = _http_head_only(base, timeout=4)
        if not h:
            continue
        for provider, hname, value_re in CDN_HEADER_PATTERNS:
            v = h.get(hname)
            if not v:
                continue
            if value_re == r".+" or re.search(value_re, str(v), flags=re.IGNORECASE):
                head_providers.setdefault(provider, []).append(
                    f"HEAD {base} → {hname}: {v}"
                )
    confirmed_providers = sorted(set(runtime_providers) & set(head_providers))
    if confirmed_providers:
        score += 2
        candidates.extend(confirmed_providers)
        for p in confirmed_providers:
            for ev in (runtime_providers.get(p, [])[:2] + head_providers.get(p, [])[:1]):
                evidence.append({"kind": "cdn_header", "where": p, "value": ev})
    else:
        # informational evidence (mono-side hit) — no points
        for p, evs in (runtime_providers or head_providers).items():
            evidence.append({"kind": "cdn_header_uncorroborated",
                             "where": p, "value": evs[:1]})
        recs.append(
            "Aucun signal d'edge/CDN cross-validé (runtime + HEAD). Mettre l'API "
            "derrière un edge/CDN multi-régions (Cloudflare, CloudFront, "
            "Front Door, Fastly, Akamai…) pour rapprocher le runtime des consommateurs."
        )

    # ── 2) Multi-region servers (spec + DNS) ───────────────────────────────
    servers = _spec_servers(spec)
    server_hosts: list[str] = []
    for u in servers:
        try:
            h = urllib.parse.urlparse(u).hostname
            if h:
                server_hosts.append(h)
        except Exception:
            continue
    distinct_hosts = sorted(set(server_hosts))
    region_tokens = sorted({m.group(1).lower()
                            for u in servers
                            for m in [_REGION_TOKEN_RE.search(u)] if m})
    distinct_ips: set[str] = set()
    for h in distinct_hosts:
        for ip in _resolve_ips(h):
            distinct_ips.add(ip)
    if len(distinct_hosts) >= 2 and (len(distinct_ips) >= 2 or len(region_tokens) >= 2):
        score += 2
        evidence.append({"kind": "multi_region_servers", "where": "openapi.servers",
                         "value": {"hosts": distinct_hosts,
                                   "regions": region_tokens,
                                   "ip_count": len(distinct_ips)}})
    elif len(distinct_hosts) <= 1:
        recs.append(
            "La spec OpenAPI ne déclare qu'une seule URL de serveur. Ajouter "
            "plusieurs entrées `servers[]` régionales (ex: eu-west, us-east) "
            "pour documenter un déploiement multi-régions."
        )
    else:
        evidence.append({"kind": "single_region_dns", "where": "dns",
                         "value": {"hosts": distinct_hosts,
                                   "ip_count": len(distinct_ips),
                                   "regions": region_tokens}})
        recs.append(
            "Plusieurs URLs `servers[]` déclarées mais elles résolvent vers la "
            "même région DNS. Vérifier que chaque URL pointe bien vers un "
            "déploiement régional distinct (anycast ou DNS GSLB)."
        )

    # ── 3) TLS handshake latency ───────────────────────────────────────────
    tls_target = next((b for b in base_urls if b and b.lower().startswith("https://")), None)
    tls_result: dict = {}
    if tls_target:
        parsed = urllib.parse.urlparse(tls_target)
        host = parsed.hostname or ""
        port = parsed.port or 443
        if host:
            tls_result = _tls_handshake_seconds(host, port=port)
    if tls_result.get("ok"):
        ms = tls_result["median_ms"]
        if ms < 150:
            score += 2
            tier = "<150ms"
        elif ms < 300:
            score += 1
            tier = "<300ms"
        else:
            tier = ">=300ms"
        evidence.append({"kind": "tls_handshake_latency",
                         "where": tls_target,
                         "value": {"median_ms": ms, "tier": tier,
                                   "samples_ms": tls_result["samples_ms"],
                                   "consumer_region": consumer_region or None}})
        if ms >= 300:
            recs.append(
                f"Latence TLS médiane élevée ({ms} ms) depuis l'environnement "
                f"d'analyse. Activer un edge/CDN ou rapprocher le runtime "
                f"de la zone consommateur ({consumer_region or 'à préciser'})."
            )
    else:
        if not tls_target:
            evidence.append({"kind": "tls_skip", "where": "n/a",
                             "value": "no HTTPS target available"})
            recs.append(
                "Activer HTTPS sur la cible pour permettre la mesure de "
                "latence TLS et bénéficier d'un edge/CDN moderne."
            )
        elif tls_result:
            evidence.append({"kind": "tls_handshake_failed", "where": tls_target,
                             "value": tls_result.get("error", "unknown")})

    # ── 4) Optional GeoIP / anycast cross-check ────────────────────────────
    if enable_geoip:
        for h in distinct_hosts[:3]:  # cap external calls
            ips = _resolve_ips(h)
            if not ips:
                continue
            info = _ipinfo_lookup(ips[0])
            org = (info.get("org") or "").lower()
            if not org:
                continue
            evidence.append({"kind": "geoip_lookup",
                             "where": f"{h} ({ips[0]})",
                             "value": {"country": info.get("country"),
                                       "region": info.get("region"),
                                       "city": info.get("city"),
                                       "org": info.get("org")}})
            anycast_match = next((tok for tok in _ANYCAST_ORG_TOKENS if tok in org), None)
            if anycast_match and anycast_match in {p for p in confirmed_providers}:
                # cross-validation: provider seen in headers AND in ASN
                if not any(e.get("kind") == "anycast_asn" for e in evidence):
                    score += 1
                    evidence.append({"kind": "anycast_asn", "where": h,
                                     "value": {"org": info.get("org"),
                                               "matches_edge_provider": anycast_match}})
            elif consumer_region and info.get("country") and \
                    info.get("country", "").upper() != consumer_region.upper():
                recs.append(
                    f"Cible {h} hébergée en {info.get('country')} alors que les "
                    f"consommateurs sont en {consumer_region.upper()} — envisager "
                    "un déploiement régional plus proche."
                )
    elif consumer_region:
        evidence.append({"kind": "consumer_region_declared",
                         "where": "cli", "value": consumer_region.upper()})
        recs.append(
            "Activer --enable-geoip pour corréler la région des consommateurs "
            f"({consumer_region.upper()}) avec la localisation IP de l'API."
        )

    # Cap score
    score = min(score, max_pts)
    matched = score >= max_pts

    return {
        "rule_id": "AR02",
        "score": score,
        "max_pts": max_pts,
        "matched": matched,
        "category": "architecture",
        "candidates": candidates,
        "evidence": evidence[:50],
        "recommendations": recs,
        "signal_kinds": sorted({e["kind"] for e in evidence}),
    }


# ═══════════════════════════════════════════════════════════════════════════
# AR05 — Cloud Footprint Dashboard
# ═══════════════════════════════════════════════════════════════════════════

# Substrings that prove minimal observability is in place — required for the
# carbon dashboard to receive data. These are detected in the discovered base
# URLs (the analyzer already probes /actuator/health for readiness).
_OBSERVABILITY_PROBE_PATHS = [
    "/actuator/metrics",
    "/actuator/prometheus",
    "/metrics",
    "/q/metrics",       # Quarkus
]


def _detect_cloud_providers(measurements: dict) -> dict[str, list[str]]:
    """Return ``{provider: [evidence_strings]}`` based on response headers.

    Iterates over every measurement we already collected so we don't issue
    extra HTTP probes. A provider can be hit multiple times — we keep the
    list of evidences for the report.
    """
    found: dict[str, list[str]] = {}
    for ep_key, m in measurements.items():
        headers = (m or {}).get("response_headers") or {}
        for provider, hname, value_re in CDN_HEADER_PATTERNS:
            v = headers.get(hname)
            if not v:
                continue
            if value_re == r".+" or re.search(value_re, str(v), flags=re.IGNORECASE):
                ev = f"{ep_key} → {hname}: {v}"
                found.setdefault(provider, []).append(ev)
    return found


def _probe_observability(base_urls: list[str], auth_headers: dict | None) -> list[dict]:
    """Probe well-known observability endpoints. Returns list of hits."""
    hits = []
    for base in base_urls:
        if not base:
            continue
        for p in _OBSERVABILITY_PROBE_PATHS:
            url = base.rstrip("/") + p
            code, body, _ = _http_get_bytes(url, headers=auth_headers, timeout=4)
            if code == 200 and body:
                hits.append({"base_url": base, "url": url})
                break  # one hit per target is enough
    return hits


def evaluate_AR05(measurements: dict, base_urls: list[str],
                  auth_headers: dict | None,
                  cloud_dashboards: dict, footprint_confirmed: bool) -> dict:
    """AR05 — Cloud Footprint Dashboard.

    Score = max_pts only when:
      • a cloud provider is detected (by edge headers), AND
      • observability is exposed (actuator/prometheus reachable), AND
      • the operator confirmed the dashboard is being used
        (``--cloud-footprint-confirmed`` CLI flag).

    Otherwise the rule is *informational*: 0 points but rendered with the
    deep-link to the provider-native dashboard so teams can act on it.
    """
    max_pts = ARCH_RULES["AR05_cloud_footprint"]["max_pts"]

    providers = _detect_cloud_providers(measurements)
    obs_hits = _probe_observability(base_urls, auth_headers)

    # Resolve one canonical provider for the recommendation. Priority based on
    # specificity (frontdoor/cloudfront wins over generic aws/azure markers).
    canonical = None
    for pref in ("aws-cloudfront", "azure-frontdoor", "gcp-loadbalancer",
                 "akamai", "fastly", "cloudflare", "varnish-edge",
                 "aws", "azure", "gcp"):
        if pref in providers:
            canonical = pref.split("-")[0]   # "aws-cloudfront" → "aws"
            break

    evidence: list[dict] = []
    for prov, evs in providers.items():
        for ev in evs[:3]:                  # cap to avoid noise
            evidence.append({"kind": "header", "where": prov, "value": ev})
    for h in obs_hits:
        evidence.append({"kind": "observability", "where": h["base_url"],
                         "value": h["url"]})

    matched = bool(canonical and obs_hits and footprint_confirmed)
    score = max_pts if matched else 0

    recommendations: list[str] = []
    if canonical:
        url = (cloud_dashboards or {}).get(canonical)
        if url:
            recommendations.append(
                f"Cloud détecté: **{canonical.upper()}**. "
                f"Activez et consultez régulièrement le dashboard d'empreinte: {url}"
            )
    else:
        recommendations.append(
            "Aucun cloud provider détecté via les en-têtes HTTP. "
            "Si l'API est hébergée sur AWS/Azure/GCP/OVH, vérifiez l'exposition "
            "des en-têtes edge ou confirmez l'usage du dashboard manuellement."
        )
    if not obs_hits:
        recommendations.append(
            "Aucune télémétrie standard détectée (/actuator/metrics, /metrics, "
            "/q/metrics). Exposez les métriques pour alimenter le dashboard."
        )
    if canonical and obs_hits and not footprint_confirmed:
        recommendations.append(
            "Confirmez l'usage actif du dashboard d'empreinte avec "
            "``--cloud-footprint-confirmed`` pour valider AR05."
        )

    return {
        "rule_id": "AR05",
        "score": score,
        "max_pts": max_pts,
        "matched": matched,
        "category": "infrastructure",
        "candidates": [],
        "evidence": evidence,
        "recommendations": recommendations,
        "detected_provider": canonical,
        "providers_raw": providers,
    }


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2 — Source-dir & IaC scanner (stdlib-only)
# ═══════════════════════════════════════════════════════════════════════════
#
# Walks an optional ``--source-dir`` once, returns ``(rel_path, content)``
# tuples for every relevant build/IaC/deps file (capped to keep CI fast).
# Used by ``evaluate_AR04`` (auto-scaling/serverless) and ``evaluate_AR01``
# (messaging-broker dependency cross-validation).

_PHASE2_MAX_FILES = 2000
_PHASE2_MAX_FILE_BYTES = 512 * 1024       # 512 KB per file
_PHASE2_SKIP_DIRS = {
    "node_modules", "dist", "build", "target", "out", ".gradle", ".mvn",
    "venv", ".venv", "__pycache__", "bin", "obj", ".terraform",
    ".next", ".nuxt", "coverage", "vendor",
}
_PHASE2_RELEVANT_EXTS = {
    ".yaml", ".yml", ".tf", ".tfvars", ".bicep", ".json", ".xml",
    ".gradle", ".kts", ".csproj", ".fsproj", ".vbproj", ".props",
    ".toml", ".txt",
}
_PHASE2_RELEVANT_NAMES = {
    "Dockerfile", "Chart.yaml", "values.yaml", "values.yml",
    "pom.xml", "build.gradle", "build.gradle.kts", "package.json",
    "requirements.txt", "pyproject.toml", "Pipfile",
    "serverless.yml", "serverless.yaml", "template.yaml", "template.yml",
    "host.json", "function.json", "samconfig.toml", "azure.yaml",
}

# AR04 — auto-scaling / serverless signal regexes
_AR04_HPA_RE = re.compile(
    r"^\s*kind:\s*HorizontalPodAutoscaler\s*$",
    re.MULTILINE | re.IGNORECASE)
_AR04_KEDA_RE = re.compile(
    r"^\s*kind:\s*Scaled(Object|Job)\s*$",
    re.MULTILINE | re.IGNORECASE)
_AR04_HELM_AUTOSCALE_RE = re.compile(
    r"autoscaling[\s\S]{0,300}?enabled\s*:\s*true",
    re.IGNORECASE)
_AR04_TF_AUTOSCALE_RE = re.compile(
    r'resource\s+"(aws_autoscaling_group|aws_appautoscaling_target|'
    r"azurerm_monitor_autoscale_setting|azurerm_container_app|"
    r"google_compute_autoscaler|google_compute_region_autoscaler|"
    r"kubernetes_horizontal_pod_autoscaler[_v0-9]*|"
    r"aws_lambda_function|google_cloudfunctions2?_function|"
    r'azurerm_function_app|azurerm_linux_function_app)"',
    re.IGNORECASE)
_AR04_BICEP_AUTOSCALE_RE = re.compile(
    r"(microsoft\.insights/autoscalesettings|"
    r"autoscaleEnabled\s*[:=]\s*true|"
    r"properties\.scale\.minReplicas|"
    r"Microsoft\.Web/serverfarms[\s\S]{0,200}ElasticPremium)",
    re.IGNORECASE)
_AR04_SERVERLESS_FILES = {
    "serverless.yml", "serverless.yaml", "template.yaml", "template.yml",
    "host.json", "function.json", "samconfig.toml",
}
_AR04_FAAS_DEPS_RE = re.compile(
    r"(azure-functions-maven-plugin|aws-lambda-java-\w+|spring-cloud-function|"
    r"Microsoft\.Azure\.Functions[\w\.]*|Amazon\.Lambda\.[\w\.]*|"
    r'"serverless"\s*:|"aws-lambda"\s*:|@azure/functions|'
    r"firebase-functions|google-cloud-functions-framework|"
    r"chalice|zappa|aws-sam-cli)",
    re.IGNORECASE)

# AR01 — messaging/broker dependency regex (cross-validation only)
_AR01_BROKER_DEPS_RE = re.compile(
    r"(spring-kafka|spring-cloud-stream|spring-rabbit|spring-amqp|"
    r"activemq|pulsar-client|nats-streaming|"
    r"kafkajs|amqplib|@nestjs/microservices|node-rdkafka|"
    r'"mqtt"\s*:|"bull"\s*:|'
    r"Confluent\.Kafka|RabbitMQ\.Client|MassTransit[\w\.]*|"
    r"Azure\.Messaging\.(EventHubs|ServiceBus|EventGrid)|"
    r"Amazon\.SimpleNotificationService|AWSSDK\.SQS|"
    r"kafka-python|aiokafka|pika|celery|nats-py)",
    re.IGNORECASE)


def _phase2_walk(source_dir: str) -> list[tuple[str, str]]:
    """Return ``[(rel_path, content), ...]`` for every relevant file.

    Strict caps: ``_PHASE2_MAX_FILES`` files max, ``_PHASE2_MAX_FILE_BYTES``
    per file, hidden dirs and well-known build outputs skipped.
    """
    base_p = Path(source_dir).expanduser().resolve()
    if not base_p.is_dir():
        return []
    out: list[tuple[str, str]] = []
    count = 0
    for root, dirs, files in os.walk(base_p):
        # prune in-place: skip hidden dirs + known build/dep outputs
        dirs[:] = [d for d in dirs
                   if d not in _PHASE2_SKIP_DIRS and not d.startswith(".")]
        for fn in files:
            if count >= _PHASE2_MAX_FILES:
                return out
            ext = os.path.splitext(fn)[1].lower()
            if (fn in _PHASE2_RELEVANT_NAMES
                    or ext in _PHASE2_RELEVANT_EXTS
                    or fn.endswith((".csproj", ".fsproj", ".vbproj"))):
                fp = Path(root) / fn
                try:
                    if fp.stat().st_size > _PHASE2_MAX_FILE_BYTES:
                        continue
                    text = fp.read_text(encoding="utf-8", errors="replace")
                except Exception:
                    continue
                try:
                    rel = str(fp.relative_to(base_p))
                except ValueError:
                    rel = str(fp)
                out.append((rel, text))
                count += 1
    return out


def _scan_broker_deps(scanned: list[tuple[str, str]]) -> list[dict]:
    """Return AR01 supplementary evidence: messaging-broker deps in build files."""
    if not scanned:
        return []
    deps_files = (
        "pom.xml", "package.json", "build.gradle", "build.gradle.kts",
        "requirements.txt", "pyproject.toml", "Pipfile",
    )
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for rel, text in scanned:
        fn = os.path.basename(rel)
        if not (fn in deps_files or fn.endswith((".csproj", ".fsproj", ".vbproj"))):
            continue
        for m in _AR01_BROKER_DEPS_RE.finditer(text):
            tok = m.group(1).lower()
            key = (rel, tok)
            if key in seen:
                continue
            seen.add(key)
            out.append({
                "kind": "deps",
                "where": rel,
                "value": f"Messaging/broker dep: {m.group(1)}",
            })
            if len(out) >= 30:
                return out
    return out


# ═══════════════════════════════════════════════════════════════════════════
# AR04 — Scalable infrastructure (Phase 2)
# ═══════════════════════════════════════════════════════════════════════════

def evaluate_AR04(source_dir: str | None,
                  scanned: list[tuple[str, str]] | None = None) -> dict:
    """Detect auto-scaling / serverless markers from IaC + build files.

    Scoring (max 5 pts):
      • ``score = 5`` when **≥ 2 distinct signal kinds** are found
        (cross-validation, e.g. HPA + KEDA, or Terraform autoscale + FaaS deps)
      • ``score = 3`` (60%) when exactly **1** signal kind is found
      • ``score = 0`` otherwise (or no ``--source-dir`` provided)

    Signal kinds (cross-validation buckets):
      ``hpa``, ``keda``, ``helm-autoscale``, ``terraform-autoscale``,
      ``bicep-autoscale``, ``serverless-config``, ``faas-deps``.
    """
    max_pts = ARCH_RULES["AR04_scalable_infra"]["max_pts"]
    if not source_dir:
        return {
            "rule_id": "AR04", "score": 0, "max_pts": max_pts,
            "matched": False, "category": "infrastructure",
            "candidates": [], "evidence": [],
            "recommendations": [
                "AR04 nécessite --source-dir pour scanner IaC (HPA, KEDA, "
                "autoscale Terraform/Bicep) et marqueurs serverless "
                "(pom.xml, *.csproj, package.json)."
            ],
            "signal_kinds": [],
        }

    scanned = scanned if scanned is not None else _phase2_walk(source_dir)
    if not scanned:
        return {
            "rule_id": "AR04", "score": 0, "max_pts": max_pts,
            "matched": False, "category": "infrastructure",
            "candidates": [], "evidence": [],
            "recommendations": [
                f"--source-dir='{source_dir}' introuvable, vide ou aucun "
                "fichier IaC/build pertinent détecté."
            ],
            "signal_kinds": [],
        }

    evidence: list[dict] = []
    signals: set[str] = set()

    for rel, text in scanned:
        fn = os.path.basename(rel)
        is_yaml = rel.endswith((".yaml", ".yml"))

        # K8s HPA
        if is_yaml and _AR04_HPA_RE.search(text):
            signals.add("hpa")
            evidence.append({"kind": "iac", "where": rel,
                             "value": "Kubernetes HorizontalPodAutoscaler"})
        # KEDA
        if is_yaml and _AR04_KEDA_RE.search(text):
            signals.add("keda")
            evidence.append({"kind": "iac", "where": rel,
                             "value": "KEDA ScaledObject/ScaledJob"})
        # Helm values.yaml — autoscaling.enabled: true
        if fn in ("values.yaml", "values.yml") and _AR04_HELM_AUTOSCALE_RE.search(text):
            signals.add("helm-autoscale")
            evidence.append({"kind": "iac", "where": rel,
                             "value": "Helm autoscaling.enabled=true"})
        # Terraform
        if rel.endswith((".tf", ".tfvars")):
            m = _AR04_TF_AUTOSCALE_RE.search(text)
            if m:
                signals.add("terraform-autoscale")
                evidence.append({"kind": "iac", "where": rel,
                                 "value": f"Terraform: {m.group(1)}"})
        # Bicep / ARM JSON templates
        if rel.endswith(".bicep") or (rel.endswith(".json") and "Microsoft." in text):
            if _AR04_BICEP_AUTOSCALE_RE.search(text):
                signals.add("bicep-autoscale")
                evidence.append({"kind": "iac", "where": rel,
                                 "value": "Bicep/ARM autoscale settings"})
        # Serverless framework / SAM / Azure Functions / GCF config files
        if fn in _AR04_SERVERLESS_FILES:
            signals.add("serverless-config")
            evidence.append({"kind": "iac", "where": rel,
                             "value": f"Serverless config: {fn}"})
        # FaaS deps in build files
        if (fn in ("pom.xml", "package.json", "build.gradle",
                   "build.gradle.kts", "requirements.txt", "pyproject.toml")
                or fn.endswith((".csproj", ".fsproj", ".vbproj"))):
            m = _AR04_FAAS_DEPS_RE.search(text)
            if m:
                signals.add("faas-deps")
                evidence.append({"kind": "deps", "where": rel,
                                 "value": f"Serverless/FaaS dep: {m.group(1)}"})

    n = len(signals)
    matched = n >= 1
    if n >= 2:
        score = max_pts                  # 5/5 — cross-validated
    elif n == 1:
        score = round(max_pts * 0.6)     # 3/5 — partial
    else:
        score = 0

    if n >= 2:
        recs = [
            f"Auto-scaling/serverless validé ({n} types de signaux): "
            f"{', '.join(sorted(signals))}.",
        ]
    elif n == 1:
        recs = [
            f"Signal partiel ({next(iter(signals))}). Pour valider 5/5, "
            "ajouter un second signal indépendant (ex. HPA + KEDA, "
            "Terraform autoscale + FaaS deps)."
        ]
    else:
        recs = [
            "Aucun signal d'auto-scaling détecté dans les fichiers IaC/build.",
            "Activer HPA/KEDA (Kubernetes), autoscale Terraform/Bicep, "
            "ou déployer en serverless (Azure Functions, AWS Lambda, Cloud Run).",
        ]

    candidates = [
        {"method": "IaC", "path": ev["where"], "matched": True, "reason": ev["value"]}
        for ev in evidence[:10]
    ]

    return {
        "rule_id": "AR04",
        "score": int(score),
        "max_pts": max_pts,
        "matched": matched,
        "category": "infrastructure",
        "candidates": candidates,
        "evidence": evidence[:50],
        "recommendations": recs,
        "signal_kinds": sorted(signals),
        "scanned_files": len(scanned),
    }


# ═══════════════════════════════════════════════════════════════════════════
# Public entry point used by the analyzer
# ═══════════════════════════════════════════════════════════════════════════

def evaluate_architecture_rules(
    *,
    spec: dict,
    sources: list[tuple],
    endpoints: list[dict],
    measurements: dict,
    auth_headers: dict | None = None,
    thresholds: dict | None = None,
    cloud_dashboards: dict | None = None,
    footprint_confirmed: bool = False,
    enable_phase2: bool = False,   # source-dir/IaC/deps scan — wired in P2
    source_dir: str | None = None,
    consumer_region: str = "",     # AR02 Phase 3
    enable_geoip: bool = False,    # AR02 Phase 3
) -> dict[str, dict]:
    """Run every Architecture/Infrastructure rule and return:

        { rule_key: RuleResult }

    where ``rule_key`` matches ``ARCH_RULES`` keys. Rules not covered by the
    current phase return ``score=0, matched=False, category="…", evidence=[],
    recommendations=["Pending Phase 2/3 implementation"]`` so the dashboard
    can render placeholders without breaking layout.
    """
    base_urls = [b for (b, _spec, _src) in (sources or []) if b]
    specs_per_target = [(b, sp) for (b, sp, _src) in (sources or []) if sp]

    # Phase 2 — single source-dir walk shared by AR01 (broker deps) and AR04
    scanned_p2: list[tuple[str, str]] = []
    if enable_phase2 and source_dir:
        try:
            scanned_p2 = _phase2_walk(source_dir)
        except Exception:
            scanned_p2 = []

    out: dict[str, dict] = {}

    # ── AR01 — Event-Driven (spec/runtime + optional broker-deps evidence) ──
    ar01 = evaluate_AR01(spec, base_urls, endpoints, measurements)
    if scanned_p2:
        broker_ev = _scan_broker_deps(scanned_p2)
        if broker_ev:
            ar01.setdefault("evidence", []).extend(broker_ev)
            if not ar01.get("matched"):
                ar01.setdefault("recommendations", []).append(
                    f"{len(broker_ev)} dépendance(s) de broker détectée(s) dans le "
                    "source-dir mais aucun signal AsyncAPI/callbacks/SSE dans la "
                    "spec → documentez vos flux d'événements pour valider AR01."
                )
            else:
                ar01.setdefault("recommendations", []).append(
                    f"Cross-validation: {len(broker_ev)} dépendance(s) broker "
                    "trouvée(s) dans le code source — cohérent avec les signaux EDA."
                )
    out["AR01_event_driven"] = ar01

    # ── AR02 — Runtime close to consumer (Phase 3) ──
    try:
        out["AR02_runtime_close"] = evaluate_AR02(
            spec, base_urls,
            measurements,
            consumer_region=consumer_region or "",
            enable_geoip=bool(enable_geoip),
        )
    except Exception as e:  # noqa: BLE001
        out["AR02_runtime_close"] = {
            "rule_id": "AR02",
            "score": 0,
            "max_pts": ARCH_RULES["AR02_runtime_close"]["max_pts"],
            "matched": False,
            "category": "architecture",
            "candidates": [],
            "evidence": [{"kind": "error", "where": "evaluate_AR02",
                          "value": str(e)}],
            "recommendations": [
                "Évaluation AR02 en erreur — vérifier la connectivité réseau "
                "et les flags --enable-geoip / --consumer-region."
            ],
        }

    out["AR03_unique_api"] = evaluate_AR03(specs_per_target, thresholds)

    # ── AR04 — Scalable infrastructure (Phase 2: IaC + serverless deps) ──
    if enable_phase2 and source_dir:
        out["AR04_scalable_infra"] = evaluate_AR04(source_dir, scanned=scanned_p2)
    else:
        out["AR04_scalable_infra"] = {
            "rule_id": "AR04",
            "score": 0,
            "max_pts": ARCH_RULES["AR04_scalable_infra"]["max_pts"],
            "matched": False,
            "category": "infrastructure",
            "candidates": [],
            "evidence": [],
            "recommendations": [
                "AR04 sera évalué via scan IaC (HPA, KEDA, autoscale "
                "Terraform/Bicep) et marqueurs serverless dans "
                "pom.xml/*.csproj/package.json — passer --source-dir "
                "<chemin> pour activer le scan Phase 2."
            ],
            "signal_kinds": [],
        }

    out["AR05_cloud_footprint"] = evaluate_AR05(
        measurements, base_urls, auth_headers,
        cloud_dashboards or {}, footprint_confirmed,
    )

    return out


# ─── Self-test (manual) ────────────────────────────────────────────────────
if __name__ == "__main__":  # pragma: no cover
    import sys
    if len(sys.argv) < 2:
        print("Usage: architecture_rules.py <spec.json>")
        sys.exit(1)
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        s = json.load(f)
    res = evaluate_architecture_rules(
        spec=s, sources=[("http://localhost", s, sys.argv[1])],
        endpoints=[], measurements={}, footprint_confirmed=False,
    )
    print(json.dumps(res, indent=2, ensure_ascii=False))

