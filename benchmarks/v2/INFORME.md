# Benchmark API v2 (S2-P4-02) — comparación contra línea base

- **Tarea:** `S2-P4-02` del plan P4 (`doc-service/docs/pasos-iniciales.md` §7.6).
- **Owner:** P4 (Integración y Calidad).
- **Fecha de ejecución:** 16/11/2026 (local, UTC-3).
- **Estado:** **HECHA con limitaciones declaradas** (§5).
- **Evidencia cruda:** `benchmarks/v2/{health,list,create,state}-run{1,2,3}-summary.json`,
  puntos k6 en `*.json.gz`, y `docs/evidencias/S2/S2-P4-02-k6-*`.

## 1. Objetivo

Comparar el stack nuevo contra la línea base del monolito (`S0-P4-02`,
`benchmarks/baseline/INFORME.md`) con los mismos escenarios: p95, throughput y
tasa de error.

## 2. Entorno medido

| Elemento | Valor |
|---|---|
| doc-service | commit `722bae2`, imagen `doc-service:local` reconstruida el 16/11/2026 |
| k6 | `v2.2.0` (commit `00a9a1b7f5`, go1.26.5) |
| Red | acceso **directo** a `doc-service:8080` (sin Traefik ni TLS) |
| Base de datos | Mongo del stack Compose, con ~14.000 documentos acumulados |
| Escenarios | `tests/k6/v2/*.js`, 10 s de warm-up a 1 VU + 3 corridas medidas por escenario |

**Por qué directo y no por Traefik:** desde S7 el gateway aplica el rate limit
(`rate=10/s burst=20`) a `/api/v2/*`. Una corrida a 10 VUs por Traefik satura el
límite y devuelve 429 en el 93–96 % de las peticiones, así que mide el limitador
y no la capacidad del doc-service. La línea base también se midió directo
(Uvicorn sin gateway), por lo que medir directo es la comparación equivalente.

## 3. Resultados (3 corridas por escenario)

| Escenario | Run | Requests | RPS | Avg ms | Med ms | p95 ms | Max ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| health | 1 | 36.523 | 811,6 | 9,0 | 5,6 | 28,2 | 225,5 |
| health | 2 | 37.643 | 836,4 | 8,7 | 5,5 | 25,6 | 311,0 |
| health | 3 | 39.117 | 869,2 | 8,4 | 5,6 | 24,3 | 228,1 |
| list | 1 | 497 | 11,0 | 761,5 | 751,5 | 1434,7 | 2041,2 |
| list | 2 | 501 | 11,1 | 760,0 | 711,2 | 1431,9 | 1956,3 |
| list | 3 | 516 | 11,4 | 737,3 | 701,7 | 1352,3 | 1583,2 |
| create | 1 | 51 | 5,1 | 22,1 | 15,3 | 55,3 | 74,4 |
| create | 2 | 51 | 5,1 | 16,2 | 12,4 | 27,9 | 56,9 |
| create | 3 | 51 | 5,1 | 19,9 | 15,0 | 57,9 | 79,5 |
| state | 1 | 6.958 | 154,6 | 25,7 | 18,9 | 72,3 | 272,3 |
| state | 2 | 6.734 | 149,4 | 26,5 | 19,4 | 79,4 | 300,6 |
| state | 3 | 6.028 | 133,9 | 29,7 | 20,7 | 83,3 | 795,2 |

Tasa de error HTTP: **0 %** en las 12 corridas (`http_req_failed = 0`), con
checks al 100 %.

## 4. Comparación contra la línea base

Regla congelada: p95 ≤ 1,2× el p95 del escenario equivalente de la línea base.

| Escenario v2 | Equivalente base | p95 base | Umbral 1,2× | p95 v2 (mediana) | Veredicto |
|---|---|---:|---:|---:|---|
| `health` (`GET /healthz`) | `GET /health` | 37,1 ms | 44,5 ms | 25,6 ms | **Pasa** (0,69×) |
| `list` (`GET /api/v2/documents`) | `GET /registros` | 210,5 ms | 252,6 ms | 1.431,9 ms | **Falla** (6,8×) |
| `create` (`POST /api/v2/documents`) | `POST /pdf/process` (no equivalente) | 71,8 ms | — | 55,3 ms | Sin comparación directa |
| `state` (`GET /api/v2/documents/{id}`) | `GET /registros/{id}` (no medido en base) | — | — | 79,4 ms | Sin comparación directa |

Throughput mediano: `health` ~836 rps (base ~435 rps); `list` ~11,1 rps
(base ~73,6 rps); `create` ~5,1 rps; `state` ~149 rps.

## 5. Limitaciones y diferencias explicadas

1. **`list` no es comparable por tamaño de dataset.** El escenario v2 recorre una
   colección con ~14.000 documentos y el plan de consulta hace `COLLSCAN`
   (documentado en `docs/evidencias/S5/S5-P4-evidencia-parcial.md`); la línea base
   medía 100 registros. La regresión de p95 es de la consulta/dataset, no del
   transporte: la misma corrida por Traefik mostró los 500 de `list` por
   cancelación de handshake tras el scan. Queda como follow-up de P2 (índice o
   paginación con límite superior efectivo).
2. **`create` mide la prefirma, no el procesamiento del PDF.** El camino v2
   responde `201` con URL prefirmada y el PDF no pasa por el doc-service; el
   equivalente base (`POST /pdf/process`) hacía el trabajo completo. No se
   declara paridad de latencia con ese escenario.
3. **`state` no tiene baseline propio.** Se reporta como referencia operativa.
4. **Arriba de la tasa del limitador el gateway cambia la medición.** Cualquier
   benchmark de capacidad debe correr directo o con una política de límites
   explícita; por Traefik la métrica dominante son los 429.
5. **El escenario `list` incumple el umbral y así queda registrado.** No se
   relabela como éxito; es un hallazgo con causa y owner.
