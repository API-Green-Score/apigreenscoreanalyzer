# 🌿 Green Analyzer — Distribution Artifacts
This folder contains **three ready-to-ship artifacts** produced by the build
scripts at the repo root. Implementation details (Python helpers, Spectral
rules, dashboard templates…) are bundled inside each artifact — end users
only see a clean CLI / IDE plugin.
| Artifact                              | Size     | What it does                                                       | Built by                                    |
|---------------------------------------|----------|--------------------------------------------------------------------|---------------------------------------------|
| `greenanalyzer`                       | ~360 KB  | Full Green Score: live API probing, badge, dashboard, Creedengo.   | `bash scripts/build-binary.sh`              |
| `green-api-lint`                      | ~9 KB    | Lightweight offline OpenAPI linter (no HTTP, no dashboard).        | `bash scripts/build-lint-binary.sh`         |
| `../intellij-plugin/build/…/*.zip`    | ~25 KB   | JetBrains plugin that wraps either of the above.                   | `bash intellij-plugin/build.sh buildPlugin` |
All three are self-contained: no `pip install`, no extra config — just bash
+ Python 3 and, optionally, Docker for the deep `analyze` mode.
---
## 1. `greenanalyzer` — full single-binary CLI
```bash
./greenanalyzer --help                                  # show all options
./greenanalyzer --target http://localhost:8080          # analyze a live./greenanalyzer --target http://localhost:8080          # analyze a live./greenanalyzer --target http://localhost:8080          # analyze a live./greenanalyzer Outputs land in `$PWD/greenanalyzer-output/` by default (override with
`--output-dir`). The binary self-extracts to `$TMPDIR` at runtime and cleans
up on exit; nothing is written to its install location.
---
## 2. `green-api-lint` — local OpenAPI linter
The same rule engine as `greenanalyzer lint` but stripped to its
essentials. Perfect foressentials. Perfect foressentials. Perfect foressentials. Perfect foressentials. Perfect foressentials. Perfect foressentials. Perfect foressentials. Perfect foressentnt ./openapi.yaml --format json    # JSON for tooling
./green-api-lint ./openapi../green-api-lint ./openapi../green-api-lint ./open./green-api-lint ./openapi.yaml --fail-on-warn   # exit 1 if anything is fo./green-api-lint ./openapi.findings (or no `--fail-on-warn`), `1` findings with
`--fail-on-warn`, `2` bad input.
---
## 3. IntelliJ Plugin
Build once:
```bash
bash ../intellij-plugin/build.sh buildPlugin
```
Then, in any JetBrains IDE (2024.1+):
1. Settings → Plugins → ⚙ → **Install Plugin from Disk…**
2. Pick `intellij-plugin/build/distributions/green-api-intellij-plugin-*.zip`
3. Settings → Tools → **API Green Score**: point *Linter binary path* at
   either `./greenanalyzer` *or* `./green-api-lint` (`$PATH` works too).
4. Right-click any OpenAPI / Swagger file → **Analyze with API Green Score**
   (or just save the file — lint-on-save is enabled by default).
Findings appear in the **API Green Score** tool window grouped by severity
and rule, with remediation hints. The plugin shells out to whichever local
linter you configured and parses ilinter you configured and parses ilinter you configured and parses ilinter you configuding from source
```bash
cd ..
bash scripts/build-binary.sh        # → dist/greenanalyzer
bash scripts/build-lint-binary.sh   # → dist/green-api-lint
bash intellij-plugin/build.sh       # → intellij-plugin/build/distributions/*.zip
```
The IntelliJ build script auto-bootstraps Gradle 8.10 into
`~/.cache/greenanalyzer-gradle/` on first run; the only prerequisite is a
JDK 17+ on `$PATH`.
