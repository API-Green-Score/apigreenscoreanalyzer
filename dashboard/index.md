# 🌿 Green API Score Dashboard

> 📦 **Application : optcreedgreen**
>
> **Devoxx France 2026 — Green Architecture : moins de gras, plus d'impact !**

📅 *Dernière analyse : 2026-05-01T09:53:46Z*

---

## 🟡 Green Score : **54/100** — Grade **D** 📉

### 📋 Détail par règle

| Statut | Règle | Score | Max | Endpoints | Détail |
|:------:|-------|------:|----:|:---------:|--------|
| ⚠️ | DE11 Pagination | 5 | 15 | 4/11 | Pagination on 4/11 collection endpoint(s) |
| ⚠️ | DE08 Filtrage champs | 2 | 15 | 2/17 | Field filtering on 2 endpoint(s) |
| ✅ | DE01 Compression | 15 | 15 | 20/20 | Gzip compression active (OpenAPI servers.x-server-compression.enabled=true) |
| ✅ | DE02/03 Cache ETag | 15 | 15 | 6/6 | ETag + 304 supported (OpenAPI servers.x-server-etag-support.enabled=true) |
| ⚠️ | DE06 Delta | 1 | 10 | 2/17 | Delta endpoint(s) found: 2 |
| ✅ | 206 Range | 10 | 10 | 17/17 | Range/206 supported (OpenAPI servers.x-server-range-support.enabled=true) |
| ❌ | LO01 Observabilité | 0 | 5 | 0/5 | No health endpoint |
| ❌ | US07 Rate Limit | 0 | 5 | 0/20 | Assumed present (API running, no explicit headers) |
| ⚠️ | AR02 CBOR | 1 | 10 | 2/20 | Binary format on 2 endpoint(s) |

### 📊 Mesures par endpoint (API découverte)

| Méthode | Endpoint | Taille | Temps | HTTP |
|:-------:|----------|-------:|------:|-----:|
| GET | `/books/{id}` | 184 B | 0.015s | 200 |
| PUT | `/books/{id}` | 209 B | 0.007s | 200 |
| GET | `/reactive/books/{id}/summary` | 0 B | 0.029s | 200 |
| POST | `/reactive/books/{id}/summary` | 0 B | 0.020s | 200 |
| GET | `/books/{id}/summary` | 36 B | 0.002s | 200 |
| POST | `/books/{id}/summary` | 207 B | 0.002s | 200 |
| GET | `/reactive/books` | 0 B | 0.012s | 200 |
| GET | `/reactive/books/{id}` | 0 B | 0.004s | 200 |
| GET | `/reactive/books/select` | 0 B | 0.005s | 200 |
| GET | `/reactive/books/changes` | 0 B | 0.011s | 200 |
| GET | `/reactive/books/cbor` | 20 B | 0.001s | 429 |
| GET | `/reactive/books/cacheable` | 20 B | 0.001s | 429 |
| GET | `/books` | 20 B | 0.001s | 429 |
| GET | `/books/select` | 20 B | 0.001s | 429 |
| GET | `/books/noCache/{id}` | 20 B | 0.001s | 429 |
| GET | `/books/changes` | 20 B | 0.001s | 429 |
| GET | `/books/cbor` | 20 B | 0.001s | 429 |
| GET | `/books/batch` | 20 B | 0.001s | 429 |
| GET | `/books/async` | 20 B | 0.001s | 429 |
| GET | `/books/async/{id}` | 20 B | 0.001s | 429 |

### 🔑 Métriques clés

- **Endpoints mesurés** : 20
- **Transfert total** : 836 B
- **Transfert moyen / endpoint** : 41 B
- **Temps moyen** : 0.006s
- **⚡ Énergie totale / appel** : 0.0008 Wh
- **🌍 CO₂ / appel** : 0.00004 g (France — 53 gCO₂/kWh)

### 💡 Suggestions d'amélioration

> **Score actuel : 54/123** — Score potentiel avec toutes les suggestions : **123/123** (+69 pts possibles)

🔴 Haute priorité : 14 | 🟡 Moyenne : 14 | ⚪ Basse : 2 | **Total : 30 suggestions**

#### 📌 AR02_runtime_close (❌ Non validé — +7 pts possibles)

> Déployer l'API au plus près des consommateurs (CDN, edge, anycast multi-régions). (0/20 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🟡 Moyenne | `AR02` | Aucun signal d'edge/CDN cross-validé (runtime + HEAD). Mettre l'API derrière un edge/CDN multi-régions (Cloudflare, CloudFront, Front Door, Fastly, Akamai…) pour rapprocher le runtime des consommateurs. | +7 pts (AR02). |
| 🟡 Moyenne | `AR02` | La spec OpenAPI ne déclare qu'une seule URL de serveur. Ajouter plusieurs entrées `servers[]` régionales (ex: eu-west, us-east) pour documenter un déploiement multi-régions. | +7 pts (AR02). |
| 🟡 Moyenne | `AR02` | Activer HTTPS sur la cible pour permettre la mesure de latence TLS et bénéficier d'un edge/CDN moderne. | +7 pts (AR02). |

#### 📌 AR01_event_driven (❌ Non validé — +6 pts possibles)

> Utiliser une architecture événementielle (callbacks, webhooks, AsyncAPI, SSE, WebSocket, broker) pour éviter le polling. (0/20 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🔴 Haute | `PUT /books/{id}` | Publier un événement domaine après mutation (Kafka/RabbitMQ/Azure Service Bus/EventBridge) pour découpler les consommateurs. Documenter via callbacks (OAS 3.x) ou un AsyncAPI dédié. | +6 pts (AR01) — supprime un cycle de polling, réduit la bande passante et la charge serveur. |
| 🔴 Haute | `POST /reactive/books/{id}/summary` | Publier un événement domaine après mutation (Kafka/RabbitMQ/Azure Service Bus/EventBridge) pour découpler les consommateurs. Documenter via callbacks (OAS 3.x) ou un AsyncAPI dédié. | +6 pts (AR01) — supprime un cycle de polling, réduit la bande passante et la charge serveur. |
| 🔴 Haute | `POST /books/{id}/summary` | Publier un événement domaine après mutation (Kafka/RabbitMQ/Azure Service Bus/EventBridge) pour découpler les consommateurs. Documenter via callbacks (OAS 3.x) ou un AsyncAPI dédié. | +6 pts (AR01) — supprime un cycle de polling, réduit la bande passante et la charge serveur. |
| 🔴 Haute | `GET /reactive/books/changes` | Remplacer le polling par un flux d'événements: exposer le même besoin via SSE (text/event-stream) ou un sujet AsyncAPI/Kafka pour pousser les changements aux abonnés. | +6 pts (AR01) — supprime un cycle de polling, réduit la bande passante et la charge serveur. |
| 🔴 Haute | `GET /reactive/books/changes` | Long-polling détecté → migrer vers WebSocket ou SSE. Le client ouvre une seule connexion et reçoit les événements push, divisant les RTT/CPU par 10 à 100×. | +6 pts (AR01) — supprime un cycle de polling, réduit la bande passante et la charge serveur. |
| 🔴 Haute | `GET /books/changes` | Remplacer le polling par un flux d'événements: exposer le même besoin via SSE (text/event-stream) ou un sujet AsyncAPI/Kafka pour pousser les changements aux abonnés. | +6 pts (AR01) — supprime un cycle de polling, réduit la bande passante et la charge serveur. |
| 🔴 Haute | `GET /books/changes` | Long-polling détecté → migrer vers WebSocket ou SSE. Le client ouvre une seule connexion et reçoit les événements push, divisant les RTT/CPU par 10 à 100×. | +6 pts (AR01) — supprime un cycle de polling, réduit la bande passante et la charge serveur. |
| 🟡 Moyenne | `AR01` | Aucun signal EDA détecté mais 7 opportunité(s) de migration vers SSE/AsyncAPI/WebSocket trouvées (cf. EDA Advisor). | +6 pts (AR01). |

<details><summary>🔧 Comment implémenter</summary>

```
Condition détectée: mutating-without-callback
Indice: Mutation declared but no OAS callbacks/webhooks
Cible recommandée: Domain Event publication
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

#### 📌 AR04_scalable_infra (❌ Non validé — +5 pts possibles)

> Préférer une infrastructure auto-scalable (HPA, KEDA, autoscale, serverless). (0/20 endpoints validés)

| Priorité | Cible | Action | Impact |
|:--------:|-------|--------|--------|
| 🟡 Moyenne | `AR04` | Aucun signal d'auto-scaling détecté dans les fichiers IaC/build. | +5 pts (AR04). |
| 🟡 Moyenne | `AR04` | Activer HPA/KEDA (Kubernetes), autoscale Terraform/Bicep, ou déployer en serverless (Azure Functions, AWS Lambda, Cloud Run). | +5 pts (AR04). |

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
| ⚪ **Mineur** | 145 |
| 🔵 **Info** | 0 |
| **Total** | **145** |

- **Issues écodesign** : 145
- **Règles écodesign violées** : 2 / 17 analysées
- **Formule du score** : (1 − 2/17) × 100 = **88/100**
- **Effort de remédiation** : 12h35min

- **Lignes de code** : 1,017

### 🏷️ Catégories éco-design

| Catégorie | Issues | Règles |
|-----------|-------:|-------:|
| 🌱 Éco-conception générale | 143 | 1 |
| 💾 Utilisation mémoire | 2 | 1 |

### 📋 Règles Creedengo violées

| Sévérité | Règle | Issues | Catégorie |
|:--------:|-------|-------:|-----------|
| ⚪ MINOR | **GCI82** — Variable can be made constant | 143 | general |
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
| *… et 6 autres* | |

---

### 🔧 Issues SonarQube générales (hors écodesign) — 16 issues

> Ces issues proviennent des règles SonarQube standard (qualité de code, bugs, sécurité). Elles ne sont **pas** comptabilisées dans le score Creedengo.

| Sévérité | Nombre |
|:--------:|-------:|
| 🟠 Critique | 3 |
| 🟡 Majeur | 7 |
| ⚪ Mineur | 5 |
| 🔵 Info | 1 |
| **Total** | **16** |

| Sévérité | Règle | Issues |
|:--------:|-------|-------:|
| 🟠 CRITICAL | **S1192** — S1192 | 3 |
| 🟡 MAJOR | **S6126** — S6126 | 5 |
| 🟡 MAJOR | **S108** — S108 | 1 |
| 🟡 MAJOR | **S107** — S107 | 1 |
| ⚪ MINOR | **S1170** — S1170 | 2 |
| ⚪ MINOR | **S1612** — S1612 | 1 |
| ⚪ MINOR | **S1602** — S1602 | 1 |
| ⚪ MINOR | **S1319** — S1319 | 1 |
| 🔵 INFO | **S1135** — S1135 | 1 |

- **Effort de remédiation SonarQube** : 1h26min

📅 *2026-05-01T10:02:38Z*

---

🌿 *API Green Score — [Framework](https://github.com/API-Green-Score/APIGreenScore) | [Training](https://github.com/API-Green-Score/training-student) | 🌱 [Creedengo](https://github.com/green-code-initiative) | Devoxx France 2026*

> 📊 Pour le dashboard interactif complet, ouvrez [`dashboard/index.html`](index.html)
