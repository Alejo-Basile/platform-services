# Plan P4 — Semanas 2 y 3

**Owner:** P4 (Integración y Calidad)
**Alcance:** tareas P4 de S2 y S3 (`S2-P4-01..03`, `S3-P4-01..03`).
**Fechas:** flexibles; la ejecución se ordena por gates y dependencias.
**Estado de este documento:** plan vivo; se actualiza al cerrar cada gate.

## 1. Decisiones de alcance

| Tema | Decisión |
|---|---|
| Alcance | Solo P4; no incluye tareas de P1/P2/P3 |
| Calendario | Sin fechas rígidas; orden por gates |
| Correlación | Incluye al worker como componente obligatorio |
| E2E | Funcional en GitHub Actions con Docker Compose |
| Runbooks de infra | Owner P1; P4 verifica y los usa, no los redacta |
| Worker ausente | No se simula; la tarea dependiente queda `BLOQUEADA` |

## 2. Estado real de partida

Auditoría posterior al `pull` de `main` en los cuatro repos, 2026-10-24.

| Área | Estado | Impacto en P4 |
|---|---|---|
| `platform-services` | `main` en `4294956`; CI de lint/openapi verde | Base para el arnés y el workflow E2E |
| `infra` | `main` en `a7e44d0`; S3-P1-02 (#27) y S3-P1-03 (#31) fusionados | El stack `full` ya tiene doc-service y webhook aislado |
| `doc-service` | `main` en `210be28`; release #53 y anti-replay #52 fusionados | Última imagen funcional para E2E |
| `extraction-worker` | `main` en `b849e1d`; resiliencia/DLQ listos; **sin extracción real** | Bloquea S3-P4 completo |
| Worker en Compose | No existe servicio `extraction-worker` | Bloquea cadena real y CI E2E completo |
| TTL Mongo | Índice TTL sobre `expires_at` sin filtro por estado | Riesgo para k6 y matriz de estados |
| Correlación | S3-P1-03 verifica Traefik, doc-service, Mongo y Redis; **worker queda N/A** | S3-P4-02 debe ampliar el alcance |
| Runbooks | Faltan failover Redis, retry DLQ y desbloqueo de deployment | P1 los entrega; P4 verifica |
| Secretos locales | `infra/secrets/` vacío salvo `.gitkeep`; hay un `.env` local | Gate A debe generar secretos efímeros |

## 3. Gates

| Gate | Criterio | Owner | Estado |
|---|---|---|---|
| **G-A — Entorno** | Clones actualizados, secretos efímeros, Compose levanta y CI hace un smoke | P4 + P1 | Local OK; CI pendiente de push |
| **G-B — Worker** | Extracción real, `.txt` en MinIO, `COMPLETED` en Mongo y servicio en Compose | P3/P1 | Bloqueado |
| **G-C — Correctitud** | TTL corregido, transiciones completas, correlación conservada y `/readyz` real | P2 | Parcial |
| **G-D — CI** | Workflow E2E verde en PR y ejecución manual | P4 | Pendiente de G-A |

**Regla:** sin G-B no se ejecuta la cadena real. Sin G-C no se cierra S3-P4-03.

## 4. S2 — tareas

### S2-P4-01 — E2E de caminos de error

**Estado:** **HECHA parcial** — 7 casos control-plane verdes en local (se separó tamaño declarado y tamaño rechazado por MinIO); 3 casos worker-dependent `BLOQUEADOS` por G-B. El aserto de stream en local se omitió porque el Redis en ejecución no autentica con `infra/.env`; en CI es obligatorio.

**Depende de:** `S1-P4-04`, G-A, G-C.

**Escenarios:** PDF corrupto, PDF cifrado, PDF sin texto, tamaño excedido, MIME falso, cliente que nunca sube, MinIO caído, Redis caído y Mongo caído.

**Clasificación:**

| Grupo | Escenarios | ¿Ejecutable ahora? |
|---|---|---|
| Control-plane | tamaño excedido, MIME falso, nunca sube, MinIO/Redis/Mongo caídos | Sí, con asertos parciales |
| Worker-dependent | corrupto, cifrado, sin texto | No hasta G-B |

**Pasos:**

1. Implementar `tests/e2e/errors/` con un caso por escenario.
2. Usar un proyecto Compose aislado y `trap` para restaurar servicios caídos.
3. Asertar estado en Mongo, mensaje/ausencia en Redis, log identificable y limpieza.
4. Publicar 6 casos control-plane como `HECHOS` y 3 como `BLOQUEADOS` si G-B no está verde.

**DoD:** 9/9 con estado final esperado y log/alerta. La clasificación de bloqueo debe quedar en la evidencia.

**Evidencia:** `docs/evidencias/S2/S2-P4-01-errores.txt` + logs por caso.

### S2-P4-02 — k6 contra el stack nuevo

**Estado:** **HECHA con limitaciones**. 12 corridas API-level sin errores. `list` mejora la baseline; `health` por Traefik incumple la regla de regresión (p95 2,81×) y la prueba directa al doc-service confirma que el límite `cpus: 0.5` de Traefik es la causa principal. La imagen local se reconstruyó el 2026-10-25 desde `doc-service@210be28` (`doc-service:local`, ID `7ff6dec39c6f`); smoke, happy 1/1 y errores no-caos (`PASS=4 FAIL=0 BLOCKED=4 KNOWN=0`) quedaron verdes. Las 12 corridas k6 siguen pendientes de repetir con esta imagen; el CI debe repetir el smoke. Los k6 ya usan `rate==0`/`checks==1`, y `run-v2.sh` valida p95 de `list`; el p95 de `health` queda condicionado a P1. La cadena completa sigue `BLOQUEADA` por G-B.

**Depende de:** `S2-P2-05`, G-C.

**Alcance inicial:** health, creación, prefirma, estado y listado. La cadena completa se mide después de G-B.

**Pasos:**

1. Adaptar `tests/k6/baseline/` a `/api/v2`.
2. Ejecutar 3 corridas con warm-up, mismo host y mismos límites de contenedor.
3. Comparar p50/p95/p99, RPS y error rate contra `benchmarks/baseline/INFORME.md`.
4. Explicar diferencias por arquitectura asíncrona, prefirma, TTL y worker ausente.
5. Ejecutar k6 comparativo en host fijo; en CI solo un smoke de carga.

**DoD:** informe comparativo con baseline y diferencias explicadas. La cadena completa queda `BLOQUEADA` hasta G-B.

**Evidencia:** `benchmarks/v2/INFORME.md` + JSON crudo.

### S2-P4-03 — Runbooks v1

**Estado:** **BLOQUEADA** — faltan failover Redis, retry DLQ y desbloqueo de deployment; no hay runbooks P1 que verificar.

**Owner de contenido y ejecución:** P1.
**P4:** verificación y uso en E2E.

**Pasos de P4:**

1. Verificar que existan y estén ejecutados: restore Mongo, failover Redis, retry DLQ y desbloqueo de deployment.
2. Comprobar fecha, autor y evidencia de cada runbook.
3. Usarlos en los escenarios de caos y registrar cuál se usó y si funcionó.
4. Si falta uno, marcar `S2-P4-03` como `BLOQUEADA` y escalar a P1.

**DoD de P4:** checklist de completitud + evidencia de uso. El cierre formal del runbook es de P1.

**Evidencia:** `docs/evidencias/S2/S2-P4-03-runbooks.txt`.

## 5. S3 — tareas

### S3-P4-01 — E2E de cadena real

**Estado:** **BLOQUEADA** — no hay worker real ni servicio en Compose; no se implementa con mocks.

**Depende de:** G-B, G-D, `S1-P4-04`.

**Flujo:** crear → prefirmar → subir → webhook → relay → worker → extracción → `.txt` → `COMPLETED` → descarga.

**Pasos:**

1. Implementar `tests/e2e/chain/` y el comando `chain`.
2. Ejecutar en local y en GitHub Actions con Compose.
3. Verificar estado final, objeto `.txt`, URL de descarga y `status_history`.
4. Sin mocks; si falta el worker, el job falla explícitamente.
5. Recolectar logs y artefactos en fallo.

**DoD:** cadena real verde en CI y local, repetible.

**Evidencia:** `docs/evidencias/S3/S3-P4-01-e2e-real.txt` + artefactos de CI.

### S3-P4-02 — Correlación automatizada

**Estado:** **BLOQUEADA** — S3-P1-03 cubre Traefik/doc-service/Mongo/Redis y declara worker `N/A`; falta el worker y revisar que el webhook conserve el `correlation_id` del documento (hoy usa el de la request).

**Depende de:** `S3-P1-03`, G-C.

**Componentes obligatorios:** Traefik, doc-service y worker. Mongo se verifica además en `status_history`.

**Pasos:**

1. Partir de `infra/scripts/e2e-correlation.sh`; hoy reporta el worker como `N/A`.
2. Exigir el `correlation_id` en los logs del worker y en `status_history`.
3. Fallar si falta en cualquiera de los 3 componentes.
4. Mantener las pruebas de header inválido/ausente y el aislamiento de `/internal`.

**DoD:** test automatizado que falla si falta correlación en Traefik, doc-service o worker.

**Evidencia:** `docs/evidencias/S3/S3-P4-02-correlation.txt`.

### S3-P4-03 — Matriz de estados alcanzables

**Estado:** **BLOQUEADA** — depende de la cadena real y de G-C (TTL, transiciones y `/readyz`).

**Depende de:** `S3-P4-01`, G-C.

**Estados:** `PENDING_UPLOAD`, `UPLOADED`, `QUEUED`, `PROCESSING`, `RETRYING`, `COMPENSATING`, `COMPLETED`, `FAILED`, `REJECTED`, `UPLOAD_EXPIRED`.

**Pasos:**

1. Definir la matriz `(origen, evento, destino esperado)` en CSV/JSON.
2. Forzar cada camino de fallo.
3. Ejecutar un ciclo completo de reconciliación.
4. Verificar que ningún documento quede en estado no terminal.
5. Repetir 3 veces; si es flaky, no se cierra.

**DoD:** todos los escenarios terminan en `COMPLETED`, `FAILED`, `REJECTED` o `UPLOAD_EXPIRED`; cero no-terminales.

**Evidencia:** `docs/evidencias/S3/S3-P4-03-estados.txt` + matriz.

## 6. CI E2E con Compose

**Workflow:** `platform-services/.github/workflows/e2e.yml`.

**Triggers:**

- `pull_request` con cambios en `tests/**`, `openapi/**` o el workflow.
- `workflow_dispatch`.
- `schedule` nocturno para la cadena completa.

**Job:**

1. Checkout de `platform-services`, `infra`, `doc-service` y `extraction-worker` como hermanos.
2. Instalar Go y Rust; configurar Docker Buildx y caché.
3. Generar `infra/.env` y `infra/secrets/*` efímeros con `tests/e2e/ci/prepare-env.sh`.
4. Generar certificados con `infra/scripts/gen-certs.sh`.
5. Construir imágenes locales de `doc-service` y, cuando exista, `extraction-worker`.
6. Levantar servicios explícitos, sin monolito ni observabilidad.
7. Añadir `api.localhost` y `s3.localhost` a `/etc/hosts`.
8. Esperar healthchecks y `/readyz`.
9. Ejecutar `smoke`; luego `errors` y `chain` cuando sus gates estén verdes.
10. En fallo, volcar `docker compose ps`, logs y estado de Mongo/Redis/MinIO.
11. En `always()`, `docker compose -p p4-e2e down -v`.

**Restricciones:**

- `timeout-minutes: 40` y `concurrency` para cancelar ejecuciones viejas.
- Sin secretos reales; todos los valores son aleatorios por ejecución.
- No usar `--profile full` para evitar el monolito.
- Los artefactos de CI no sustituyen la evidencia versionada.

## 7. Dependencias y bloqueos

| Bloqueo | Owner | Tarea afectada |
|---|---|---|
| Worker real y servicio Compose | P3/P1 | S2-P4-01 completo, S3-P4-01/02/03 |
| TTL de `expires_at` | P2 | S3-P4-03 (no afectó las corridas cortas de S2-P4-02) |
| Transiciones completas | P2 | S3-P4-03 |
| Correlación en webhook | P2 | S3-P4-02 |
| `/readyz` real | P2/P1 | Estabilidad E2E |
| Runbooks de infra | P1 | S2-P4-03 |
| Secretos de `infra/secrets/` | P1/P4 | G-A |

## 8. Riesgos

| Riesgo | Mitigación |
|---|---|
| Worker no llega | Gate G-B; plan B sin mocks; escalar |
| TTL borra documentos en k6 | No afectó corridas de 45 s; sigue bloqueando S3-P4-03 |
| E2E flaky por change stream en frío | Warm-up y espera explícita del watcher |
| Compose en CI lento/inestable | Spike temprano, caché, healthchecks y logs en fallo |
| Correlación sin worker | Incluirlo en el DoD y actualizar la evidencia de S3-P1-03 |
| Runbooks P1 incompletos | P4 verifica y bloquea S2-P4-03 |
| Comparación k6 inválida | Host fijo, 3 corridas, mismos límites; imagen local reconstruida el 2026-10-25 y k6 pendiente de repetir |
| Health por gateway lento | Traefik `cpus: 0.5`; prueba con 2 CPUs mejora de 172 a 338 RPS. P1 decide el límite y se repite |

## 9. Entregables

```text
platform-services/
├── .github/workflows/e2e.yml
├── docs/plan-P4-S2-S3.md
├── docs/evidencias/S2/
├── docs/evidencias/S3/
├── benchmarks/v2/
└── tests/
    ├── e2e/ci/prepare-env.sh
    ├── e2e/errors/
    ├── e2e/chain/
    └── k6/v2/
```

## 10. Orden de ejecución

1. G-A: actualizar clones, preparar secretos efímeros y validar Compose.
2. Implementar el workflow E2E y un smoke mínimo.
3. S2-P4-01 control-plane y S2-P4-02 API-level.
4. Verificar runbooks de P1 y usarlos en E2E.
5. G-B: worker real + servicio Compose.
6. S3-P4-01, S3-P4-02 y S3-P4-03 en ese orden.
7. Cierre S2/S3 con informes y evidencias.
