---
name: add-compression
description: Configure gzip/brotli compression middleware (DE01 - 15 pts)
---
Enable response compression for the API.
## Java (Spring Boot):
Add to application.yml:
```yaml
server:
  compression:
    enabled: true
    mime-types: application/json,application/xml,text/plain
    min-response-size: 1024
```
## C# (.NET):
In Program.cs:
```csharp
builder.Services.AddResponseCompression(opts => {
    opts.EnableForHttps = true;
    opts.Providers.Add<GzipCompressionProvider>();
    opts.Providers.Add<BrotliCompressionProvider>();
});
app.UseResponseCompression();
```
## Verification:
Request with `Accept-Encoding: gzip` must return `Content-Encoding: gzip`.
