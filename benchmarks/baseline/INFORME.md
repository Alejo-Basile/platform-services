# Línea base del monolito con k6 — S0-P4-02

- **Tarea:** `S0-P4-02` del plan `docs/plan-P4-S0-S1.md`.
- **Owner:** P4 (Integration & Quality).
- **Fecha de ejecución:** 19/10/2026 (local, UTC-3).
- **Estado:** **HECHA con limitaciones declaradas** (ver §7). La línea base es local y reproducible; no se ejecutó sobre Traefik/TLS/MinIO.
- **Evidencia cruda:** `benchmarks/baseline/*.json` y `docs/evidencias/S0/S0-P4-02-*`.

## 1. Objetivo

Medir el comportamiento del monolito legado **antes** de la migración para tener una referencia
objetiva de:

1. latencia p50/p95/p99 y RPS sostenible de los flujos seguros del inventario;
2. tasa de error y de checks;
3. tamaño máximo de PDF aceptado y código de rechazo.

Esta referencia se congela para comparar `S2-P4-02` (doc-service) y el replay de S8. Cambiar los
escenarios después invalida la comparación.

## 2. Entorno medido

| Elemento | Valor |
|---|---|
| Hardware | Intel Core i3-8130U, 4 vCPU, 3,7 GiB RAM, Linux |
| k6 | `v2.2.0` (commit `00a9a1b7f5`, go1.26.5) |
| Python del monolito | 3.11.15 |
| MongoDB | contenedor `mongo:latest`, `mongod v8.2.6`, puerto local `127.0.0.1:27017` |
| Monolito | `src.interface.main:app` vía Uvicorn, 1 worker, `127.0.0.1:8000` |
| Commit del monolito | `main` = `830f5b1` (worktree temporal en `/tmp/opencode/pdf-extractext-main`) |
| Configuración | `MONGO_HOST=127.0.0.1`, `max_size=26214400`, `min_size=1`, `debug=false` |
| Red | acceso directo a Uvicorn; sin Traefik, sin TLS, sin MinIO |

**Por qué `main` y no la rama activa:** el HEAD de `chadbranch` (`f9cd1f7`) no importa
`EmptyInputDTO` en `registro_procesamiento_mapper.py` y la aplicación no arranca. Para no modificar
el repo del monolito se creó un worktree de solo lectura sobre `main`, que sí arranca. Esto debe
tenerse en cuenta al comparar con una URL real: la referencia es del código de `main`, no de
`chadbranch`.

El `.venv` original del monolito tiene un shebang apuntando a una ruta inexistente y no incluye
`pip`; se usó un venv temporal en `/tmp/opencode/p4-venv` con las dependencias del proyecto. El
monolito no fue modificado.

## 3. Escenarios k6

Archivos congelados en `tests/k6/baseline/`:

| Escenario | Flujo | Carga medida |
|---|---|---|
| `health.js` | `GET /health` | rampa 10 s a 10 VUs, 30 s a 10 VUs, 5 s de bajada |
| `registros.js` | `GET /registros?page=1&page_size=10` | rampa 10 s a 10 VUs, 30 s a 10 VUs, 5 s de bajada |
| `pdf_process.js` | `POST /pdf/process` multipart | rampa 10 s a 5 VUs, 30 s a 5 VUs, 5 s de bajada |

Cada escenario tiene un **warm-up de 10 s a 1 VU** y luego **3 corridas medidas**. Los PDFs son
100 fixtures de una página, texto único, generados sin dependencias con
`tests/fixtures/pdf/generate_fixtures.py`. Los duplicados son parte del comportamiento normal: el
monolito responde `200` con el texto cacheado (ver §6).

## 4. Resultados

Crudo: `benchmarks/baseline/{scenario}-run{1,2,3}.json.gz` (puntos k6, comprimidos) y
`...-summary.json` (resumen). Tabla consolidada: `benchmarks/baseline/resultados.csv`.

| Escenario | Run | Requests | RPS | Avg ms | p50 ms | p95 ms | p99 ms | Max ms | Error rate | Checks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| health | 1 | 19.088 | 424,1 | 19,1 | 17,7 | 37,6 | 52,0 | 106,0 | 0,0000 | 1,0 |
| health | 2 | 20.133 | 447,3 | 18,1 | 16,3 | 36,5 | 52,2 | 104,8 | 0,0000 | 1,0 |
| health | 3 | 19.572 | 434,9 | 18,7 | 17,5 | 37,1 | 48,6 | 116,9 | 0,0000 | 1,0 |
| pdf_process | 1 | 4.114 | 91,4 | 45,3 | 48,1 | 71,8 | 86,1 | 137,6 | 0,0000 | 1,0 |
| pdf_process | 2 | 4.033 | 89,6 | 46,3 | 48,2 | 70,8 | 83,8 | 115,2 | 0,0000 | 1,0 |
| pdf_process | 3 | 3.987 | 88,6 | 46,8 | 48,4 | 72,2 | 86,3 | 143,5 | 0,0000 | 1,0 |
| registros | 1 | 3.298 | 73,3 | 113,9 | 114,9 | 211,1 | 236,5 | 297,0 | 0,0000 | 1,0 |
| registros | 2 | 3.310 | 73,6 | 113,5 | 114,0 | 210,5 | 240,8 | 285,4 | 0,0000 | 1,0 |
| registros | 3 | 3.396 | 75,5 | 110,6 | 116,8 | 199,5 | 231,7 | 284,8 | 0,0000 | 1,0 |

Resumen por escenario (mediana de las 3 corridas):

| Escenario | RPS | p50 ms | p95 ms | p99 ms | Error rate |
|---|---:|---:|---:|---:|---:|
| `GET /health` | ~435 | ~17,5 | ~37,1 | ~52,0 | 0 |
| `GET /registros` | ~74 | ~114,9 | ~210,5 | ~236,5 | 0 |
| `POST /pdf/process` | ~90 | ~48,2 | ~71,8 | ~86,1 | 0 |

**Observaciones:**

- Los 3 escenarios terminaron con `http_req_failed = 0` y `checks = 1,0` en las 9 corridas.
- `GET /health` es el endpoint más rápido y estable; es el candidato natural para el healthcheck
  del gateway y para el smoke de `S0-P4-05`.
- `GET /registros` es el más costoso (p95 ~210 ms). La corrida se hizo con la base ya poblada por
  la línea base anterior (200+ registros); el costo relativo puede crecer con el volumen. No se
  debe usar este número como capacidad absoluta de la nueva paginación por cursor.
- `POST /pdf/process` mezcla dos caminos: extracción real de los primeros 100 PDFs únicos y caché
  por hash para el resto. Con ~4.000 requests por corrida, **la latencia está dominada por el
  camino cacheado**; el p95 de ~72 ms no representa la extracción de un documento nuevo. La
  extracción real se mide en S2/S8 con documentos frescos (ver §7).

## 5. Tamaño máximo de PDF aceptado

Evidencia: `docs/evidencias/S0/S0-P4-02-max-pdf.txt`.

Búsqueda binaria entre 1 MiB y 30 MiB contra `POST /pdf/process`:

| Resultado | Valor |
|---|---|
| Mayor tamaño aceptado (`200`) | **26.214.399 bytes** (~24,999999 MiB) |
| Primer tamaño rechazado (`400`) | **26.214.400 bytes** (25 MiB exactos) |
| Configuración | `max_size=26214400` |

El monolito rechaza con `400` cuando `len(contenido) >= max_size`. Por eso el límite efectivo es
`max_size - 1`; un PDF de exactamente 25 MiB se rechaza. Esto es una diferencia de borde que el
doc-service debe definir explícitamente (`> max_size` vs `>= max_size`) y que el contrato v2 debe
reflejar. El código de rechazo observado es `400` con detalle de validación, no `413`.

## 6. Hallazgo de contrato: duplicados

El inventario original decía `409` para un PDF duplicado. La ejecución real muestra otra cosa:

- Dos `POST /pdf/process` del mismo PDF devuelven **`200` con el texto cacheado**.
- El `409` existe en la ruta, pero solo se dispara en la carrera de guardado
  (`DocumentoDuplicadoException` al persistir), no en el flujo normal de deduplicación.
- El orquestador tiene una ruta explícita `_procesar_ruta_cacheado` y marca `fue_cacheado=true`.

Se corrigió `docs/inventario-endpoints.md` y `.csv`. Para la migración esto importa: el cliente v1
que dependa de `409` para deduplicar no lo está recibiendo; la idempotencia v2 (`Idempotency-Key`)
debe cubrir ese caso con `200`/`201` y una semántica explícita.

## 7. Limitaciones y validez

1. **No es la pila completa.** Se midió Uvicorn directo + MongoDB local. No hay Traefik, TLS,
   MinIO ni worker. Los números no incluyen latencia de gateway ni de subida a S3.
2. **`chadbranch` roto.** La referencia es `main` (`830f5b1`). Si el entorno real corre
   `chadbranch`, la comparación no es equivalente.
3. **PDF cacheados.** Como se explica en §4, `pdf_process` mide mayoritariamente caché. No usar
   este p95 como SLA de extracción.
4. **`registros` con base poblada.** El costo incluye más registros que una base recién creada.
5. **Hardware de laptop.** 4 vCPU y 3,7 GiB de RAM; los valores absolutos no son trasladables a
   otro host. Para CI/S2 comparar en el mismo entorno o usar la regla relativa de §8.
6. **Sin access logs.** El consumidor real de cada endpoint sigue pendiente (`S0-P4-01/07`).

## 8. Congelamiento para S2 y S8

Hashes de los escenarios (no cambiar sin registrar una nueva línea base):

```text
98458917cfbfe64cdb4a268f89def8c2b895f82ca919c267c5d2ec07c60b5a3f  health.js
1c408e2231687d5d4c3e52c078bbe3e9dbd2737e2269e4dd392d9513801fe48f  pdf_process.js
ae64c2ec9e7e112847ce54d3c3a27ebd36126fc47fbdfd586df485c452925275  registros.js
64125efb0a600beca58d04e2eb652ca414ab2d8671d65711bf244b99507ad5f9  run-baseline.sh
```

Umbrales de referencia (mismo entorno, mismas condiciones; no son SLA del servicio nuevo):

| Escenario | p95 | p99 | RPS mínimo | Error rate |
|---|---:|---:|---:|---:|
| `GET /health` | ≤ 40 ms | ≤ 60 ms | ≥ 400 | 0 |
| `GET /registros` | ≤ 230 ms | ≤ 260 ms | ≥ 70 | 0 |
| `POST /pdf/process` (camino cacheado) | ≤ 80 ms | ≤ 95 ms | ≥ 85 | 0 |

Regla de comparación para `S2-P4-02`: una regresión es un p95 > 1,2× el valor de la tabla **o**
cualquier error no esperado. Para extracción real, generar PDFs frescos por corrida y no reutilizar
los 100 fixtures.

## 9. Reproducción

```bash
# 1. MongoDB local (credenciales del .env del monolito; no se imprimen)
cd ../pdf-extractext
set -a; . ./.env; set +a
docker run -d --name p4-baseline-mongo -p 127.0.0.1:27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" \
  -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASS" mongo:latest

# 2. Monolito en un worktree de main (no tocar el working tree)
git worktree add /tmp/opencode/pdf-extractext-main main
cp .env /tmp/opencode/pdf-extractext-main/.env
cd /tmp/opencode/pdf-extractext-main
MONGO_HOST=127.0.0.1 MONGO_PORT=27017 max_size=26214400 min_size=1 debug=false \
  /tmp/opencode/p4-venv/bin/python -m uvicorn src.interface.main:app --host 127.0.0.1 --port 8000

# 3. Fixtures y línea base (en platform-services/)
python3 tests/fixtures/pdf/generate_fixtures.py --out tests/fixtures/pdf --count 100 --prefix baseline
BASE_URL=http://127.0.0.1:8000 ./tests/k6/baseline/run-baseline.sh

# 4. Tamaño máximo
python3 tests/k6/baseline/measure_max_pdf.py \
  --pdf tests/fixtures/pdf/baseline-0001.pdf \
  | tee docs/evidencias/S0/S0-P4-02-max-pdf.txt
```

## 10. Evidencia

| Archivo | Contenido |
|---|---|
| `benchmarks/baseline/*-run*.json.gz` | puntos crudos de k6 (cada request, gzip) |
| `benchmarks/baseline/*-summary.json` | resumen de k6 por corrida |
| `benchmarks/baseline/resultados.csv` | tabla consolidada con p99 calculado |
| `docs/evidencias/S0/S0-P4-02-k6-*-warmup.txt` | salida del warm-up |
| `docs/evidencias/S0/S0-P4-02-k6-*-run*.txt` | salida de las 9 corridas |
| `docs/evidencias/S0/S0-P4-02-max-pdf.txt` | búsqueda binaria del tamaño máximo |

## 11. Pendientes que no bloquean esta tarea

- Confirmar consumidores reales con access logs (`S0-P4-01/07`).
- Repetir la línea base sobre la pila completa (Traefik/TLS/MinIO/worker) cuando `infra/.env`,
  keyfile y certificados existan; hoy `S0-P4-05` está bloqueada por esos prerequisitos.
- Medir extracción de documentos frescos en S2/S8; esta línea base no sirve como SLA de extracción.
