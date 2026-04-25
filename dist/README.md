# 🌿 Green Analyzer — API Eco-Design Scoring

**Green Analyzer** measures the eco-design quality of any REST API and produces a **Green Score out of 100**.

It works with **any technology stack** (Spring Boot, .NET, Express, Flask, Django…) — the only requirement is a reachable API with an OpenAPI/Swagger endpoint.

---

## 📦 Installation

### Prerequisites
- **Docker** (or Podman) installed and running

### Setup

```bash
# 1. Build the image (one time only)
make build

# 2. Verify installation
./greenanalyzer --help
```

---

## 🚀 Usage

```bash
# Analyze an API (auto-discovers OpenAPI spec)
./greenanalyzer --target http://your-api:8080

# Provide the swagger URL explicitly
./greenanalyzer --target http://your-api:8080 --swagger http://your-api:8080/v3/api-docs

# With authentication + more measurement passes
./greenanalyzer --target http://your-api:8080 --bearer "your-token" --repeat 5

# Dry-run: lint a spec file without calling the API
./greenanalyzer --swagger ./my-spec.yaml --dry-run
```

### Options

| Option | Description |
|--------|-------------|
| `--target URL` | Base URL of the API to analyze (required unless `--dry-run`) |
| `--swagger URL\|FILE` | Explicit OpenAPI/Swagger spec URL or local file path |
| `--bearer TOKEN` | Bearer token for authenticated APIs |
| `--repeat N` | Number of measurement repetitions per endpoint (default: 3) |
| `--dry-run` | Lint spec only, no HTTP calls to the API |
| `--help` | Show help message |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GREEN_OUTPUT_DIR` | `./greenanalyzer-output` | Where reports, dashboard, and badges are written |

---

## 📊 Output

After analysis, results are available in `./greenanalyzer-output/`:

```
greenanalyzer-output/
├── reports/
│   ├── latest-report.json              # Latest analysis results (JSON)
│   └── green-score-report-*.json       # Timestamped reports
├── dashboard/
│   └── index.html                      # Open in browser for visual dashboard
└── badges/
    └── green-score.svg                 # Score badge for your README
```

### Dashboard
Open `greenanalyzer-output/dashboard/index.html` in any browser to see:
- Overall Green Score gauge
- Per-rule breakdown with scores
- Per-endpoint detailed measurements
- Historical score evolution

### Badge
Embed the generated badge in your README:
```markdown
![Green Score](greenanalyzer-output/badges/green-score.svg)
```

---

## 📏 Scoring Rules (100 points total)

| Rule | Description | Points | What is measured |
|------|-------------|--------|------------------|
| **DE11** | Pagination | 15 | Collection endpoints support `?page=&size=` |
| **DE08** | Field filtering | 15 | `?fields=id,title` reduces payload |
| **DE01** | Compression | 15 | `Accept-Encoding: gzip` reduces wire size |
| **DE02/03** | Cache (ETag) | 15 | ETag present → conditional GET returns 304 |
| **DE06** | Delta | 10 | `/changes?since=` returns only recent changes |
| — | Range (206) | 10 | `Range` header returns 206 Partial Content |
| **LO01** | Observability | 5 | Logging filter logs bytes + ms per request |
| **US07** | Rate Limit | 5 | Rate limiting returns 429 on excess |
| **AR02** | CBOR | 10 | Binary CBOR endpoint vs JSON reduces payload |

---

## 🔄 CI/CD Integration

### Threshold Gate

Edit `green-score-threshold.json` to set your minimum acceptable score:
```json
{"minScore": 50}
```

The analyzer exits with code 1 if the score is below the threshold.

### GitHub Actions Example

```yaml
- name: Run Green Analyzer
  run: ./greenanalyzer --target http://localhost:8080 --repeat 3

- name: Check threshold
  run: |
    score=$(jq '.greenScore' greenanalyzer-output/reports/latest-report.json)
    threshold=$(jq '.minScore' green-score-threshold.json)
    if [ "$score" -lt "$threshold" ]; then
      echo "❌ Green Score $score is below threshold $threshold"
      exit 1
    fi
```

---

## 🔍 OpenAPI Auto-Discovery

The analyzer automatically tries these paths:

```
/api/v3/api-docs     /v3/api-docs         /v3/api-docs.yaml
/v2/api-docs         /openapi.json        /openapi.yaml
/swagger/v1/swagger.json  /swagger.json   /swagger.yaml
```

Or pass `--swagger` to skip discovery.

---

## ❓ Troubleshooting

| Problem | Solution |
|---------|----------|
| `Docker not found` | Install Docker Desktop or Podman |
| Can't reach `localhost` API | The container uses `--network=host` which works on Linux. On macOS, use `host.docker.internal` instead of `localhost` |
| No OpenAPI spec found | Pass `--swagger URL` explicitly |
| Permission denied | Run `chmod +x greenanalyzer` |

