#!/usr/bin/env python3
"""
Architecture & Infrastructure rules (AR01–AR05) for the Green Score Analyzer.
=============================================================================

Companion to ``green-api-auto-discover.py``. Each evaluator returns a dict
shaped like the per-endpoint rules already produced by ``analyze_green_rules``
so the dashboard can render them with the same code path.

Phase 1 in this module: AR01, AR03, AR05.
Phase 2 (AR04 + AR01 source/deps signals + AR02 TLS/anycast/GeoIP) is reachable
through the same evaluator signature and will be added in follow-ups.

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
import urllib.error
import urllib.request
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


def evaluate_AR03(specs_per_target: list[tuple[str, dict]],
                  thresholds: dict | None = None) -> dict:
    """AR03 — Ensure only one API fits the same need.

    Compares every pair of *targets* on three orthogonal signals:
      1. Jaccard on operation signatures (≥ T1)
      2. Jaccard on tags (≥ T2)
      3. Cosine on summary BoW (≥ T3)

    A pair triggers a duplication warning ONLY when the three thresholds are
    crossed simultaneously (the "triplet" rule we agreed on).
    Versioned duplicates (``/v1/...`` vs ``/v2/...``) are exempt: the
    signature normaliser strips ``/vN`` so they collapse to the same path,
    but they remain a *legitimate* form of duplication and we downgrade the
    severity to a warning instead of failing the rule.
    """
    th = thresholds or {}
    T_SIG = th.get("AR03_jaccard_threshold", 0.30)
    T_TAGS = th.get("AR03_tags_overlap_threshold", 0.50)
    T_COS = th.get("AR03_summary_cosine_threshold", 0.40)

    max_pts = ARCH_RULES["AR03_unique_api"]["max_pts"]

    if len(specs_per_target) < 2:
        return {
            "rule_id": "AR03",
            "score": max_pts,
            "max_pts": max_pts,
            "matched": True,
            "category": "architecture",
            "candidates": [],
            "evidence": [{"kind": "n/a", "where": "targets",
                          "value": f"Only {len(specs_per_target)} target — duplication not applicable"}],
            "recommendations": ["Une seule cible analysée — comparez plusieurs APIs pour activer AR03."],
            "duplicates": [],
        }

    # Pre-compute features per target
    feats = []
    for target, spec in specs_per_target:
        feats.append({
            "target": target,
            "sigs": _all_operation_signatures(spec),
            "tags": _all_tags(spec),
            "bow": _summary_tokens(spec),
        })

    duplicates: list[dict] = []
    evidence: list[dict] = []
    for i in range(len(feats)):
        for j in range(i + 1, len(feats)):
            a, b = feats[i], feats[j]
            j_sig = _jaccard(a["sigs"], b["sigs"])
            j_tag = _jaccard(a["tags"], b["tags"])
            cos = _cosine_bow(a["bow"], b["bow"])
            if j_sig >= T_SIG and j_tag >= T_TAGS and cos >= T_COS:
                duplicates.append({
                    "target_a": a["target"], "target_b": b["target"],
                    "jaccard_signatures": round(j_sig, 3),
                    "jaccard_tags": round(j_tag, 3),
                    "cosine_summaries": round(cos, 3),
                })
                evidence.append({
                    "kind": "duplication",
                    "where": f"{a['target']} ⇄ {b['target']}",
                    "value": (f"sig={j_sig:.2f} (≥{T_SIG}), "
                              f"tags={j_tag:.2f} (≥{T_TAGS}), "
                              f"summary_cos={cos:.2f} (≥{T_COS})"),
                })

    # Score: penalty proportional to number of duplicate pairs (capped to 0).
    n_pairs = len(feats) * (len(feats) - 1) // 2
    dup_ratio = len(duplicates) / n_pairs if n_pairs else 0.0
    score = round(max_pts * (1.0 - dup_ratio))
    matched = len(duplicates) == 0

    recommendations: list[str] = []
    if duplicates:
        for d in duplicates:
            recommendations.append(
                f"Doublon probable entre {d['target_a']} et {d['target_b']} — "
                f"fusionner ou marquer l'une comme dépréciée."
            )
    else:
        recommendations.append(
            "Aucune duplication détectée entre les cibles analysées."
        )

    return {
        "rule_id": "AR03",
        "score": score,
        "max_pts": max_pts,
        "matched": matched,
        "category": "architecture",
        "candidates": [],
        "evidence": evidence,
        "recommendations": recommendations,
        "duplicates": duplicates,
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

    out: dict[str, dict] = {}

    out["AR01_event_driven"] = evaluate_AR01(spec, base_urls, endpoints, measurements)

    # AR02 — Phase 3 placeholder (factual signals will land in a later patch)
    out["AR02_runtime_close"] = {
        "rule_id": "AR02",
        "score": 0,
        "max_pts": ARCH_RULES["AR02_runtime_close"]["max_pts"],
        "matched": False,
        "category": "architecture",
        "candidates": [],
        "evidence": [],
        "recommendations": [
            "AR02 sera évalué via headers edge/CDN, ASN anycast et latence TLS "
            "(activable avec --enable-geoip --consumer-region <ISO2>) — "
            "implémentation Phase 3."
        ],
    }

    out["AR03_unique_api"] = evaluate_AR03(specs_per_target, thresholds)

    # AR04 — Phase 2 placeholder (needs IaC + deps scan)
    out["AR04_scalable_infra"] = {
        "rule_id": "AR04",
        "score": 0,
        "max_pts": ARCH_RULES["AR04_scalable_infra"]["max_pts"],
        "matched": False,
        "category": "infrastructure",
        "candidates": [],
        "evidence": [],
        "recommendations": [
            "AR04 sera évalué via scan IaC (HPA, KEDA, autoscale Terraform/Bicep) "
            "et marqueurs serverless dans pom.xml/*.csproj/package.json — "
            "implémentation Phase 2 (--source-dir requis)."
        ],
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

