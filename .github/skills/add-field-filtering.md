---
name: add-field-filtering
description: Add field filtering support to reduce payload size (DE08 - 15 pts)
---
Add `fields` query parameter to the given endpoint to allow clients to request only needed fields.
## Java (Spring Boot):
Use `MappingJacksonValue` + `@JsonFilter("fieldFilter")` on DTOs with `SimpleBeanPropertyFilter.filterOutAllExcept(fields.split(","))`.
## C# (.NET):
Use reflection to project only requested properties into a Dictionary.
## OpenAPI:
```yaml
parameters:
  - name: fields
    in: query
    description: Comma-separated list of fields to include
    schema: { type: string }
    example: "id,name,price"
```
Apply this to the provided endpoint. Return only the requested fields in the response body.
