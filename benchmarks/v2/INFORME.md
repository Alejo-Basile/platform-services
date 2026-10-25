# Benchmark API-level v2 con k6 — S2-P4-02

- **Tarea:** `S2-P4-02` del plan `docs/plan-P4-S2-S3.md`.
- **Owner:** P4 (Integration & Quality).
- **Fecha de ejecución:** 24/10/2026, 16:58–17:05 (UTC-3).
- **Estado:** **HECHA con limitaciones declaradas**. La cadena completa queda **BLOQUEADA** hasta G-B (worker real).
- **Evidencia cruda:** `benchmarks/v2/*.json.gz`, `benchmarks/v2/*-summary.json`, `benchmarks/v2/resultados.csv` y `docs/evidencias/S2/S2-P4-02-k6-*`.

## 1. Objetivo y alcance

Medir el camino API-level del `doc-service` v2 en el host fijo usado por la línea base:

1. `GET /healthz`;
2. `GET /api/v2/documents?limit=10` (listado por cursor);
3. `POST /api/v2/documents` (creación + prefirma);
4. `POST /api/v2/documents` seguido de `GET /api/v2/documents/{id}` (estado).

No se mide subida a MinIO, webhook, worker, extracción ni `COMPLETED`: esas etapas dependen de G-B y quedan fuera de este informe. Por eso `create` y `state` no son equivalentes al `POST /pdf/process` del monolito; se usan solo como referencia débil.

## 2. Entorno

| Elemento | Valor |
|---|---|
| Hardware | Intel Core i3-8130U, 4 vCPU, 3,7 GiB RAM, Linux |
| k6 | `v2.2.0` (`00a9a1b7f5`, go1.26.5) |
| Gateway | Traefik `v3.7`, TLS local, `cpus: 0.5` |
| doc-service | imagen local `doc-service:latest` (`sha256:c1bab847…`, creada 21/10/2026) |
| MongoDB | réplica `rs0` en contenedor |
| Redis | contenedor local con credencial previa; el relay no participa en estas rutas |
| MinIO | contenedor local; solo se firma la URL, no se sube binario |
| Red | `https://api.localhost:8543` vía Traefik |
| Código de referencia | `platform-services` `4294956`, `infra` `a7e44d0`, `doc-service` `210be28` |

**Limitación de imagen:** no se reconstruyó `doc-service` para no recrear el contenedor con secretos nuevos sobre un volumen Mongo ya inicializado. Los números validan la imagen local del 21/10, no necesariamente el commit `210be28`. El CI de Compose sí construye la imagen actual y debe repetir este smoke.

## 3. Escenarios y carga

Cada escenario tiene warm-up de 10 s a 1 VU y 3 corridas medidas. Los escenarios conservan la forma de la línea base:

| Escenario | Flujo | Carga |
|---|---|---|
| `health` | `GET /healthz` | rampa 10 s a 10 VUs, 30 s a 10 VUs, 5 s de bajada |
| `list` | `GET /api/v2/documents?limit=10` | rampa 10 s a 10 VUs, 30 s a 10 VUs, 5 s de bajada |
| `create` | `POST /api/v2/documents` | rampa 10 s a 5 VUs, 30 s a 5 VUs, 5 s de bajada |
| `state` | `POST` + `GET /api/v2/documents/{id}` | rampa 10 s a 5 VUs, 30 s a 5 VUs, 5 s de bajada |

Umbral aplicado en el smoke de CI: `http_req_failed: rate==0` y `checks: rate==1`.

Umbrales p95 de las corridas comparativas (`run-v2.sh`, regla `p95 <= 1,2x baseline`):

| Escenario | p95 máximo | Estado |
|---|---:|---|
| `list` | 252,6 ms | Activo (`210,5 ms x 1,2`) |
| `health` | 44,52 ms | Condicionado a P1: desactivado por defecto; activar con `P4_HEALTH_P95_MS=44.52` |
| `create` | — | Sin baseline equivalente |
| `state` | — | Sin baseline equivalente |

Las 12 corridas históricas terminaron con `http_req_failed = 0` y `checks = 1,0`. La automatización de thresholds se incorporó después de esas corridas; el rerun con la imagen actual sigue pendiente (platform-services#5).

## 4. Resultados

Mediana de las 3 corridas:

| Escenario | RPS | Avg ms | p50 ms | p95 ms | p99 ms | Error rate |
|---|---:|---:|---:|---:|---:|---:|
| `health` | 172,5 | 47,3 | 37,7 | 104,1 | 157,2 | 0 |
| `list` | 132,8 | 60,3 | 53,2 | 125,7 | 183,7 | 0 |
| `create` | 83,4 | 48,4 | 41,6 | 99,8 | 141,4 | 0 |
| `state` | 101,6 | 39,9 | 32,5 | 96,2 | 145,4 | 0 |

Las 12 corridas completas están en `benchmarks/v2/resultados.csv`. No hubo errores HTTP ni checks fallidos.

## 5. Comparación con la línea base

La línea base se midió contra Uvicorn directo, HTTP y sin gateway. La comparación con Traefik/TLS no es equivalente, pero se aplica la regla congelada: regresión si `p95 > 1,2 × baseline` o si aparece un error inesperado.

| Escenario v2 | Baseline equivalente | RPS baseline | RPS v2 | Δ RPS | p95 baseline | p95 v2 | Δ p95 | p99 baseline | p99 v2 | Δ p99 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `health` | `GET /health` | ~435 | 172,5 | 0,40× | 37,1 | 104,1 | 2,81× | 52,0 | 157,2 | 3,02× |
| `list` | `GET /registros` | ~74 | 132,8 | 1,79× | 210,5 | 125,7 | 0,60× | 236,5 | 183,7 | 0,78× |
| `create`* | `POST /pdf/process` | ~90 | 83,4 | 0,93× | 71,8 | 99,8 | 1,39× | 86,1 | 141,4 | 1,64× |
| `state`* | `POST /pdf/process` | ~90 | 101,6 | 1,13× | 71,8 | 96,2 | 1,34× | 86,1 | 145,4 | 1,69× |

\* Sin baseline directo: `create`/`state` no hacen extracción ni subida; la comparación con `pdf_process` es solo orientativa.

**Lectura:**

- `list` mejora frente al listado legacy: más RPS y menor p95/p99. La paginación por cursor y la consulta acotada explican la diferencia; no es una comparación de carga idéntica.
- `health` es una **regresión a nivel de gateway** según la regla congelada (p95 2,81×). No es una regresión del handler: la medición directa al mismo `doc-service`, sin Traefik, dio **1.380,6 RPS y p95 14,7 ms** (45 s, 10 VUs, red interna).
- `create` y `state` no tienen baseline equivalente. Su p95 es mayor que el `pdf_process` cacheado, pero el trabajo es distinto y el camino incluye TLS/gateway.

## 6. Hallazgo: el límite de CPU de Traefik domina el health

El `health` por Traefik con `cpus: 0.5` quedó en 172,5 RPS y p95 104,1 ms. Para aislar la causa se hizo una prueba puntual, sin cambiar el repo:

| Camino | Duración / VUs | RPS | p95 |
|---|---|---:|---:|
| doc-service directo (red interna, sin Traefik) | 45 s / 10 | 1.380,6 | 14,7 ms |
| Traefik con `cpus: 0.5` (config actual) | 45 s / 10 | 172,5 | 104,1 ms |
| Traefik con `cpus: 2` (prueba temporal) | 30 s / 10 | 338,2 | 59,1 ms |

La prueba con 2 CPUs se revirtió a `0.5` al terminar (`NanoCpus=500000000`). El resultado muestra que el handler y Mongo no son el cuello de botella del health; el límite de CPU de Traefik y el costo de TLS/gateway explican la mayor parte. Aun con 2 CPUs el health no alcanza la línea base directa, por la diferencia de camino (TLS + Traefik + host compartido).

**Acción propuesta (P1, no P4):** decidir si `cpus: 0.5` es un requisito del entorno académico o un valor conservador; si se busca acercarse a la baseline, subirlo y repetir `health`. No se modifica `infra` en esta tarea.

## 7. Limitaciones

1. **Sin worker:** no se mide subida, webhook, extracción, `.txt` ni `COMPLETED`; la cadena completa sigue bloqueada por G-B.
2. **Imagen local del 21/10:** no se reconstruyó contra `doc-service` `210be28` para no romper el volumen Mongo con secretos nuevos. El CI debe repetir el smoke con la imagen construida.
3. **Baseline no equivalente:** Uvicorn directo sin TLS ni gateway; la regla de 1,2× se aplica como referencia, no como SLA.
4. **Redis local con credencial previa:** el relay no se usó en estas rutas; no afecta `health`, `create`, `state` ni `list`, pero el stack local no es reproducible solo con `infra/.env`.
5. **Host compartido:** k6, Traefik, doc-service, Mongo, Redis y MinIO comparten 4 vCPU. Los valores absolutos no son trasladables.
6. **Datos acumulados:** `list` se ejecutó antes de `create`/`state` para no medir un Mongo inflado por el propio benchmark; aun así había documentos de las pruebas E2E.
7. **Prueba de CPU de Traefik:** la corrida con 2 CPUs usó 30 s sin rampa, no es idéntica a las corridas de 45 s; es evidencia de dirección, no una medición oficial.

## 8. Estado de la tarea

- `S2-P4-02` API-level: **HECHA con limitaciones**. Informe, JSON crudo y CSV completos.
- Cadena completa (`UPLOADED` → `COMPLETED`): **BLOQUEADA** por G-B.
- Aceptación de performance: **no cerrada**. El health por gateway incumple la regla de regresión; requiere decisión de P1 sobre el límite de Traefik y repetir con la imagen actual.
- CI: `tests/k6/v2/run-smoke.sh` queda para el workflow; no reemplaza las 3 corridas comparativas.
- Automatización de regresión: smoke con `rate==0`/`checks==1`; `run-v2.sh` exige p95 de `list` y permite activar el de `health` cuando P1 decida el límite de Traefik.
- Rerun pendiente: repetir las 3 corridas por escenario con la imagen construida por CI y reemplazar estos números (platform-services#5).

## 9. Reproducción

```bash
# Stack local ya levantado y doc-service healthy
cd platform-services
tests/k6/v2/run-v2.sh

# Smoke de CI
tests/k6/v2/run-smoke.sh
```

## 10. Evidencia

| Archivo | Contenido |
|---|---|
| `benchmarks/v2/{scenario}-run{1,2,3}.json.gz` | puntos crudos de k6 |
| `benchmarks/v2/{scenario}-run{1,2,3}-summary.json` | resumen de k6 |
| `benchmarks/v2/resultados.csv` | tabla consolidada con p99 |
| `benchmarks/v2/direct-health-summary.json` | health directo al doc-service (sin Traefik) |
| `benchmarks/v2/gateway-health-cpu2-summary.json` | prueba puntual de Traefik con 2 CPUs |
| `docs/evidencias/S2/S2-P4-02-k6-*-warmup.txt` | salida del warm-up |
| `docs/evidencias/S2/S2-P4-02-k6-*-run*.txt` | salida de las 12 corridas |
