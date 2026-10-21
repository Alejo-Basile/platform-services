# Inventario de endpoints del monolito (`S0-P4-01`)

> Fuente: código del monolito `pdf-extractext` (FastAPI + PyMongo), leído el 19/10/2026 en
> `../pdf-extractext/src/interface/api/routes/`. Complementado con `README.md` del monolito y
> `doc-service/docs/pasos-iniciales.md` §11.2.
>
> Este inventario congela la superficie del contrato v1 antes de tocarlo (riesgo R13: alcance
> creciente). Toda ruta nueva del monolito que aparezca después entra por PR y con decisión
> registrada, no por sorpresa.

## 1. Rutas del monolito

| Método | Ruta | Request | Response | Auth | Errores | Destino en la arquitectura nueva |
|---|---|---|---|---|---|---|
| `GET` | `/health` | — | `200 {status, timestamp, version}` | ninguna | — | Queda en el monolito hasta el apagado. El camino nuevo usa `/healthz` del doc-service y del worker. |
| `GET` | `/health/ready` | — | `200 {status:"ready"}` | ninguna | — | Queda en el monolito hasta el apagado. Equivalente nuevo: `/readyz` que sí verifica dependencias. |
| `POST` | `/pdf/process` | `multipart/form-data` con `file`; exige `Content-Type: application/pdf` | `200 text/plain` (`.txt` como `StreamingResponse`) | ninguna | `400` tipo no soportado o validación; `422` PDF inválido o sin texto; `500` error de extracción. **Duplicado por hash: `200` con el texto cacheado** (`fue_cacheado=true`); `409` solo en la carrera de guardado, no en el flujo normal (verificado el 19/10/2026 con dos POST del mismo PDF) | **Reemplazado** por el flujo asíncrono v2: `POST /api/v2/documents` → subida prefirmada directa a MinIO → webhook → worker → `GET /api/v2/documents/{id}/download`. |
| `GET` | `/registros` | query `page` (≥1), `page_size` (1–100) | `200 {items, total, page, page_size}` | ninguna | `400` parámetros inválidos; `500` error interno | **Reemplazado** por `GET /api/v2/documents` (paginación por cursor y filtro por `status`). |
| `GET` | `/registros/hash/{hash_contenido}` | path de 64 hex | `200` registro completo | ninguna | `400` hash inválido; `404` no encontrado | **Se elimina**: la deduplicación por hash de contenido se sustituye por idempotencia con `Idempotency-Key` en v2. |
| `GET` | `/registros/{id_registro}` | path UUID | `200` registro completo | ninguna | `400` UUID inválido; `404` no encontrado | **Reemplazado** por `GET /api/v2/documents/{id}`. |
| `PUT` | `/registros/{id_registro}` | `application/json` con `nombre_archivo_original?` o `contenido_extraido?` | `200` registro actualizado | ninguna | `400` sin campos; `404` no encontrado | **Se elimina**: en v2 el estado lo gobierna la SAGA; no existe edición manual del contenido. |
| `DELETE` | `/registros/{id_registro}` | path UUID | `200 {eliminado, id_registro, mensaje}` | ninguna | `400` UUID inválido; `404` no encontrado | **Se elimina del camino de negocio**. Si el negocio lo necesita como operación administrativa, queda en el monolito hasta el apagado con decisión registrada. |
| `GET` | `/docs`, `/redoc`, `/openapi.json` | — | `200` HTML/JSON cuando `debug=true`; `404` si `debug=false` | ninguna | — | No aplica al camino nuevo. El contrato v2 vive en `platform-services/openapi/documents.yaml`. |

Observaciones del código que impactan la paridad y la migración:

- **No hay autenticación** en ninguna ruta del monolito. El rate limiting y la identidad de
  cliente son una capacidad nueva del camino v2 (S7), no una paridad a conservar.
- El monolito **valida los magic bytes** `%PDF-` y el tamaño (`max_size` / `min_size` de
  `Settings`), pero devuelve `422` cuando el PDF es inválido, no `400`.
- El monolito **deduplica por hash SHA256 del contenido** y, si el hash ya existe, devuelve el
  `.txt` cacheado (`fue_cacheado=true`) sin volver a extraer. En v2 la idempotencia es por
  `document_id`/`Idempotency-Key`, no por hash.
- El monolito devuelve el `.txt` **como stream en la misma request** (`200`). v2 responde `201`
  y separa la subida y la consulta: **no se comparan códigos HTTP** (ver `docs/paridad.md`).

## 2. Resumen de destinos

| Destino | Rutas |
|---|---|
| `doc-service` | `POST /pdf/process`, `GET /registros`, `GET /registros/{id}` (equivalentes v2) |
| `worker` | La extracción de `POST /pdf/process` pasa al worker; no hay endpoint propio expuesto. |
| `se elimina` | `GET /registros/hash/{hash}`, `PUT /registros/{id}`, `DELETE /registros/{id}` (del camino de negocio). |
| `queda en el monolito` | `/health`, `/health/ready`, `/docs`, `/redoc`, `/openapi.json` y las operaciones administrativas que el negocio decida conservar. |

## 3. Cobertura del inventario

- [x] Todas las rutas declaradas en los routers del monolito están en la tabla.
- [x] El 100 % tiene destino asignado (una por una, sin `catch-all`).
- [ ] Consumidores identificados con datos reales (pendiente de access logs del monolito; ver
      `docs/clientes.md`). El único consumidor técnico confirmado hoy es el gateway Strangler
      de `infra/`, que enruta `/*` legacy al monolito.
- [x] Revisión con P2 sobre los equivalentes v2 (contrato en `openapi/documents.yaml`).
- [x] Revisión con P1 sobre lo que queda en el monolito y por qué.

## 4. Riesgo y bloqueo declarado

La columna **consumidor real** no se puede completar sin los access logs del monolito en
producción (`S8-P4-05` los exige medidos, no estimados). Mientras no existan, `S0-P4-07`
(ADR-0018) queda **BLOQUEADA en su parte de negocio**: se puede redactar la decisión técnica, pero
no fijar la fecha límite ni el inventario con responsable. No se inventan consumidores.
