---
name: add-delta-endpoint
description: Add a /changes?since= delta sync endpoint (DE06 - 10 pts)
---
Add an incremental sync endpoint that returns only resources modified after a given timestamp.
## Java (Spring Boot):
```java
@GetMapping("/changes")
public ResponseEntity<List<T>> getChanges(
    @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant since) {
    List<T> changes = repository.findByLastModifiedAfter(since);
    return ResponseEntity.ok(changes);
}
```
## C# (.NET):
```csharp
[HttpGet("changes")]
public async Task<IActionResult> GetChanges([FromQuery] DateTime since)
{
    var changes = await _repository.GetModifiedSinceAsync(since);
    return Ok(changes);
}
```
## Repository query:
```sql
SELECT id, name, updated_at FROM items WHERE updated_at > :since ORDER BY updated_at ASC
```
Requires a `last_modified` / `updated_at` column with an index.
