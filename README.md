# apigreenscoreanalyzer

Green Score + Creedengo eco-design analyzer for REST APIs.

## Stacks supportés

| Stack          | Build / Run                              | Creedengo (code)               |
|----------------|------------------------------------------|--------------------------------|
| **Java Maven** | `mvn spring-boot:run` ou `java -jar`     | plugin SonarQube `creedengo-java` (D1) |
| **Java Gradle**| `./gradlew bootRun`                      | plugin SonarQube `creedengo-java` (D1) |
| **.NET 8+ (C#)** | `dotnet run --urls http://+:<port>`    | plugin SQ `creedengo-csharp` (D1) si publié, sinon scan stock SQ via `dotnet-sonarscanner` (D2) |

> ⚠️ F#/VB.NET sont détectés mais Creedengo ne les couvre pas (warning explicite).

## Prérequis

- **Java** : JDK 17+, Maven 3.8+
- **.NET** : .NET SDK **8.0** (LTS) — `dotnet --version` doit retourner ≥ 8.x
- **Container runtime** : Docker ou Podman (pour SonarQube)
- Python 3.9+, curl

Le tool global `dotnet-sonarscanner` est installé automatiquement à la volée
au premier scan C#. Pour l'installer manuellement :

```sh
dotnet tool install --global dotnet-sonarscanner
```

## Usage CLI — `scripts/start.sh`

```sh
# Java Maven (utilisateur démarre l'app à part)
bash scripts/start.sh --target http://localhost:8080 --creedengo \
                      --source-dir ./my-spring-app

# Java + build & run automatique
bash scripts/start.sh --stack java --build-and-run \
                      --source-dir ./my-spring-app --creedengo

# .NET (build & run + Creedengo)
bash scripts/start.sh --stack dotnet --build-and-run \
                      --source-dir ./MyAspNetApi --creedengo \
                      --target http://localhost:5050
```

### Flags clés

| Flag                | Effet                                                       |
|---------------------|-------------------------------------------------------------|
| `--stack <auto\|java\|dotnet>` | Force le stack ; `auto` détecte depuis `--source-dir`. |
| `--source-dir <path>` | Dossier du code source local (alternatif à `--git-repo`). |
| `--build-and-run`   | Compile + démarre l'app avant les health-checks. Exige `--source-dir`. |
| `--target <url>`    | URL d'API à analyser (Green Score). Répétable.              |
| `--creedengo`       | Active l'analyse Creedengo (code source).                   |
| `--git-repo <url>`  | Clone un dépôt Git et l'analyse via Creedengo.              |
| `--bearer <token>`  | Bearer token pour endpoints protégés.                        |
| `--debug`           | Mode verbeux.                                                |

## UI interactive

```sh
bash scripts/start-interactive.sh    # http://127.0.0.1:8765
```

Onglet **« Local Green Score / Creedengo Source analyse »** :

- Sélecteur **Stack** (Auto / Java / .NET)
- Champ **Dossier source local**
- Checkbox **Build & run** (compile + démarre l'app, kill au cleanup)
- Console live des logs `start.sh`

## Architecture C# / .NET (SonarQube)

1. **D1 (préféré)** : si un JAR `creedengo-csharp-plugin-*.jar` est publié sur
   GitHub Releases, il est téléchargé automatiquement et chargé dans SonarQube
   → règles éco-design appliquées via `dotnet-sonarscanner`.
2. **D2 (fallback)** : si le JAR n'existe pas, le scan tourne quand même via
   `dotnet sonarscanner begin/end` → analyse stock SonarQube (issues C#
   classiques) sans les règles Creedengo, avec un warning explicite.

Le scan utilise toujours `dotnet build -c Debug` pour garantir la disponibilité
des PDB (requis par les analyzers Roslyn).

## Limitations connues

- HTTPS dev cert ASP.NET non installé → on force `ASPNETCORE_URLS=http://+:<port>`
  pour éviter le prompt `dotnet dev-certs`.
- Premier `dotnet restore` (cache NuGet vide) peut être lent : timeout bridge
  configuré à 10 minutes.
- Mono-repos Java + .NET : utiliser `--stack` explicite pour lever l'ambiguïté.

