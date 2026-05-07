Review the following code for **Green API Score** and **Creedengo** compliance.

## Green API Rules — check each:
1. **DE11** — Pagination: Do collection endpoints support `page`/`size`?
2. **DE08** — Field filtering: Is there a `fields` query param?
3. **DE01** — Compression: Is gzip middleware configured?
4. **DE02/DE03** — Cache: Are ETags generated? Is 304 handled?
5. **DE06** — Delta: Is there a `/changes?since=` endpoint?
6. **206** — Range: Are large payloads supporting partial content?
7. **BIN01** — Binary: Is CBOR/Protobuf available?
8. **LO01** — Observability: Is `/health` exposed?
9. **US07** — Rate limiting: Is 429 returned on abuse?
10. **AR01** — Event-driven: Are webhooks/SSE used instead of polling?

## Creedengo Rules — check for violations:
- **GCI1/GCI72** — DB/repository calls inside loops
- **GCI74** — SELECT * without specifying columns
- **GCI77** — Pattern.compile() not static final (Java)
- **GCI75** — String concatenation in loops (C#)
- **GCI79/GCI88** — Unclosed resources
- **GCI82** — Variables that should be final/const/readonly
- **GCI84** — async void (C#)
- **GCI85** — Unsealed types (C#)
- **GCI94** — orElse() with expensive computation (Java)
- **GCI105** — String += in loops (Python)
- **GCI111** — f-string in logging (Python)

## Output format:

For each rule:
- ✅ if satisfied
- ❌ if violated — with file, line, and fix

Estimate:
- **Green API Score**: X/123 (Grade A-E)
- **Creedengo Score**: X/100 (Grade A-E)
- **Top 3 quick wins** to gain the most points
