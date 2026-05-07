---
name: add-health-endpoint
description: Add health/readiness endpoint (LO01 - 5 pts)
---
Add observability endpoints to the API.
## Java (Spring Boot):
Add dependency `spring-boot-starter-actuator`. Expose in application.yml:
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics
  endpoint:
    health:
      show-details: when-authorized
```
## C# (.NET):
```csharp
builder.Services.AddHealthChecks()
    .AddDbContextCheck<AppDbContext>();
app.MapHealthChecks("/health");
```
## Expected response:
```json
{ "status": "UP", "components": { "db": { "status": "UP" } } }
```
Endpoints: `/health`, `/health/ready`, `/health/live`
