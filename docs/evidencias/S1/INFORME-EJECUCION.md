# Informe de ejecución S1 — P4 (Integration & Quality)

- **Plan:** `platform-services/docs/plan-P4-S0-S1.md` §5.
- **Fecha:** 21/10/2026.
- **Alcance ejecutado:** `S1-P4-01`, `S1-P4-02`, `S1-P4-03` y el alcance parcial de
  `S1-P4-04` (hasta `UPLOADED` + Redis Streams).
- **Regla aplicada:** no se simuló el worker ni se cerró un DoD sin su dependencia. Lo parcial
  queda marcado como tal y con causa.

## 1. Estado por tarea

| Tarea | Estado | Entregable / evidencia | Causa si no está cerrada |
|---|---|---|---|
| `S1-P4-01` Decisión de algoritmo | **HECHA** | `infra/docs/adr/ADR-0005-rate-limiting.md` (GCRA, `Aceptado`; acuse cruzado de P1 pendiente) | — |
| `S1-P4-02` Núcleo Lua atómico | **HECHA** | `rate-limiter/internal/limiter/gcra.lua`, `limiter.go`, `cmd/ratelimitd/main.go`; `S1-P4-02-go-test.txt`, `S1-P4-02-lua-concurrency.txt` | — |
| `S1-P4-03` Fuzzing de contrato | **HECHA** | `tests/contract/run.sh`, `tests/contract/requirements.txt`, `S1-P4-03-fuzz.txt`, `S1-P4-03-fuzz-report.json` | 1000 casos, 0 respuestas 500 |
| `S1-P4-04` E2E del camino feliz | **HECHA PARCIAL / BLOQUEADA (DoD)** | `S1-P4-04-e2e-10x.txt` (10/10 hasta `UPLOADED` + stream, limpieza verificada) | `S1-P3-02` (`extraction-worker`) no está implementado; no se valida `COMPLETED` ni el texto extraído |

## 2. Evidencia principal

- **ADR:** `infra/docs/adr/ADR-0005-rate-limiting.md`.
- **Rate limiter:** `platform-services/rate-limiter/` (módulo Go, Lua, tests y wrapper HTTP).
- **Tests Go:** `S1-P4-02-go-test.txt` — 6 tests, incluidos burst=1, burst=N, recarga tras
  intervalo, TTL y `retry_after`.
- **Concurrencia:** `S1-P4-02-lua-concurrency.txt` — 100 VUs, `rate=0.1`, `burst=1`;
  `allowed_total count=1`, `denied_total count=99`, checks 100 % OK; 0 claves `rl:*` al final.
- **Fuzzing:** `S1-P4-03-fuzz.txt` y `S1-P4-03-fuzz-report.json` — Schemathesis 4.32.2,
  4 operaciones × 250 casos = 1000, 0 respuestas 500. El comando queda versionado en
  `tests/contract/run.sh` y la versión en `tests/contract/requirements.txt`.
- **E2E:** `S1-P4-04-e2e-10x.txt` — create → presigned POST a MinIO público → webhook →
  `PENDING_UPLOAD → UPLOADED` → mensaje en `stream:pdf-processing`; 10/10 con el watcher ya
  estabilizado; limpieza: 0 documentos `p4-*`, 0 mensajes y 0 PDFs de prueba. En arranque en
  frío la primera ejecución puede perder su evento por la carrera descrita en el hallazgo #2;
  no se declara determinismo en frío.

## 3. Hallazgos

1. **Suscripción MinIO rota (corregida).** `infra/compose/minio/init-notifications.sh` construía
   `arn:minio:sqs::docservice:webhook` (minúsculas, sin región), pero MinIO publica
   `arn:minio:sqs:us-east-1:DOCSERVICE:webhook`. El evento nunca se suscribía y el webhook no
   llegaba al `doc-service`; todos los documentos quedaban en `PENDING_UPLOAD`. Corregido y
   verificado (ver `S0-P4-05-minio-notify.txt` y los 10 E2E).
2. **Carrera del change stream al reiniciar `doc-service`.** Tras un reinicio, el watcher
   invalidó el resume token, reinició el stream “fresco” y perdió un evento `UPLOADED` ocurrido
   durante la ventana. El documento quedó `UPLOADED` sin mensaje en Redis. Ocurrió una vez; las
   10 ejecuciones posteriores pasaron. Mitigación pendiente: el reconciler debe reencolar
   documentos `UPLOADED` sin mensaje, o el watcher debe arrancar desde una posición segura.
3. **Objeto marcador `raw-pdfs/`.** El reconciler lo cuenta como huérfano e intenta borrar
   `raw-pdfs/raw-pdfs/`, lo que devuelve `Access Denied` y ensucia los logs. No bloquea el E2E,
   pero conviene ignorar claves que terminan en `/` en el reconciler.
4. **Desviación de aislamiento.** El arnés usa el proyecto Compose existente `infra` en lugar de
   `-p p4-e2e`. No ejecuta `down -v`; solo hace `stop` de los servicios que levantó y nunca borra
   volúmenes. Se documenta para que el equipo decida si migra a un proyecto aislado.

## 4. Qué falta para cerrar S1-P4-04

| Pendiente | Owner sugerido | Desbloquea |
|---|---|---|
| Implementar `extraction-worker` (`S1-P3-02`) y publicar `COMPLETED` + texto extraído | P3 | `S1-P4-04` (DoD completo) |
| Extender `happy` para esperar `COMPLETED` y validar `GET .../download` | P4 | `S1-P4-04` |
| Acuse de revisión de ADR-0005 por P1 | P1 | Cierre formal de `S1-P4-01` |
| Mitigar la carrera del change stream y el objeto `raw-pdfs/` | P2 | Robustez de `S1-P4-04` y S3 |

## 5. Notas de reproducibilidad

- Go 1.24.4 (toolchain local en `/tmp/opencode/go`); `go-redis v9.7.3`.
- k6 v2.2.0; Schemathesis 4.32.2 en un venv temporal.
- Certificados autofirmados para `api.localhost` y `s3.localhost` (no hay `mkcert` en el host).
- El stack se levantó con el perfil `full`; `MONGO_APP_USER`, `REDIS_STREAMS_PASSWORD` y
  credenciales de MinIO se leen de `infra/.env` y no se escriben en las evidencias.
