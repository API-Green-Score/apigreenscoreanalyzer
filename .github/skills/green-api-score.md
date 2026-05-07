---
name: green-api-score
description: Analyze an API endpoint or controller and calculate its Green API Score (0-123 pts)
---

Analyze the provided code for Green API Score compliance.

For each rule, determine if it passes or fails:

| Rule | Points | Check |
|------|--------|-------|
| DE11 Pagination | /15 | Collection endpoints have `page`/`size` or `limit`/`offset` params |
| DE08 Fields | /15 | `fields` query param supported |
| DE01 Compression | /15 | Gzip middleware configured |
| DE02/DE03 Cache | /15 | ETag generated + 304 on If-None-Match |
| DE06 Delta | /10 | `/changes?since=` endpoint exists |
| 206 Range | /10 | Range header → 206 Partial Content |
| BIN01 Binary | /10 | CBOR/Protobuf/MessagePack endpoint |
| LO01 Observability | /5 | `/health` or `/actuator/health` |
| US07 Rate Limit | /5 | 429 response on abuse |
| AR01 Event-driven | /6 | Webhooks/SSE/WebSocket |
| AR02 Proximity | /7 | CDN/edge/multi-region |
| AR03 Single API | /3 | No duplicate API |
| AR04 Scalable | /5 | HPA/KEDA/autoscale |
| AR05 Carbon | /2 | Cloud carbon dashboard |

Output:
1. Score breakdown table with ✅/❌
2. Total score and grade (A/B/C/D/E)
3. Top 3 fixes to gain the most points

