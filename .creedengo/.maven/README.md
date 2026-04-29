# Offline Maven backup

Drop an Apache Maven binary archive in this directory to make the analyzer
install Maven without internet access.

The `--build-and-run java` flow in `scripts/start.sh` looks for files matching:

- `apache-maven-*-bin.tar.gz` (preferred, used on macOS / Linux)
- `apache-maven-*-bin.zip` (Windows, or as alternative)

## How to grab the archive

From any machine with internet access:

```sh
# Latest 3.9.x (recommended, requires JDK 8+)
curl -fsSLO https://dlcdn.apache.org/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz

# Or the older 3.8.8 (also requires JDK 8+, longer mirror retention)
curl -fsSLO https://archive.apache.org/dist/maven/maven-3/3.8.8/binaries/apache-maven-3.8.8-bin.tar.gz
```

Then copy the `.tar.gz` into this directory:

```sh
cp apache-maven-3.9.9-bin.tar.gz path/to/repo/.creedengo/.maven/
```

## Resolution order (start.sh `--build-and-run java`)

1. `./mvnw` (Maven Wrapper — preferred, pins the project's exact version).
2. `mvn` already on `PATH`.
3. `$HOME/.maven/apache-maven-*/bin/mvn` (cache from a previous run).
4. **This directory** — extracted to `$HOME/.maven/`.
5. Online download from `https://dlcdn.apache.org/maven/` (with fallback to
   `https://archive.apache.org/dist/maven/` for older versions).

If none of these resolve, the script aborts with a clear error message.

## Override the resolved version

You can pin a specific version via env var:

```sh
MAVEN_VERSION=3.9.6 ./scripts/start.sh --build-and-run java …
```

Or change the install root (defaults to `$HOME/.maven`):

```sh
MAVEN_LOCAL_ROOT=/opt/maven ./scripts/start.sh --build-and-run java …
```

## JDK requirement

Maven needs a **JDK** (not just a JRE) to compile your project. If `javac` is
not on `PATH` and `JAVA_HOME` is unset, the script prints a hint pointing at:

- macOS: `brew install --cask temurin`
- Debian/Ubuntu: `apt-get install default-jdk`
- Manual: <https://adoptium.net/>

It is **not** an automatic install (JDKs are heavier, often distro-specific,
and frequently already cached by IDEs / SDK managers).

