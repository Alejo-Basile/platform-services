# Plan P4 — Semana 5 (F3 Worker)

**Owner:** P4 (Integración y Calidad)  
**Alcance:** `S5-P4-01`, `S5-P4-02`, `S5-P4-03` + arrastre `S3-P4-01`, `S3-P4-02`, `S3-P4-03` + verificaciones P4 del calendario (contract test del resultado, PDFs patológicos, k6 de subida sostenida, comparación p95).  
**Fuera de alcance:** implementación directa de P1/P2/P3. P4 verifica y reporta; no se usan mocks.  
**Premisa:** sin worker real no se simula. G-B es bloqueante.

## 0. Gates y precondiciones

| Gate | Criterio | Owner | Estado |
|---|---|---|---|
| **G-B1** | Merge `extraction-worker#11` → retarget/merge `#17`. `Dockerfile` no-root (multi-stage), usuario no-root, `HEALTHCHECK`. Servicio `extraction-worker` en Compose con `mem_limit`, `cpus`, `pids_limit`, `ulimits.nofile`, `read_only`, `cap_drop`, `security_opt`, secretos, redes y healthcheck. | P3/P1 | Bloqueado |
| **G-B2** | `/readyz` valida Redis, MinIO, Mongo **y consumer group registrado** (`XINFO GROUPS`), sin competir con permisos del bulkhead. | P3/P1 | Parcial (`#17` no valida grupo) |
| **G-B3** | `S5-P3-06` prueba de sostenimiento 1000 docs con memoria/descriptores estables. `S5-P3-05` PDFs patológicos/hostiles con timeout duro. | P3 | Pendiente |
| **G-B4** | `S5-P2-01`..`S5-P2-04` cerrados. `doc-service#45` (timeline con actores `client`, `minio-webhook`, `worker`, `reconciler`), `doc-service#55` (relay reencola tras caída) resueltos o medidos con `P4_STRICT_RELAY`. | P2 | Parcial |
| **G-B5** | Prometheus scrapea `extraction-worker`, `redis-exporter`, `minio`. Alertas con runbook real. `MinioDiskHigh` a 70%/85%. `QueueDepthHigh`, `PELBacklog`, `DLQNotEmpty`. | P1 | Parcial (scrape incompleto; runbooks faltantes) |
| **G-B6** | `S3-P4-01` cadena real verde 10/10 local y CI. | P4 | Bloqueado |

## 1. Arrastre S3 (prerrequisito)

| Tarea | Descripción | DoD | Evidencia |
|---|---|---|---|
| **S3-P4-01** | `tests/e2e/chain/run.sh`: crear → prefirmar → subir a MinIO → webhook → relay → worker → `.txt` → `COMPLETED` → descarga. | 10 corridas consecutivas sin mocks. Verifica objeto `.txt`, URL descarga, `status_history`. | `docs/evidencias/S3/S3-P4-01-e2e-real.txt` |
| **S3-P4-02** | Correlación automatizada: `correlation_id` presente en Traefik, doc-service, worker y `status_history` de Mongo. | Falla si falta en cualquiera. Incluye casos de header ausente/inválido. | `docs/evidencias/S3/S3-P4-02-correlation.txt` |
| **S3-P4-03** | Matriz de estados alcanzables forzando todos los caminos de fallo. Ciclo completo de reconciliación. | 0 documentos en estados no terminales. Todos terminan en `COMPLETED`, `FAILED`, `REJECTED` o `UPLOAD_EXPIRED`. | `docs/evidencias/S3/S3-P4-03-estados.txt` + matriz |

## 2. S5-P4-01 — Carga de 1000 documentos

### Arnés
- **K6:** `tests/e2e/load/pipeline.js`
- **Reporte:** `tests/e2e/load/report.sh` (mongosh/jq)
- **Orquestador:** `tests/e2e/load/run.sh`

### Flujo
1. `POST /api/v2/documents` con `idempotency_key` único y `size_bytes`.
2. Subida multipart directa a MinIO con `form_fields` devueltos.
3. Polling `GET /api/v2/documents/{id}` hasta estado terminal o timeout 600s.
4. Escritura de línea JSON por documento (doc_id, timestamps, status) para trazabilidad.

### Métricas obligatorias
- Creados, terminales, por estado (`COMPLETED`, `FAILED`, `REJECTED`, `UPLOAD_EXPIRED`), no terminales.
- p50/p95/p99 `POST→terminal`.
- Duplicados: entradas de stream por doc_id, `.txt` en `extracted-txt`, `COMPLETED` en `status_history`.
- Recuperados por reconciliador: entradas con actor `reconciler`.
- Perdidos: terminales ausentes o sin `.txt` válido.
- Conteo de `/internal`/historia y verificación de `correlation_id`.

### TTL / persistencia
- Índice TTL sobre `expires_at` no filtra por estado. Para esta corrida fijar `DOC_UPLOAD_GRACE_MIN` amplio (>= 180 min) en el stack de prueba. 
- Verificar explícitamente que ningún documento es borrado por TTL durante la ventana.
- Para 24h (S5-P4-02) usar `DOC_UPLOAD_GRACE_MIN=2880`.

### DoD
- 1000 documentos creados.
- 100 % terminales.
- 0 duplicados.
- 0 perdidos.
- Recuperados contabilizados y justificados.
- p50/p95/p99 medidos.

**Evidencia:** `docs/evidencias/S5/S5-P4-01-carga-1000.txt`, `docs/evidencias/S5/S5-P4-01-report.json`, `docs/evidencias/S5/S5-P4-01-report.csv`

## 3. S5-P4-03 — SLOs medibles

### SLOs propuestos (ratificar con primera corrida)
1. **Latencia pipeline:** p95 `POST→COMPLETED` < 5 min (alineado con SPEC §15.2).
2. **Convergencia temporal:** 100 % terminales en < 10 min.
3. **Convergencia total:** 100 % terminales, 0 duplicados, 0 no terminales, 0 perdidos. Recuperados medidos.

### Exportador propio (P4)
Crear `platform-services/slo-exporter/` (Go):
- **Conexión:** `MONGO_URI`, `MONGO_DB`, `LISTEN_ADDR` (`:9100`).
- **Métricas expuestas:**
  - `docservice_docs_total{status="..."}` 
  - `docservice_docs_non_terminal`
  - `docservice_docs_completed_total`, `docservice_docs_failed_total`, `docservice_docs_rejected_total`, `docservice_docs_upload_expired_total`
  - `docservice_docs_recovered_total` (historia con actor `reconciler`)
  - `docservice_pipeline_p95_seconds`, `docservice_pipeline_p99_seconds`
  - `docservice_pipeline_terminal_rate`, `docservice_pipeline_terminal_within_10m_rate`
- **Cálculo:** agrega sobre ventana configurable (`SLO_WINDOW`), cache 15s, consultas eficientes. Usa gauges (no histograma infinito).
- **Integración:** añadir servicio en `infra/compose/docker-compose.yml` (`profiles: ["full"]`), redes `data` + `internal`, límites, read-only, scrape en `prometheus.yml`. P1 integra, P4 desarrolla.

### Dashboard y alertas
- **Dashboard:** `infra/compose/grafana/dashboards/pipeline-slo.json` (p95/p99, terminal rate, <10min, no terminal, cola, PEL, DLQ, worker throughput, recuperados/perdidos).
- **Alertas:** `PipelineP95High` (>300s 10m), `PipelineTerminalRateLow` (<0.999 15m), `DocsNonTerminal` (>0 5m, ahora real), `QueueDepthHigh`, `DLQNotEmpty`, `MinioDiskHigh` (70%/85%).
- **Prueba:** provocar pausa de worker / ráfaga para disparar alertas y validar runbooks.

### DoD
- Los 3 números existen, se publican en dashboard.
- Umbrales configurados y probados.
- Exportador integrado y scrapeando.

**Evidencia:** `docs/evidencias/S5/S5-P4-03-slo.txt`, `docs/evidencias/S5/S5-P4-03-dashboard.txt`, `docs/evidencias/S5/S5-P4-03-alerts.txt`

**Nota:** `S5-P4-03` depende de `S5-P4-02` según el calendario. En S5 se implementa/valida con `S5-P4-01`; el cierre formal se produce tras las 24h en S6.

## 4. S5-P4-02 — 24 h sostenidas

**Entorno:** host dedicado (fuera de GitHub Actions). CI limitado a smoke de 1h nocturno.

### Escenarios
- **Carga mixta:** creación continua con k6 (válidos + % patológicos controlados).
- **Fallos periódicos:** reinicio de Redis (60s), `kill -9` worker (reclamado por otro), pausa/lentitud MinIO.
- **Recuperación:** validar convergencia, `XAUTOCLAIM`, reconciliación.

### Recolección
- SLOs cada 15 min.
- Recursos: CPU/mem/descriptores/red por servicio.
- Cola: `XLEN`, PEL, DLQ.
- Métricas SLO exporter.
- Intervenciones humanas (contabilizar).

### DoD
- 24h sin intervención humana no programada.
- 100 % terminales, 0 duplicados, 0 perdidos.
- SLOs medidos e informados.
- Incidentes documentados con recuperación.

**Evidencia:** `docs/evidencias/S5/S5-P4-02-endurance-24h.txt`, `docs/evidencias/S5/S5-P4-02-metrics.csv`, `docs/evidencias/S5/S5-P4-02-incidents.md`

## 5. Verificaciones P4 del calendario

| Tarea | Descripción | DoD | Evidencia |
|---|---|---|---|
| **Contract test del resultado** | Validar contrato terminal (doc), `.txt` existente y legible, `status_history`, `correlation_id`, envelope DLQ, `WorkItem`. | Tests reproducibles; falla ante contrato inválido. | `docs/evidencias/S5/S5-P4-04-contract.txt` |
| **E2E PDFs patológicos** | Encriptado, corrupto, sin texto extraíble, 0 bytes, gigante, hostil. Esperados `REJECTED`/`FAILED`/DLQ. | Sin OOM/crash; `/readyz` 200; causa registrada. | `docs/evidencias/S5/S5-P4-05-pathological.txt` |
| **k6 de subida sostenida** | Separado del pipeline completo; mide create/presign/upload sin esperar a COMPLETED masivamente. | Métricas, errores 0, timeouts controlados. | `docs/evidencias/S5/S5-P4-06-upload-sustained.txt` |
| **Comparación p95 pipeline vs baseline** | Comparar con `benchmarks/baseline` y `benchmarks/v2`. Explicar diferencias (asíncrono, prefirma, worker). | Informe con análisis. | `docs/evidencias/S5/S5-P4-07-p95-comparison.txt` |

## 6. Integración CI

Actualizar `platform-services/.github/workflows/e2e.yml`:
- Checkout `extraction-worker`.
- Build imagen worker local cuando exista servicio.
- Ejecutar `tests/e2e/chain/run.sh` (cuando G-B2 verde).
- Ejecutar `tests/e2e/load/run.sh --smoke` (pequeña corrida) para validar harness.
- Artefactos: logs, métricas, reportes.
- `workflow_dispatch` inputs: `load_docs`, `load_vus`, `chaos1_race_runs`.
- Nightly: smoke 1h; 24h **no** en CI.

## 7. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| G-B retrasado | Fase 0 sin ejecutar cadena; plan marcado bloqueante. No mocks. |
| TTL borra documentos | `DOC_UPLOAD_GRACE_MIN` amplio en prueba; vigilar; considerar índice TTL parcial (P2). |
| `doc-service#55` relay | Reconciliación cuenta como recuperado; `P4_STRICT_RELAY=1` tras fix. |
| `doc-service#45` timeline | Usar `completed_at`/`history`; priorizar fix. |
| Prometheus sin scrape Redis/MinIO/worker | P1 corrige; sin ello alertas NoData. |
| Sin métricas de negocio | Exportador propio (fase 0) evita depender solo de P2. |
| 24h infactible en CI | Host dedicado. |
| Flakiness k6/polling | Reintentos, timeouts generosos, limpieza por ID, report determinista. |

## 8. Orden de ejecución

1. **Fase 0 (preparación):** crear plan, arnés chain/load/report, slo-exporter, dashboard/alerts, CI. Todo sin ejecutar contra worker ausente.
2. **Gate check G-B1..G-B6:** si alguno rojo → parar y reportar bloqueos.
3. **Fase 2:** S3-P4-01 → S3-P4-02 → S3-P4-03.
4. **Fase 3:** S5-P4-01 (1000) + reporte.
5. **Fase 4:** S5-P4-03 (exporter, dashboard, alertas). Medición parcial aceptada; cierre tras 24h.
6. **Fase 5:** S5-P4-02 (24h host dedicado).
7. **Fase 6:** Extras + evidencia completa.
