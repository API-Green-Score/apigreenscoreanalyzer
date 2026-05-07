Fix the following code to achieve **maximum Green API Score**.

Apply ALL of the following patterns. If a pattern is already present, skip it.

## Fixes to apply:

### DE11 — Pagination (+15 pts)
Add `page` and `size` query params to all collection GET endpoints. Return `X-Total-Count` header.

### DE08 — Field filtering (+15 pts)
Add `fields` query param. Only serialize requested fields in response.

### DE01 — Compression (+15 pts)
Configure gzip/brotli compression middleware. Verify response includes `Content-Encoding`.

### DE02/DE03 — ETag + 304 (+15 pts)
Generate ETag from response content hash. Check `If-None-Match` header, return 304 if match.

### DE06 — Delta endpoint (+10 pts)
Add `GET /resource/changes?since=<ISO8601>` returning only modified items.

### 206 — Range / Partial Content (+10 pts)
Support `Range` header for binary or large list endpoints. Return `206` with `Content-Range`.

### BIN01 — Binary format (+10 pts)
Add content negotiation for `application/cbor` or `application/protobuf`.

### LO01 — Health endpoint (+5 pts)
Expose `/health` or `/actuator/health` with status and component checks.

### US07 — Rate limiting (+5 pts)
Add rate-limit middleware. Return `429 Too Many Requests` with `Retry-After` header.

### AR01 — Event-driven (+6 pts)
Replace polling patterns with webhooks, SSE, or WebSocket where applicable.

## Output:

For each fix applied:
```
🔧 [DE##] +N pts — description of change
   File: path
   Change: <summary>
```

Show the modified code with inline comments marking each rule: `// DE11: pagination`

Final estimate: **Green API Score: X/123 (Grade X)**

