# Informe de ejecución S0 — P4 (Integration & Quality)

- **Plan:** `platform-services/docs/plan-P4-S0-S1.md`.
- **Fecha:** 19/10/2026 (base) · 21/10/2026 (cierre de infraestructura y `S0-P4-05`).
- **Alcance ejecutado:** S0 completo salvo `S0-P4-01` y `S0-P4-07`; S1 se ejecutó y se reporta en `../S1/INFORME-EJECUCION.md`.
- **Regla aplicada:** lo que no se pudo verificar quedó `BLOQUEADA` o `HECHA PARCIAL` con causa;
  no se inventaron consumidores, fechas ni resultados.

## 1. Estado por tarea

| Tarea | Estado | Entregable / evidencia | Causa si no está cerrada |
|---|---|---|---|
| `S0-P4-01` Inventario de endpoints y clientes | **HECHA PARCIAL** | `docs/inventario-endpoints.md`, `docs/inventario-endpoints.csv` | Faltan access logs y datos de negocio para confirmar consumidores. El inventario técnico de rutas está completo y verificado contra la fuente del monolito. |
| `S0-P4-02` Línea base con k6 | **HECHA** (con limitaciones) | `tests/k6/baseline/*.js`, `tests/k6/baseline/run-baseline.sh`, `benchmarks/baseline/INFORME.md`, `resultados.csv`, JSON crudo comprimido, evidencias `S0-P4-02-*` | Medida local (Uvicorn + Mongo), no pila completa; `pdf_process` dominado por caché. Declarado en el informe. |
| `S0-P4-03` ADR-0001 y ADR-0002 | **HECHA** (propuestas) | `infra/docs/adr/ADR-0001-microservicios.md`, `ADR-0002-strangler-fig.md` | Estado `Propuesto`; falta revisión/aceptación de las 4 personas en G0. |
| `S0-P4-04` OpenAPI del doc-service | **HECHA** | `openapi/documents.yaml`; lint en `docs/evidencias/S0/S0-P4-04-openapi-lint.txt` | 2 warnings no bloqueantes (`no-server-example-com` por hosts de ejemplo). |
| `S0-P4-05` Arnés E2E smoke | **HECHA** | `tests/e2e/run.sh smoke`; evidencias `S0-P4-05-smoke.txt` y `S0-P4-05-minio-notify.txt` | — |
| `S0-P4-06` Paridad | **HECHA** (definición) | `docs/paridad.md` | La ejecución real de paridad requiere el doc-service y el worker; se hará en S2/S5. Faltan las 4 firmas de aceptación. |
| `S0-P4-07` Compatibilidad de clientes / ADR-0018 | **BLOQUEADA** | `docs/clientes.md` (parcial), `infra/docs/adr/ADR-0018-compatibilidad-clientes.md` (`Propuesto — BLOQUEADO`) | Sin access logs ni fecha de negocio. No se fijó un deadline inventado. |

## 2. Evidencia principal

- Inventario: `platform-services/docs/inventario-endpoints.md` y `.csv`.
- Línea base: `platform-services/benchmarks/baseline/INFORME.md` (+ `resultados.csv` y JSON gzip).
- Contrato: `platform-services/openapi/documents.yaml` + lint.
- Paridad: `platform-services/docs/paridad.md`.
- Clientes: `platform-services/docs/clientes.md`.
- ADRs: `infra/docs/adr/ADR-0001-microservicios.md`, `ADR-0002-strangler-fig.md`,
  `ADR-0018-compatibilidad-clientes.md`.
- Smoke: `platform-services/docs/evidencias/S0/S0-P4-05-smoke.txt` (`smoke` OK) y
  `S0-P4-05-minio-notify.txt` (suscripción efectiva `arn:minio:sqs:us-east-1:DOCSERVICE:webhook`).

## 3. Hallazgos que afectan el plan

1. **Duplicados del monolito:** un PDF repetido responde `200` con el texto cacheado, no `409`.
   El `409` solo aparece en la carrera de guardado. Inventario corregido.
2. **`chadbranch` no arranca:** el HEAD de la rama activa importa `EmptyInputDTO`, que ya no
   existe. La línea base se hizo sobre `main` (`830f5b1`) en un worktree temporal, sin modificar
   el repo del monolito.
3. **Límite de PDF:** el monolito acepta como máximo `26.214.399` bytes y rechaza exactamente
   `26.214.400` (25 MiB) con `400` porque usa `>= max_size`. El contrato v2 debe decidir el borde.
4. **Prerequisitos de infraestructura resueltos:** se generaron `.env`, keyfile y certificados
   autofirmados (no hay `mkcert` en el host). Además, el job `minio-notify-init` usaba
   `arn:minio:sqs::docservice:webhook` (minúsculas y sin región) mientras MinIO publica
   `arn:minio:sqs:us-east-1:DOCSERVICE:webhook`; la suscripción nunca se creaba y los webhooks
   no llegaban al `doc-service`. Corregido y verificado con `smoke` + `happy`.
   `gen-certs.sh` también tenía un `chmod` mal formado y exigía `mkcert`; ahora usa `openssl`
   como fallback y deja las claves en `644`, porque Traefik no puede leerlas en `600` en este
   entorno de Docker.
5. **Consumidores desconocidos:** no hay access logs; el inventario de clientes queda pendiente y
   ADR-0018 no puede fijar fecha.

## 4. Qué falta para cerrar S0 al 100%

| Pendiente | Owner sugerido | Desbloquea |
|---|---|---|
| Access logs y datos de negocio de consumidores | P1 / negocio | `S0-P4-01`, `S0-P4-07`, ADR-0018 |
| Revisar y aceptar ADR-0001/0002/0018 en G0 | P1–P4 | `S0-P4-03`, `S0-P4-07` |
| Firmar la definición de paridad | P1–P4 | `S0-P4-06` |
| Repetir línea base sobre la pila completa (opcional, recomendado) | P4 | Referencia S2/S8 más realista |

## 5. S1

S1 se ejecutó en la misma sesión: ADR-0005, núcleo GCRA (Go + Lua), 100 clientes concurrentes,
fuzzing de contrato y E2E parcial del camino feliz. El detalle y las evidencias están en
`platform-services/docs/evidencias/S1/INFORME-EJECUCION.md`. `S1-P4-04` sigue **BLOQUEADA**
para su DoD porque `S1-P3-02` (`extraction-worker`) no está implementado.
