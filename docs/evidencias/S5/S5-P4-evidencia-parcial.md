# Evidencia parcial P4 — 2026-11-10

## Estado

La matriz k6 de API v2 y la verificación k6 del gateway rate-limit terminaron con código 0. La cadena E2E y la carga del worker no se consideran aprobadas: el webhook MinIO → doc-service devuelve HTTP 401 y deja documentos en `PENDING_UPLOAD`.

## P4-06 — k6 de doc-service

Comando: `bash tests/k6/v2/run-v2.sh` desde `platform-services`.

Resultado observado: 12/12 corridas (health, list, create y state; 3 por escenario) finalizaron con código 0. En todas las corridas `http_req_failed` fue 0% y los checks fueron 100%.

| Escenario | p95 run 1 | p95 run 2 | p95 run 3 | Umbral p95 del script |
|---|---:|---:|---:|---|
| health | 111.85 ms | 107.92 ms | 105.63 ms | No configurado |
| list | 121 ms | 122.8 ms | 124.09 ms | `< 252.6 ms` — pasó en las 3 |
| create | 130.33 ms | 140.53 ms | 133.31 ms | No configurado |
| state | 111.19 ms | 135.01 ms | 145.04 ms | No configurado |

El script escribe los detalles en `docs/evidencias/S2/` y los resúmenes/JSON en `benchmarks/v2/`. Esta corrida los actualizó localmente, pero se excluyen de este PR para no reemplazar evidencia histórica de S2; esta tabla conserva el resumen P4.

## P4-05 — E2E reducido

**Pendiente; no aprobado.** `tests/e2e/chain/run.sh` no alcanzó estados terminales y expiró durante el polling. Los logs de doc-service registraron `POST /internal/storage/events` con HTTP 401 (`webhook: token inválido o ausente`); los documentos observados permanecieron en `PENDING_UPLOAD`.

La documentación de MinIO indica que `auth_token` se envía exactamente como está configurado. El Compose actual proporciona el secreto sin el prefijo `Bearer ` (`infra/compose/docker-compose.yml:335`), mientras que doc-service acepta `Authorization: Bearer <secreto>` y compara el token extraído con `MINIO_WEBHOOK_SECRET` (`doc-service/internal/webhook/handler.go:119-136`). El wiring del token necesita corrección en el frente de infra antes de repetir la cadena. No se modificó código de infra ni doc-service desde P4.

Referencia: [MinIO Webhook Service Settings](https://minio.community/community/minio-object-store/reference/minio-server/settings/notifications/webhook-service.html) — `auth_token` se coloca exactamente en el header de autenticación; para Bearer debe incluirse el prefijo en el valor.

Por el mismo bloqueo, no se ejecutaron los casos no-PDF y extracción fallida/DLQ: no se podía validar correctamente el camino de webhook.

## P4-04/P4-06 — rate-limiter y gateway

- `go test ./...` pasó en `golang:1.24-alpine`; la imagen `ratelimitd:p4-04` se construyó y `/healthz` respondió `{"status":"ok"}`.
- P1-04/P1-05 quedaron integrados por `infra#44` (`214f124`): `ratelimitd` en Compose y middleware Traefik hacia `/check?key=api-v2&rate=10&burst=20`.
- `tests/k6/ratelimit/run-gateway.sh` hizo una petición bajo el límite a `GET /api/v2/documents/{id}` (200) y luego un burst point-read de 100 VUs/100 requests. En la corrida registrada: 46 respuestas 200, 54 respuestas 429, 0 inesperadas y checks 100% (exit 0). La proporción varía con la reposición del GCRA; los thresholds requieren observar ambos códigos y cero respuestas inesperadas. `http_req_failed=54%` es el contador k6 que clasifica 429 como fallo HTTP; no se usó como threshold porque 429 es el comportamiento esperado sobre el límite.
- El primer burst contra el endpoint de listado produjo 3 respuestas 500; los logs correlacionados mostraron `COLLSCAN` de 14.154 documentos y cancelación de handshake Mongo. Se repitió el burst sobre un documento por ID para aislar el rate-limit del scan del listado.
- `tests/k6/ratelimit/run.sh` se conserva para la prueba directa S1 de `/check`; P4-06 usa `tests/k6/ratelimit/run-gateway.sh` porque `ratelimitd` no publica el puerto 8090 en el host.
- El runner crea un documento de prueba y lo deja en `PENDING_UPLOAD` (no hace upload), por lo que también queda sujeto al webhook/TTL del stack.
- **Worker, 100 documentos:** pendiente. No se ejecutó porque el webhook 401 impide promover documentos a `UPLOADED`.

## Dependencias aún pendientes para P4-07

Faltan las salidas de P2-02 (webhook perdido/reconciliador) y P3-05 (PDFs hostiles), además de P4-05 y la carga del worker. Esta evidencia es parcial y no cierra P4-07.

## Nota de entorno

Para poder arrancar el stack local se completaron variables ausentes en `infra/.env`, se sincronizaron valores locales con los archivos de secretos y se recreó únicamente `infra_mongo-data`, un volumen de prueba creado el 2026-10-21. El stack quedó levantado para continuar la verificación.
