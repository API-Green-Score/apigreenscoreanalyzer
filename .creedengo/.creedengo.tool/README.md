# Creedengo.Tool — offline backup

Drop a pre-downloaded NuGet package here so `creedengo-analyzer.sh` can install
the .NET tool **without internet access** (CI behind a proxy, offline workshops,
or when nuget.org is throttling).

## Expected layout

```
.creedengo/.creedengo.tool/
  Creedengo.Tool.<version>.nupkg     ← offline NuGet package (preferred)
```

The script will run:
```bash
dotnet tool install --global \
  --add-source .creedengo/.creedengo.tool Creedengo.Tool
```

If multiple `.nupkg` files are present, the **highest version** (sorted with
`sort -V`) is picked.

## Alternative: pre-extracted binary

If you cannot ship a `.nupkg` (e.g. air-gapped environment), a pre-built
binary is also accepted:

```
.creedengo/.creedengo.tool/
  creedengo-cli         (Linux / macOS, must be executable)
  creedengo-cli.exe     (Windows)
```

The script chmods +x and prepends the directory to `PATH`.

## How to grab the .nupkg manually

```bash
# From a machine with internet access:
nuget install Creedengo.Tool -OutputDirectory ./tmp
cp ./tmp/Creedengo.Tool.*/*.nupkg .creedengo/.creedengo.tool/
```

Or simply download from <https://www.nuget.org/packages/Creedengo.Tool> →
"Download package" → place the file here.

## Fallback order in the analyzer

1. `dotnet tool install --global Creedengo.Tool` (online from nuget.org)
2. `dotnet tool install --global --add-source <this dir> Creedengo.Tool`
3. Use the pre-built `creedengo-cli` binary if dropped here
4. Hard error with actionable instructions

