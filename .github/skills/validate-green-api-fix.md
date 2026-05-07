---
name: validate-green-api-fix
description: Validate that a Green API fix is correct and actually gains the expected points
---

Validate the provided Green API fix for correctness and score impact.

## Validation checklist:

1. **Rule compliance**: Does the fix actually satisfy the Green API rule requirements?
2. **Functional correctness**: Does the endpoint still behave correctly?
3. **No regression**: Does the fix break other Green API patterns already in place?
4. **Score accuracy**: Is the claimed point gain realistic?

## Specific validations per rule:

### DE11 — Pagination
- ✅ `page` and `size` params present with defaults
- ✅ Response is a subset (not full collection)
- ✅ `X-Total-Count` header returned
- ❌ INVALID if: params exist but full collection is always returned

### DE08 — Field filtering
- ✅ `fields` param accepted
- ✅ Response actually omits unrequested fields
- ❌ INVALID if: param is accepted but ignored

### DE01 — Compression
- ✅ Middleware configured
- ✅ Response includes `Content-Encoding: gzip` when `Accept-Encoding: gzip` is sent
- ❌ INVALID if: only configured but never applied (wrong order, wrong mime-types)

### DE02/DE03 — ETag + 304
- ✅ ETag header present on GET responses
- ✅ `If-None-Match` check implemented
- ✅ Returns 304 (not 200 with empty body)
- ❌ INVALID if: ETag is static/hardcoded or never changes

### DE06 — Delta
- ✅ `/changes?since=` endpoint exists
- ✅ Returns only items modified after the timestamp
- ✅ `last_modified` / `updated_at` column exists and is indexed
- ❌ INVALID if: returns ALL items regardless of `since`

### US07 — Rate limiting
- ✅ Returns 429 when limit exceeded
- ✅ `Retry-After` header present
- ❌ INVALID if: configured but never triggered (infinite limit)

## Output:

```
✅ VALID   — Fix correctly implements DE## (+N pts confirmed)
⚠️ PARTIAL — Fix implements DE## but: [issue] (+N pts reduced to +M)
❌ INVALID — Fix does not satisfy DE## because: [reason] (+0 pts)
```

If invalid, provide the correct implementation.

