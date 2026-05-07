---
name: add-rate-limiting
description: Add rate limiting with 429 Too Many Requests (US07 - 5 pts)
---
Add rate limiting to the API.
## Java (Spring Boot with Bucket4j):
```java
@Bean
public FilterRegistrationBean<RateLimitFilter> rateLimitFilter() {
    // 100 requests per minute per IP
}
// Return 429 with Retry-After header
```
## C# (.NET 7+):
```csharp
builder.Services.AddRateLimiter(opts => {
    opts.AddFixedWindowLimiter("fixed", o => {
        o.PermitLimit = 100;
        o.Window = TimeSpan.FromMinutes(1);
        o.QueueLimit = 0;
    });
    opts.RejectionStatusCode = 429;
});
app.UseRateLimiter();
```
## Response headers to include:
- `X-RateLimit-Limit: 100`
- `X-RateLimit-Remaining: 42`
- `Retry-After: 30` (on 429)
