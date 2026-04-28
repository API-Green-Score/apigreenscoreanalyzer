# 🌿 Green API Score Dashboard

> 📦 **Application : dotcreedgreen**
>
> **Devoxx France 2026 — Green Architecture : moins de gras, plus d'impact !**

📅 *Dernière analyse : 2026-04-28T23:16:50Z*

---

## 🔴 Green Score : **49/100** — Grade **D** 📉

### 📋 Détail par règle

| Statut | Règle | Score | Max | Endpoints | Détail |
|:------:|-------|------:|----:|:---------:|--------|
| ⚠️ | DE11 Pagination | 6 | 15 | 3/7 | Pagination on 3/7 collection endpoint(s) |
| ⚠️ | DE08 Filtrage champs | 8 | 15 | 4/8 | Field filtering on 4 endpoint(s) |
| ✅ | DE01 Compression | 15 | 15 | 11/11 | Gzip compression active |
| ✅ | DE02/03 Cache ETag | 15 | 15 | 1/1 | ETag + 304 supported (OpenAPI spec declares 304 Not Modified response) |
| ❌ | DE06 Delta | 0 | 10 | 0/8 | No delta endpoint found |
| ❌ | 206 Range | 0 | 10 | 0/8 | Range not supported |
| ✅ | LO01 Observabilité | 5 | 5 | 5/5 | Actuator/health detected |
| ❌ | US07 Rate Limit | 0 | 5 | 0/11 | Assumed present (API running, no explicit headers) |
| ❌ | AR02 CBOR | 0 | 10 | 0/11 | No binary format endpoint |

### 📊 Mesures par endpoint (API découverte)

| Méthode | Endpoint | Taille | Temps | HTTP |
|:-------:|----------|-------:|------:|-----:|
| GET | `/actuator` | 237 B | 0.027s | 200 |
| GET | `/actuator/info` | 219 B | 0.031s | 200 |
| GET | `/actuator/metrics` | 228 B | 0.029s | 200 |
| GET | `/` | 735 B | 0.099s | 200 |
| GET | `/Products` | 316 B | 0.039s | 200 |
| POST | `/Products` | 176 B | 0.033s | 415 |
| GET | `/Products/{id}` | 81 B | 0.035s | 200 |
| PUT | `/Products/{id}` | 176 B | 0.031s | 415 |
| GET | `/Scores/leaderboard` | 238 B | 0.033s | 200 |
| POST | `/Scores/calculate` | 176 B | 0.034s | 415 |
| GET | `/WeatherForecast` | 1.1 KB | 0.037s | 200 |

### 🔑 Métriques clés

- **Endpoints mesurés** : 11
- **Transfert total** : 3.7 KB
- **Transfert moyen / endpoint** : 338 B
- **Temps moyen** : 0.039s
- **⚡ Énergie totale / appel** : 0.0032 Wh
- **🌍 CO₂ / appel** : 0.00017 g (France — 53 gCO₂/kWh)

### 💡 Suggestions d'amélioration

> **Score actuel : 49/100** — Score potentiel avec toutes les suggestions : **100/100** (+51 pts possibles)

🔴 Haute priorité : 7 | 🟡 Moyenne : 4 | ⚪ Basse : 4 | **Total : 15 suggestions**

#### 🔄 DE06 — Delta / Changes (❌ Non validé — +10 pts possibles)

> Un endpoint /changes?since= ou equivalent doit exister. (0/8 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🟡 Moyenne | `GET /actuator/changes  (new endpoint)` | Add a delta/changes endpoint with a 'since' parameter | +1.2 pts/endpoint (total gap: 10 pts) — clients fetch only what changed since last sync |
| 🟡 Moyenne | `GET /actuator/info/changes  (new endpoint)` | Add a delta/changes endpoint with a 'since' parameter | +1.2 pts/endpoint (total gap: 10 pts) — clients fetch only what changed since last sync |
| 🟡 Moyenne | `GET /actuator/metrics/changes  (new endpoint)` | Add a delta/changes endpoint with a 'since' parameter | +1.2 pts/endpoint (total gap: 10 pts) — clients fetch only what changed since last sync |

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
Alternative: Add @RequestParam 'since' to existing /actuator.
```
</details>

#### ✂️ 206 — Range / Partial Content (❌ Non validé — +10 pts possibles)

> Supporter le header Range pour les gros payloads. (0/8 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| ⚪ Basse | `GET /Products/{id}` | Support HTTP Range header for partial content (206) | +10 pts — enables resumable downloads and partial fetches |
| ⚪ Basse | `GET /actuator` | Support HTTP Range header for partial content (206) | +10 pts — enables resumable downloads and partial fetches |

<details><summary>🔧 Comment implémenter</summary>

```
For JSON endpoints, Range/206 is rarely useful.
Focus on the file download endpoint(s) instead.
```
</details>

#### 📦 AR02 — Format binaire (CBOR) (❌ Non validé — +10 pts possibles)

> Un endpoint en format binaire (CBOR, protobuf...) doit exister. (0/11 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| ⚪ Basse | `GET /actuator  (add CBOR variant)` | Add a binary format alternative (CBOR or Protobuf) | +10 pts — binary formats are 30-50% smaller than JSON |
| ⚪ Basse | `GET /actuator/info  (add CBOR variant)` | Add a binary format alternative (CBOR or Protobuf) | +10 pts — binary formats are 30-50% smaller than JSON |

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

#### 🚦 US07 — Rate Limiting (❌ Non validé — +5 pts possibles)

> Un mecanisme de rate limiting doit etre present. (0/11 endpoints validés)

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

#### 📄 DE11 — Pagination (⚠️ Partiel (3/7) — +9 pts possibles)

> Les endpoints de collection doivent supporter la pagination (page/size ou limit/offset). (3/7 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🔴 Haute | `GET /actuator` | Add pagination parameters (page & size) | +2.1 pts/endpoint (total gap: 9 pts) — reduces payload size for large collections |
| 🔴 Haute | `GET /actuator/info` | Add pagination parameters (page & size) | +2.1 pts/endpoint (total gap: 9 pts) — reduces payload size for large collections |
| 🔴 Haute | `GET /` | Add pagination parameters (page & size) | +2.1 pts/endpoint (total gap: 9 pts) — reduces payload size for large collections |

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

#### 🔍 DE08 — Filtrage de champs (⚠️ Partiel (4/8) — +7 pts possibles)

> Supporter un parametre 'fields' pour reduire le payload. (4/8 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🔴 Haute | `GET /actuator` | Add a 'fields' query parameter for sparse fieldsets | +1.9 pts/endpoint (total gap: 7 pts) — lets clients request only needed fields, reducing payload |
| 🔴 Haute | `GET /actuator/info` | Add a 'fields' query parameter for sparse fieldsets | +1.9 pts/endpoint (total gap: 7 pts) — lets clients request only needed fields, reducing payload |
| 🔴 Haute | `GET /actuator/metrics` | Add a 'fields' query parameter for sparse fieldsets | +1.9 pts/endpoint (total gap: 7 pts) — lets clients request only needed fields, reducing payload |
| 🔴 Haute | `GET /` | Add a 'fields' query parameter for sparse fieldsets | +1.9 pts/endpoint (total gap: 7 pts) — lets clients request only needed fields, reducing payload |

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

---

🌿 *API Green Score — [Framework](https://github.com/API-Green-Score/APIGreenScore) | [Training](https://github.com/API-Green-Score/training-student) | 🌱 [Creedengo](https://github.com/green-code-initiative) | Devoxx France 2026*

> 📊 Pour le dashboard interactif complet, ouvrez [`dashboard/index.html`](index.html)
