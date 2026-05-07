---
name: green-api-fix
description: Apply Green API Score fixes to existing code (pagination, fields, ETag, compression, etc.)
---

Apply Green API patterns to the provided code to maximize the score.

## Patterns to apply (in priority order):

1. **DE11 (15 pts)**: Add `page`/`size` params + `X-Total-Count` header to collections
2. **DE08 (15 pts)**: Add `fields` query param, filter response fields
3. **DE01 (15 pts)**: Enable gzip compression middleware
4. **DE02/DE03 (15 pts)**: Add ETag generation + 304 Not Modified
5. **DE06 (10 pts)**: Add `/changes?since=` endpoint
6. **206 (10 pts)**: Support Range header for large payloads
7. **BIN01 (10 pts)**: Add CBOR/Protobuf content negotiation
8. **LO01 (5 pts)**: Expose /health endpoint
9. **US07 (5 pts)**: Add rate limiting (429 + Retry-After)

Skip patterns already implemented. Mark each with inline comment.

Output the modified code and the estimated score gain.

