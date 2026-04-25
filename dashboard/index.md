# 🌿 Green API Score Dashboard

> 📦 **Application : greenscoreoptimized**
>
> **Devoxx France 2026 — Green Architecture : moins de gras, plus d'impact !**

📅 *Dernière analyse : 2026-04-16T13:20:16Z*

---

## 🔴 Green Score : **9/100** — Grade **E** 📉

### 📋 Détail par règle

| Statut | Règle | Score | Max | Endpoints | Détail |
|:------:|-------|------:|----:|:---------:|--------|
| ⚠️ | DE11 Pagination | 5 | 15 | 4/11 | Pagination on 4/11 collection endpoint(s) |
| ⚠️ | DE08 Filtrage champs | 2 | 15 | 2/17 | Field filtering on 2 endpoint(s) |
| ❌ | DE01 Compression | 0 | 15 | 0/20 | Gzip not detected |
| ❌ | DE02/03 Cache ETag | 0 | 15 | 0/6 | ETag/304 not detected |
| ⚠️ | DE06 Delta | 1 | 10 | 2/17 | Delta endpoint(s) found: 2 |
| ❌ | 206 Range | 0 | 10 | 0/17 | Range not supported |
| ❌ | LO01 Observabilité | 0 | 5 | 0/5 | No health endpoint |
| ❌ | US07 Rate Limit | 0 | 5 | 0/20 | Assumed present (API running, no explicit headers) |
| ⚠️ | AR02 CBOR | 1 | 10 | 2/20 | Binary format on 2 endpoint(s) |

### 📊 Mesures par endpoint (API découverte)

| Méthode | Endpoint | Taille | Temps | HTTP |
|:-------:|----------|-------:|------:|-----:|
| GET | `/books/{id}` | 187 B | 0.042s | 200 |
| PUT | `/books/{id}` | 319 B | 0.012s | 400 |
| GET | `/reactive/books/{id}/summary` | 0 B | 0.078s | 200 |
| POST | `/reactive/books/{id}/summary` | 392 B | 0.012s | 400 |
| GET | `/books/{id}/summary` | 34 B | 0.016s | 200 |
| POST | `/books/{id}/summary` | 346 B | 0.012s | 400 |
| GET | `/reactive/books` | 0 B | 0.053s | 200 |
| GET | `/reactive/books/{id}` | 0 B | 0.023s | 200 |
| GET | `/reactive/books/select` | 0 B | 0.028s | 200 |
| GET | `/reactive/books/changes` | 210 B | 0.016s | 400 |
| GET | `/reactive/books/cbor` | 13 B | 0.017s | 429 |
| GET | `/reactive/books/cacheable` | 20 B | 0.006s | 429 |
| GET | `/books` | 20 B | 0.009s | 429 |
| GET | `/books/select` | 20 B | 0.009s | 429 |
| GET | `/books/noCache/{id}` | 20 B | 0.009s | 429 |
| GET | `/books/changes` | 20 B | 0.008s | 429 |
| GET | `/books/cbor` | 20 B | 0.008s | 429 |
| GET | `/books/batch` | 20 B | 0.009s | 429 |
| GET | `/books/async` | 20 B | 0.008s | 429 |
| GET | `/books/async/{id}` | 20 B | 0.008s | 429 |

### 🔑 Métriques clés

- **Endpoints mesurés** : 20
- **Transfert total** : 1.7 KB
- **Transfert moyen / endpoint** : 84 B
- **Temps moyen** : 0.019s
- **⚡ Énergie totale / appel** : 0.0028 Wh
- **🌍 CO₂ / appel** : 0.00015 g (France — 53 gCO₂/kWh)

### 💡 Suggestions d'amélioration

> **Score actuel : 9/100** — Score potentiel avec toutes les suggestions : **100/100** (+91 pts possibles)

🔴 Haute priorité : 13 | 🟡 Moyenne : 8 | ⚪ Basse : 4 | **Total : 25 suggestions**

#### 🗜️ DE01 — Compression Gzip (❌ Non validé — +15 pts possibles)

> Le serveur doit supporter Accept-Encoding: gzip. (0/20 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🔴 Haute | `ALL endpoints (server-level)` | Enable gzip compression on the server | +0.8 pts/endpoint (total gap: 15 pts) — typically 60-80% payload reduction |

<details><summary>🔧 Comment implémenter</summary>

```
Option 1 — Spring Boot application.yml:
  server:
    compression:
      enabled: true
      min-response-size: 1024
      mime-types: application/json,application/xml,text/html,text/plain

Option 2 — Nginx (if reverse proxy):
  gzip on;
  gzip_types application/json application/xml text/plain;
  gzip_min_length 1024;
  gzip_comp_level 6;

Both options apply to ALL endpoints automatically.
```
</details>

#### 💾 DE02/03 — Cache ETag/304 (❌ Non validé — +15 pts possibles)

> Les ressources unitaires doivent supporter ETag + If-None-Match -> 304. (0/6 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🔴 Haute | `GET /books/{id}` | Add ETag support and If-None-Match → 304 Not Modified | +2.5 pts/endpoint (total gap: 15 pts) — avoids resending unchanged resources, saves bandwidth |
| 🔴 Haute | `GET /reactive/books/{id}/summary` | Add ETag support and If-None-Match → 304 Not Modified | +2.5 pts/endpoint (total gap: 15 pts) — avoids resending unchanged resources, saves bandwidth |
| 🔴 Haute | `GET /books/{id}/summary` | Add ETag support and If-None-Match → 304 Not Modified | +2.5 pts/endpoint (total gap: 15 pts) — avoids resending unchanged resources, saves bandwidth |
| 🔴 Haute | `GET /reactive/books/{id}` | Add ETag support and If-None-Match → 304 Not Modified | +2.5 pts/endpoint (total gap: 15 pts) — avoids resending unchanged resources, saves bandwidth |
| 🔴 Haute | `GET /books/noCache/{id}` | Add ETag support and If-None-Match → 304 Not Modified | +2.5 pts/endpoint (total gap: 15 pts) — avoids resending unchanged resources, saves bandwidth |

<details><summary>🔧 Comment implémenter</summary>

```
Spring Boot: Use ShallowEtagHeaderFilter (zero-code) or manual ETags:

  Option A — Global filter (easiest):
  @Bean
  public FilterRegistrationBean<ShallowEtagHeaderFilter> etagFilter() {
    FilterRegistrationBean<ShallowEtagHeaderFilter> reg = new FilterRegistrationBean<>();
    reg.setFilter(new ShallowEtagHeaderFilter());
    reg.addUrlPatterns("/api/*");
    return reg;
  }

  Option B — Manual per endpoint:
  String etag = '"' + DigestUtils.md5DigestAsHex(body.getBytes()) + '"';
  if (request.checkNotModified(etag)) return null; // → 304
  return ResponseEntity.ok().eTag(etag).body(body);
```
</details>

#### ✂️ 206 — Range / Partial Content (❌ Non validé — +10 pts possibles)

> Supporter le header Range pour les gros payloads. (0/17 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| ⚪ Basse | `GET /books/{id}` | Support HTTP Range header for partial content (206) | +10 pts — enables resumable downloads and partial fetches |
| ⚪ Basse | `GET /reactive/books/{id}/summary` | Support HTTP Range header for partial content (206) | +10 pts — enables resumable downloads and partial fetches |

<details><summary>🔧 Comment implémenter</summary>

```
For JSON endpoints, Range/206 is rarely useful.
Focus on the file download endpoint(s) instead.
```
</details>

#### 👁️ LO01 — Observabilité (❌ Non validé — +5 pts possibles)

> Actuator / health / metrics doit etre expose. (0/5 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🔴 Haute | `/actuator/health, /actuator/metrics` | Expose Spring Boot Actuator endpoints | +5 pts — essential for production monitoring |

<details><summary>🔧 Comment implémenter</summary>

```
Spring Boot application.yml:
  management:
    endpoints:
      web:
        exposure:
          include: health,info,metrics
    endpoint:
      health:
        show-details: when-authorized

Add dependency: spring-boot-starter-actuator (likely already present).
```
</details>

#### 🚦 US07 — Rate Limiting (❌ Non validé — +5 pts possibles)

> Un mecanisme de rate limiting doit etre present. (0/20 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🟡 Moyenne | `ALL endpoints (server-level)` | Add rate-limit response headers | +5 pts — protects the API from abuse and signals limits to clients |

<details><summary>🔧 Comment implémenter</summary>

```
Option 1 — Spring Boot filter:
  Add a HandlerInterceptor or OncePerRequestFilter that adds:
    X-RateLimit-Limit: 100
    X-RateLimit-Remaining: 97
    X-RateLimit-Reset: 1620000000

Option 2 — Use Bucket4j + Spring Boot Starter:
  <dependency>com.bucket4j:bucket4j-spring-boot-starter</dependency>
  Configure rate limits in application.yml per endpoint.

Option 3 — Nginx:
  limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
  location /api/ { limit_req zone=api burst=20; }
  add_header X-RateLimit-Limit 100;
```
</details>

#### 🔍 DE08 — Filtrage de champs (⚠️ Partiel (2/17) — +13 pts possibles)

> Supporter un parametre 'fields' pour reduire le payload. (2/17 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🟡 Moyenne | `GET /books/{id}` | Add a 'fields' query parameter for sparse fieldsets | +0.9 pts/endpoint (total gap: 13 pts) — lets clients request only needed fields, reducing payload |
| 🟡 Moyenne | `GET /reactive/books/{id}/summary` | Add a 'fields' query parameter for sparse fieldsets | +0.9 pts/endpoint (total gap: 13 pts) — lets clients request only needed fields, reducing payload |
| 🟡 Moyenne | `GET /books/{id}/summary` | Add a 'fields' query parameter for sparse fieldsets | +0.9 pts/endpoint (total gap: 13 pts) — lets clients request only needed fields, reducing payload |
| 🔴 Haute | `GET /reactive/books` | Add a 'fields' query parameter for sparse fieldsets | +0.9 pts/endpoint (total gap: 13 pts) — lets clients request only needed fields, reducing payload |
| 🟡 Moyenne | `GET /reactive/books/{id}` | Add a 'fields' query parameter for sparse fieldsets | +0.9 pts/endpoint (total gap: 13 pts) — lets clients request only needed fields, reducing payload |

<details><summary>🔧 Comment implémenter</summary>

```
Spring Boot: Add an optional @RequestParam and filter the DTO:
  @GetMapping
  public ApiResponse<?> list(
      @RequestParam(required = false) String fields) {
    // If fields != null, use Jackson @JsonFilter or a projection
    // to return only the requested fields.
  }
Alternative: Use a custom Jackson MappingJacksonValue with a
SimpleFilterProvider that keeps only the requested properties.
OpenAPI: The 'fields' param will appear automatically.
```
</details>

#### 📄 DE11 — Pagination (⚠️ Partiel (4/11) — +10 pts possibles)

> Les endpoints de collection doivent supporter la pagination (page/size ou limit/offset). (4/11 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🔴 Haute | `GET /reactive/books/changes` | Add pagination parameters (page & size) | +1.4 pts/endpoint (total gap: 10 pts) — reduces payload size for large collections |
| 🔴 Haute | `GET /reactive/books/cbor` | Add pagination parameters (page & size) | +1.4 pts/endpoint (total gap: 10 pts) — reduces payload size for large collections |
| 🔴 Haute | `GET /reactive/books/cacheable` | Add pagination parameters (page & size) | +1.4 pts/endpoint (total gap: 10 pts) — reduces payload size for large collections |
| 🔴 Haute | `GET /books/changes` | Add pagination parameters (page & size) | +1.4 pts/endpoint (total gap: 10 pts) — reduces payload size for large collections |
| 🔴 Haute | `GET /books/cbor` | Add pagination parameters (page & size) | +1.4 pts/endpoint (total gap: 10 pts) — reduces payload size for large collections |

<details><summary>🔧 Comment implémenter</summary>

```
Spring Boot: Change return type from List<T> to Page<T> and add @RequestParam defaultValue parameters:
  @GetMapping
  public ApiResponse<Page<T>> list(
      @RequestParam(defaultValue = "0") int page,
      @RequestParam(defaultValue = "20") int size) {
    return ApiResponse.success(repository.findAll(PageRequest.of(page, size)));
  }
OpenAPI: params 'page' and 'size' will appear automatically via springdoc.
```
</details>

#### 🔄 DE06 — Delta / Changes (⚠️ Partiel (2/17) — +9 pts possibles)

> Un endpoint /changes?since= ou equivalent doit exister. (2/17 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🟡 Moyenne | `GET /reactive/books/changes  (new endpoint)` | Add a delta/changes endpoint with a 'since' parameter | +0.6 pts/endpoint (total gap: 9 pts) — clients fetch only what changed since last sync |
| 🟡 Moyenne | `GET /reactive/books/select/changes  (new endpoint)` | Add a delta/changes endpoint with a 'since' parameter | +0.6 pts/endpoint (total gap: 9 pts) — clients fetch only what changed since last sync |
| 🟡 Moyenne | `GET /reactive/books/changes/changes  (new endpoint)` | Add a delta/changes endpoint with a 'since' parameter | +0.6 pts/endpoint (total gap: 9 pts) — clients fetch only what changed since last sync |

<details><summary>🔧 Comment implémenter</summary>

```
Spring Boot: Add a new endpoint that filters by updatedAt:
  @GetMapping("/changes")
  public ApiResponse<List<T>> getChanges(
      @RequestParam @DateTimeFormat(iso = ISO.DATE_TIME) LocalDateTime since) {
    return ApiResponse.success(
        repository.findByUpdatedAtAfter(since));
  }

Prerequisite: Add an 'updatedAt' column with @UpdateTimestamp
to your entity, and a repository method findByUpdatedAtAfter().
Alternative: Add @RequestParam 'since' to existing /reactive/books.
```
</details>

#### 📦 AR02 — Format binaire (CBOR) (⚠️ Partiel (2/20) — +9 pts possibles)

> Un endpoint en format binaire (CBOR, protobuf...) doit exister. (2/20 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| ⚪ Basse | `GET /reactive/books  (add CBOR variant)` | Add a binary format alternative (CBOR or Protobuf) | +10 pts — binary formats are 30-50% smaller than JSON |
| ⚪ Basse | `GET /reactive/books/select  (add CBOR variant)` | Add a binary format alternative (CBOR or Protobuf) | +10 pts — binary formats are 30-50% smaller than JSON |

<details><summary>🔧 Comment implémenter</summary>

```
Spring Boot + CBOR:
  1. Add dependency: com.fasterxml.jackson.dataformat:jackson-dataformat-cbor
  2. Register the converter:
     @Bean
     public HttpMessageConverter<Object> cborConverter(ObjectMapper mapper) {
       ObjectMapper cborMapper = new ObjectMapper(new CBORFactory());
       return new MappingJackson2CborHttpMessageConverter(cborMapper);
     }
  3. Clients send: Accept: application/cbor

Alternative (Protobuf):
  Add spring-boot-starter-protobuf and define .proto schemas.
  Register ProtobufHttpMessageConverter.
```
</details>


---

## 🌱 Creedengo Éco-Design : **88/100** — Grade **A** 🟢

> Analyse statique de l'éco-conception du code source via [Creedengo](https://github.com/green-code-initiative) / SonarQube

> ⚠️ **Seules les règles Creedengo/écodesign sont comptabilisées** dans le score et le récapitulatif ci-dessous. Les règles SonarQube générales sont listées séparément.

- **Langages détectés** : java
- **Principal** : java
- **Plugins Creedengo** : java

### 📊 Récapitulatif — Règles Creedengo écodesign uniquement

| Sévérité | Nombre |
|:--------:|-------:|
| 🔴 **Bloquant** | 0 |
| 🟠 **Critique** | 0 |
| 🟡 **Majeur** | 0 |
| ⚪ **Mineur** | 142 |
| 🔵 **Info** | 0 |
| **Total** | **142** |

- **Issues écodesign** : 142
- **Règles écodesign violées** : 2 / 17 analysées
- **Formule du score** : (1 − 2/17) × 100 = **88/100**
- **Effort de remédiation** : 12h20min

- **Lignes de code** : 718

### 🏷️ Catégories éco-design

| Catégorie | Issues | Règles |
|-----------|-------:|-------:|
| 🌱 Éco-conception générale | 140 | 1 |
| 💾 Utilisation mémoire | 2 | 1 |

### 📋 Règles Creedengo violées

| Sévérité | Règle | Issues | Catégorie |
|:--------:|-------|-------:|-----------|
| ⚪ MINOR | **GCI82** — Variable can be made constant | 140 | general |
| ⚪ MINOR | **GCI76** — Avoid usage of static collections. | 2 | memory |

### 📁 Fichiers les plus impactés (écodesign)

| Fichier | Issues |
|---------|-------:|
| `api/BookReactiveController.java` | 37 |
| `api/BookController.java` | 36 |
| `repo/BookRepository.java` | 19 |
| `observability/PayloadLoggingFilter.java` | 8 |
| `api/FieldSelector.java` | 7 |
| `web/GlobalExceptionHandler.java` | 7 |
| `domain/Book.java` | 6 |
| `repo/BookRepository.java` | 5 |
| `web/ApiError.java` | 5 |
| `web/RateLimitFilter.java` | 5 |
| *… et 5 autres* | |

---

### 🔧 Issues SonarQube générales (hors écodesign) — 13 issues

> Ces issues proviennent des règles SonarQube standard (qualité de code, bugs, sécurité). Elles ne sont **pas** comptabilisées dans le score Creedengo.

| Sévérité | Nombre |
|:--------:|-------:|
| 🟠 Critique | 2 |
| 🟡 Majeur | 2 |
| ⚪ Mineur | 8 |
| 🔵 Info | 1 |
| **Total** | **13** |

| Sévérité | Règle | Issues |
|:--------:|-------|-------:|
| 🟠 CRITICAL | **S1192** — S1192 | 2 |
| 🟡 MAJOR | **S107** — S107 | 1 |
| 🟡 MAJOR | **S108** — S108 | 1 |
| ⚪ MINOR | **S1170** — S1170 | 2 |
| ⚪ MINOR | **S1319** — S1319 | 1 |
| ⚪ MINOR | **S116** — S116 | 1 |
| ⚪ MINOR | **S117** — S117 | 1 |
| ⚪ MINOR | **S1612** — S1612 | 1 |
| ⚪ MINOR | **S1602** — S1602 | 1 |
| ⚪ MINOR | **S1659** — S1659 | 1 |
| 🔵 INFO | **S1135** — S1135 | 1 |

- **Effort de remédiation SonarQube** : 1h08min

📅 *2026-04-16T13:24:15Z*

---

🌿 *API Green Score — [Framework](https://github.com/API-Green-Score/APIGreenScore) | [Training](https://github.com/API-Green-Score/training-student) | 🌱 [Creedengo](https://github.com/green-code-initiative) | Devoxx France 2026*

> 📊 Pour le dashboard interactif complet, ouvrez [`dashboard/index.html`](index.html)
