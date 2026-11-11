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
- Una petición de bajo volumen a `GET /api/v2/documents/{id}` devolvió 200. El burst k6 point-read (100 VUs/100 requests) terminó con 25 respuestas 200, 75 respuestas 429 y checks 100% (exit 0). `http_req_failed=75%` es el contador k6 que clasifica 429 como fallo HTTP; no se usó como threshold porque 429 es el comportamiento esperado sobre el límite.
- El primer burst contra el endpoint de listado produjo 3 respuestas 500; los logs correlacionados mostraron `COLLSCAN` de 14.154 documentos y cancelación de handshake Mongo. Se repitió el burst sobre un documento por ID para aislar el rate-limit del scan del listado.
- No se ejecutó `tests/k6/ratelimit/run.sh`: ese runner apunta a `BASE_URL/check` en `127.0.0.1:8090`, mientras que el servicio está solo en la red interna y el criterio P4-06 es verificar el comportamiento a través del gateway. La prueba de gateway se ejecutó con un script temporal fuera del repositorio.
- **Worker, 100 documentos:** pendiente. No se ejecutó porque el webhook 401 impide promover documentos a `UPLOADED`.

## Dependencias aún pendientes para P4-07

Faltan las salidas de P2-02 (webhook perdido/reconciliador) y P3-05 (PDFs hostiles), además de P4-05 y la carga del worker. Esta evidencia es parcial y no cierra P4-07.

## Nota de entorno

Para poder arrancar el stack local se completaron variables ausentes en `infra/.env`, se sincronizaron valores locales con los archivos de secretos y se recreó únicamente `infra_mongo-data`, un volumen de prueba creado el 2026-10-21. El stack quedó levantado para continuar la verificación.
