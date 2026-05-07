Generate a **fully Green API compliant** REST endpoint for the given resource.

The endpoint MUST include ALL of the following patterns:

## Required patterns (score them inline with comments):

1. **DE11 — Pagination**: Accept `page` and `size` query params. Return `X-Total-Count` header.
2. **DE08 — Field filtering**: Accept `fields` query param. Only serialize requested fields.
3. **DE01 — Compression**: Ensure gzip middleware is active (show config if needed).
4. **DE02/DE03 — ETag + 304**: Generate ETag from response hash. Check `If-None-Match`, return 304 if match.
5. **DE06 — Delta**: Add a `GET /resource/changes?since=<ISO8601>` companion endpoint.
6. **206 — Range**: For list endpoints with large payloads, support `Range` header.
7. **LO01 — Health**: Ensure health endpoint exists.
8. **US07 — Rate limit**: Include rate-limit headers in response.

## Code quality (Creedengo GCI compliant):

### Java — avoid these violations:
- **GCI1**: No Spring repository calls inside loops/streams — batch
- **GCI72**: No SQL queries inside loops — use IN clause or batch
- **GCI74**: No `SELECT *` — specify columns
- **GCI77**: Pattern.compile must be `private static final`
- **GCI79**: Always use try-with-resources for AutoCloseable
- **GCI82**: Make variables `final` when never reassigned
- **GCI94**: Use `orElseGet()` not `orElse()` for expensive computations

### C# — avoid these violations:
- **GCI72**: No LINQ/EF queries inside loops
- **GCI75**: No string concatenation in loops — use StringBuilder
- **GCI84**: No `async void` — use `async Task`
- **GCI85**: Seal classes that don't need inheritance
- **GCI87**: Use indexer `[0]` not `.First()` when collection supports it
- **GCI88**: Use `await using` for IAsyncDisposable
- **GCI91**: Filter before sorting
- **GCI93**: Return Task directly when only one await

### Python — avoid these violations:
- **GCI72**: No SQL in loops — use executemany
- **GCI74**: No SELECT * — specify columns
- **GCI105**: No string += in loops — use join()
- **GCI109**: No exceptions for control flow — use dict.get()
- **GCI111**: Use %s in logging, not f-strings
- **GCI112**: Add slots=True to dataclasses
- **GCI404**: Use generator expressions in iterations, not list comprehensions

## Output:
- Controller/handler code
- Service/repository code
- Any configuration needed (middleware, filters)
- OpenAPI spec snippet (YAML)

Mark each green pattern with an inline comment: `// DE11: pagination` or `// GCI82: final`
