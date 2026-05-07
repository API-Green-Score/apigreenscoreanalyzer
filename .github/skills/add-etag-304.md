---
name: add-etag-304
description: Add ETag generation and 304 Not Modified support (DE02/DE03 — 15 pts)
---

Add ETag + conditional GET (304) to the given single-resource endpoint.

## Implementation:

### Java (Spring Boot):
```java
@GetMapping("/{id}")
public ResponseEntity<T> getById(@PathVariable Long id, 
                                  @RequestHeader(value = "If-None-Match", required = false) String ifNoneMatch) {
    T entity = service.findById(id);
    String etag = "\"" + Integer.toHexString(entity.hashCode()) + "\"";
    
    if (etag.equals(ifNoneMatch)) {
        return ResponseEntity.status(HttpStatus.NOT_MODIFIED).eTag(etag).build();
    }
    return ResponseEntity.ok().eTag(etag).body(entity);
}
```

### C# (.NET):
```csharp
[HttpGet("{id}")]
public async Task<IActionResult> GetById(int id, [FromHeader(Name = "If-None-Match")] string? ifNoneMatch)
{
    var entity = await _repository.GetByIdAsync(id);
    if (entity == null) return NotFound();
    
    var etag = $"\"{entity.GetHashCode():x}\"";
    
    if (etag == ifNoneMatch)
    {
        Response.Headers.ETag = etag;
        return StatusCode(304);
    }
    
    Response.Headers.ETag = etag;
    return Ok(entity);
}
```

### Alternative — Use middleware/filter (recommended):
- Spring: `ShallowEtagHeaderFilter`
- ASP.NET: Custom middleware hashing response body

Apply this pattern to the provided endpoint. Use `version` or `lastModified` field for ETag if available.

