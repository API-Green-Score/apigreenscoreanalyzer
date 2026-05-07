---
name: add-pagination
description: Add pagination support to a collection endpoint (DE11 — 15 pts)
---

Add pagination to the given collection endpoint.

## What to add:

### Controller/Handler:
- `page` query parameter (int, default: 0 or 1)
- `size` query parameter (int, default: 20, max: 100)
- Return `X-Total-Count` response header
- Return `X-Total-Pages` response header
- Return paginated subset of data

### Java (Spring Boot):
```java
@GetMapping
public ResponseEntity<List<T>> getAll(
    @RequestParam(defaultValue = "0") int page,
    @RequestParam(defaultValue = "20") int size) {
    Page<T> result = repository.findAll(PageRequest.of(page, size));
    return ResponseEntity.ok()
        .header("X-Total-Count", String.valueOf(result.getTotalElements()))
        .body(result.getContent());
}
```

### C# (.NET):
```csharp
[HttpGet]
public async Task<IActionResult> GetAll(
    [FromQuery] int page = 1,
    [FromQuery] int size = 20)
{
    var total = await _repository.CountAsync();
    var items = await _repository.GetPagedAsync(page, size);
    Response.Headers["X-Total-Count"] = total.ToString();
    return Ok(items);
}
```

### OpenAPI snippet:
```yaml
parameters:
  - name: page
    in: query
    schema: { type: integer, default: 1, minimum: 1 }
  - name: size
    in: query
    schema: { type: integer, default: 20, minimum: 1, maximum: 100 }
```

Apply this pattern to the provided endpoint.

