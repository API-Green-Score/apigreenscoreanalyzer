# Green API Review Checklist (API Green Score)

Merci d’indiquer les **mesures avant/après** (payload/latence).

## Data Exchange
- [ ] **DE11 – Pagination** (size borné ≤100, validé)
- [ ] **DE08 – Filtrage** via `fields=` (whitelist, champs coûteux off par défaut)
- [ ] **DE01/USXX – Format & compression** (JSON/CBOR, Gzip activé & testé)
- [ ] **DE02/DE03 – Cache HTTP** (`Cache-Control` + **ETag**/`Last-Modified` → **304** en test)
- [ ] **DE06/US04 – Delta** (`/changes?since=…` ou `sinceVersion`)
- [ ] **206 Partial Content** (`Range: bytes=` pour ressources volumineuses)

## Usage / Archi / Logs
- [ ] **US01 – Query params** pour GET (page/size/fields)
- [ ] **US07 – Monitoring erreurs** (Actuator/metrics)
- [ ] **AR02 – Efficacité** (batch, agrégation, keyset pagination)
- [ ] **LO01 – Logs utiles** (bytes, timeMs, 304) & rétention documentée
- [ ] **Rate limiting** pour éviter rafales inutiles

## Sécurité & robustesse
- [ ] Validation inputs (bornes `size`, whitelist `fields`)
- [ ] Idempotency‑Key sur POST critiques

## Mesures
```
curl -s -w 'size=%{size_download} time=%{time_total}
' -o /dev/null <URL>
```
- Avant : …
- Après : …
- Gain : … %

## 🌿 Green Score (automatique)
> Le CI calculera automatiquement le **Green Score /100** et postera un commentaire détaillé sur cette PR.
> Consultez le dashboard : `dashboard/index.html`

