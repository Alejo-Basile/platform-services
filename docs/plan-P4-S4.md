# Plan P4 — Semana 4

**Owner:** P4 (Integración y Calidad)
**Alcance:** tareas P4 de S4 (`S4-P4-01..05`).
**Estado de este documento:** plan vivo; se actualiza al cerrar cada gate.
**Premisa:** sin worker real no se cierran los caos que exigen `COMPLETED`; no se usan mocks.

## 1. Decisiones de alcance

| Tema | Decisión |
|---|---|
| Alcance | Solo P4; no incluye worker, reconciliador ni endpoints de P2/P3 |
| Ejecución | Primero los caos parciales que no requieren worker; el resto queda `BLOQUEADO` |
| Caos 1 | “Redis caído + `SIGKILL` de doc-service”: la caída entre webhook y `XADD` se fuerza dejando Redis caído y matando el proceso; no se añaden failpoints al código |
| Caos 3 | Redis caído 300 s por defecto en la corrida manual y 60 s en el nightly; el arnés admite una duración menor solo para desarrollo |
| Reconciliador | Se puede forzar con `created_at`/`updated_at` retrasados y `POST /internal/reconcile` para no esperar el ciclo |
| Worker ausente | No se simula; `S4-P4-02/04` y el cierre `COMPLETED` quedan `BLOQUEADOS` |
| Evidencias | `docs/evidencias/S4/`; los artefactos de CI no sustituyen la evidencia versionada |

## 2. Estado real de partida

Auditoría de `main` al 2026-10-27.

| Área | Estado | Impacto en S4-P4 |
|---|---|---|
| `platform-services` | PR #6 mergeada (`0ca65b9`): arnés con `KNOWN`, `P4_STRICT_RELAY`, `lib.sh` y workflow corregido | Base actualizada del arnés de caos |
| `infra` | Redis Sentinel y webhook disponibles; `S4-P1-01` mergeado (`b21250a`); sin servicio worker | Caos 3 parcial; caos 2/4 bloqueados |
| `doc-service` | Reconciliador, relay con backoff, lease, historial y endpoints internos en `main` | Caos 1/3 ejecutables hasta cola |
| `extraction-worker` | Consumidor, DLQ y `XAUTOCLAIM`; PR #11 (extracción real) y #17 (Mongo/`COMPLETED`) aprobadas, sin mergear | No hay cadena real ni `COMPLETED` |
| `S4-P2` | Implementación y tests presentes, sin auditoría de cierre | Debe auditarse antes de declarar el caos 1 cerrado |
| `S4-P1-01` | Escalado horizontal con 2 réplicas **HECHO** (evidencia `infra/docs/evidencias/S4/S4-P1-01-escalado.txt`) | Habilita caos 1 con concurrencia real; limitación: imagen local, deploy GHCR bloqueado |
| `S4-P1-02/03` | Métricas y alertas de negocio pendientes | No bloquean el arnés, sí el cierre operativo |
| `S3-P4-03` | `BLOQUEADA` por worker y G-C | Bloquea el cierre de `S4-P4-05` |
| `S4-P3-01..04` | Replay, métricas, `min-idle-time` y drenaje pendientes | Afectan la validez de caos 2/3 completos |

## 3. Gates

| Gate | Criterio | Owner | Estado |
|---|---|---|---|
| **G-B — Worker real** | Extracción real, `.txt` en MinIO, `COMPLETED` y servicio en Compose | P3/P1 | Bloqueado |
| **G-C — Correctitud** | TTL, transiciones, correlación y `/readyz` cerrados | P2 | Parcial |
| **S4-P2 — Auditoría** | Tests y código de reconciliación/relay/endpoints verificados contra el DoD | P2/P4 | Pendiente |
| **S4-P1-01** | 2 réplicas del doc-service y 50/50 mensajes sin duplicados | P1 | Hecha (PR infra #32; imagen local) |
| **G-E — Caos** | Caos 1/3 parciales verdes y evidencia; caos 2/4 con worker | P4 | Parcial verde (run 40135424950, 40609491183) |

**Regla:** un caos solo se marca `HECHO` si su DoD completo se ejecutó. Hasta entonces se registra `PARCIAL` o `BLOQUEADO`.

## 4. Tareas

### S4-P4-01 — doc-service cae entre webhook y XADD

**Depende de:** `S2-P2-06`, G-B, G-C, S4-P2 auditado.
**Estado:** **PARCIAL EJECUTADO** (variante Redis caído + SIGKILL, CI 40135424950; escenario real CI 40609491183, 10/10 sin pérdida ni duplicados, 1/10 ventana). El cierre con `COMPLETED` sigue `BLOQUEADO` por G-B.

**Inyección real (sin failpoints):**

1. Redis arriba.
2. Crear y subir un PDF válido.
3. Enviar `SIGKILL` al doc-service inmediatamente después del upload.
4. Reiniciar el doc-service y esperar `/healthz`.
5. Leer el estado post-reinicio: `PENDING_UPLOAD` (el webhook no llegó), `UPLOADED` (ventana webhook → XADD) o `QUEUED` (el `XADD` ya se hizo).
6. Esperar exactamente una entrada en el stream. Si falta, intentar reconciliación como diagnóstico y reportar `KNOWN`/`FAIL` según `P4_STRICT_RELAY`.
7. Repetir N veces y registrar la cobertura real (`webhook->XADD`, `webhook-perdido`, `ya-encolado`, `reconciler-forzado`).

**Variante:** `--chaos1-kill` conserva el escenario anterior (Redis caído + `SIGKILL`).

**Asertos parciales:**

- El documento existe tras el kill y el reinicio.
- El stream contiene exactamente un mensaje para el `document_id` tras la recuperación.
- No hay mensajes duplicados en ninguna de las N repeticiones.
- Si el documento quedó `UPLOADED` y el relay no reencola, se reporta `KNOWN-ISSUE` con doc-service#55; no se cuenta como fallo parcial.
- `P4_STRICT_RELAY=1` convierte ese `KNOWN-ISSUE` en fallo, para cuando se corrija el relay.
- El `reconcile` forzado se registra como diagnóstico, no como operación de producción.

**Asertos completos (bloqueados):**

- El documento converge a `COMPLETED` por relay o reconciliación.
- El `.txt` existe y la descarga funciona.
- `status_history` conserva actor y `correlation_id`.

**Evidencia:** `docs/evidencias/S4/S4-P4-01-caos-doc-service.txt`.

### S4-P4-02 — El worker muere a mitad de extracción

**Depende de:** `S1-P3-05`, G-B, `S4-P3-03`, `S4-P3-04`.
**Estado:** **BLOQUEADA**.

**Procedimiento futuro:**

1. Levantar dos workers reales sobre el mismo grupo de consumo.
2. Hacer `kill -9` al worker que tenga el mensaje en `PROCESSING`.
3. Verificar que el otro worker lo reclama con `XAUTOCLAIM` después de `min-idle-time`.
4. Comprobar un único `.txt`, un único `COMPLETED` y ausencia de duplicados.
5. Repetir 3 veces; si es flaky, no se cierra.

**DoD:** el documento termina en `COMPLETED` sin pérdida ni duplicados.

**Evidencia:** `docs/evidencias/S4/S4-P4-02-caos-worker.txt`.

### S4-P4-03 — Redis de Streams caído 5 minutos

**Depende de:** `S1-P1-08`, G-B.
**Estado:** **PARCIAL EJECUTADO** (CI 40135424950); el cierre con `COMPLETED` y la pérdida por réplica asíncrona están `BLOQUEADOS`.

**Procedimiento parcial:**

1. Crear y subir dos documentos con Redis arriba; confirmar dos entradas en el stream.
2. Detener Redis durante `P4_CHAOS_REDIS_SECONDS` (300 s por defecto).
3. Durante la caída, subir un tercer documento; debe quedar en `UPLOADED` y el relay fallar sin perder el evento.
4. Levantar Redis y esperar `PONG`.
5. Confirmar que las dos entradas previas siguen en el stream y que el tercer documento se encola.
6. Medir `recuperados` y `preservados`; registrar la duración real.

**Asertos parciales:**

- Cero documentos perdidos: los tres tienen estado/entrada verificable.
- El stream no duplica mensajes.
- El relay o el reconciliador recupera el documento que falló durante la caída.
- La caída no deja servicios en estado inconsistente.

**Asertos completos (bloqueados):**

- Con worker real, los tres documentos terminan en `COMPLETED`.
- Se mide cuántos mensajes se perdieron con la réplica asíncrona y cuántos recuperó el reconciliador.
- Se usa el runbook de failover Redis de P1, si existe.

**Evidencia:** `docs/evidencias/S4/S4-P4-03-caos-redis.txt`.

### S4-P4-04 — Mongo caído durante el paso 5

**Depende de:** `S2-P3-09`, G-B.
**Estado:** **BLOQUEADA**.

**Procedimiento futuro:**

1. Ejecutar la cadena real hasta que el worker haya subido el `.txt`.
2. Detener Mongo antes de escribir `COMPLETED`.
3. Verificar la compensación: el `.txt` se elimina o queda registrado como huérfano.
4. Recuperar Mongo y ejecutar el reconciliador.
5. Comprobar que no hay `.txt` huérfano ni documento atascado.

**DoD:** compensación ejecutada, sin `.txt` huérfano y sin estado no terminal.

**Evidencia:** `docs/evidencias/S4/S4-P4-04-caos-mongo.txt`.

### S4-P4-05 — Guía de documentos atascados

**Depende de:** `S3-P4-03`, G-B.
**Estado:** **BORRADOR POSIBLE**, validación real `BLOQUEADA`.

**Contenido mínimo:**

1. Consulta en Mongo por `document_id`, estado, `updated_at`, `expires_at` y `status_history`.
2. Consulta de la entrada en Redis Streams, PEL, consumer group y DLQ.
3. Verificación del objeto en `raw-pdfs` y `extracted-txt`.
4. Árbol de decisión: reencolar, reintentar, cancelar, esperar TTL o escalar.
5. Acciones prohibidas: borrar documentos o `.txt` a mano sin evidencia.
6. Enlace a los runbooks de P1 aplicables.

**DoD:** una persona que no escribió el código sigue la guía y resuelve un caso real de `PROCESSING` viejo.

**Evidencia:** `docs/evidencias/S4/S4-P4-05-runbook.txt` + caso resuelto.

## 5. Arnés de caos parcial

**Ubicación:** `tests/e2e/chaos/run.sh`.
**Stack:** ya levantado, igual que `tests/e2e/errors/run.sh`; no levanta ni baja el stack completo.
**Aislamiento:** `P4_COMPOSE_PROJECT`; `trap` restaura Redis y doc-service siempre.

```bash
# Los tres casos; Redis 300 s y 10 repeticiones del caos 1 real
tests/e2e/chaos/run.sh --all

# Solo caos 1 real (ventana webhook -> XADD)
tests/e2e/chaos/run.sh --chaos1

# Variante Redis caído + SIGKILL
tests/e2e/chaos/run.sh --chaos1-kill

# Solo caos 3, duración explícita para desarrollo
P4_CHAOS_REDIS_SECONDS=10 tests/e2e/chaos/run.sh --chaos3

# Menos repeticiones para desarrollo
P4_CHAOS1_RACE_RUNS=3 tests/e2e/chaos/run.sh --chaos1

# Cuando exista worker real: exige COMPLETED y falla si no converge
tests/e2e/chaos/run.sh --all --full
```

**Salida:** `PASS`, `FAIL`, `BLOCKED` y `KNOWN`; exit 1 solo si falla un aserto parcial o si `P4_STRICT_RELAY=1` y el relay no recupera. `BLOCKED` no hace fallar el job; los bloqueos de worker y caos 2/4 quedan cubiertos por platform-services#5. `--full` convierte los bloqueos de worker en fallos.

**CI:** `workflow_dispatch` con 300 s después del smoke y `schedule` nocturno con 60 s. No corre en cada PR por la espera.

**Primera ejecución:** workflow `e2e` 40135424950, 10m39s, commit `2bc9d56`.
Resultado: `PASS=2 FAIL=0 BLOCKED=2`. Caos 1 y 3 recuperaron por el
reconciliador; el relay no reencoló en ninguno de los dos. Evidencias en
`docs/evidencias/S4/S4-P4-01-caos-doc-service.txt` y
`S4-P4-03-caos-redis.txt`.

El arnés actualizado (comparte `tests/e2e/lib.sh`, reporta `KNOWN` y admite
`P4_STRICT_RELAY=1`) quedó en `main` con la PR #6 (`0ca65b9`), pero todavía no
se ejecutó en CI; la próxima corrida `workflow_dispatch` debe guardar el
resumen nuevo.

Ejecución local del escenario real (2026-10-28):
`P4_CHAOS1_RACE_RUNS=10 tests/e2e/chaos/run.sh --chaos1` →
10/10 sin pérdida ni duplicados (cobertura dependiente de la carrera).

Ejecución CI (workflow_dispatch 40609491183, 2026-10-28):
`tests/e2e/chaos/run.sh --all` (P4_CHAOS1_RACE_RUNS=10) →
`PASS=3 FAIL=0 BLOCKED=3 KNOWN=3`. `S4-P4-01 real`: 10/10 sin pérdida ni
duplicados, cobertura `webhook->XADD=1`, `ya-encolado=9`,
`reconciliador-forzado=1`. La ventana fue alcanzada; el relay no reencoló
(doc-service#55) y el reconciliador lo recuperó. `S4-P4-01 variante` y
`S4-P4-03`: recuperados por reconciliador con `KNOWN-ISSUE`. `COMPLETED`
sigue `BLOQUEADO` por G-B.

`S4-P1-01` cerró con la PR infra #32 (`b21250a`): dos réplicas, 50 documentos,
50 mensajes y dedup verificado. La evidencia está en
`infra/docs/evidencias/S4/S4-P1-01-escalado.txt`; usó `doc-service:local` y el
deploy por imagen GHCR sigue bloqueado.

## 6. Matriz de ejecución

| Tarea | Ahora | Con G-B | Con G-C + S4-P2 | Evidencia |
|---|---|---|---|---|
| S4-P4-01 | Parcial ejecutado | Completa | Completa | `S4-P4-01-caos-doc-service.txt` |
| S4-P4-02 | Bloqueada | Completa | Completa | `S4-P4-02` |
| S4-P4-03 | Parcial ejecutado | Completa | Completa | `S4-P4-03-caos-redis.txt` |
| S4-P4-04 | Bloqueada | Completa | Completa | `S4-P4-04` |
| S4-P4-05 | Borrador | Validable | Completa | `S4-P4-05` |

## 7. Riesgos

| Riesgo | Mitigación |
|---|---|
| El relay no reanuda desde el resume token y el documento queda `UPLOADED` | Ocurrió en la primera ejecución; se reporta `KNOWN-ISSUE` (doc-service#55), se recupera por reconciliador y el arnés puede exigir el relay con `P4_STRICT_RELAY=1` |
| La caída de Redis no es exactamente “antes del XADD” | Es una inyección equivalente sin failpoints; se documenta la limitación |
| El caos 3 tarda 5 min y alarga CI | `workflow_dispatch` con 300 s y nightly con 60 s; duración configurable para desarrollo |
| El worker no llega | No se simula; caos 2/4 y cierres `COMPLETED` quedan bloqueados |
| Se confunde `PARCIAL` con `HECHO` | El resumen del arnés y la evidencia separan ambos estados |
| El reconciliador tarda 10 min | Se usa el endpoint interno con `created_at`/`updated_at` retrasados, sin esperar el ciclo real |
| El estado local no coincide con CI | Ejecutar el arnés en CI con secretos efímeros y documentar ambos resultados |

## 8. Orden de ejecución

1. Auditar S4-P2 y confirmar que reconciliador/relay/endpoints cumplen su DoD.
2. ~~Implementar y validar el arnés de caos 1/3 parcial.~~
3. ~~Ejecutar en CI manual y guardar evidencia.~~ (hecho en 40135424950)
4. Redactar el borrador de `S4-P4-05`.
5. Al llegar G-B y S4-P1-01: caos 2/4, cierre `COMPLETED` y validación real del runbook.
6. Actualizar este plan y las evidencias con cada gate.

## 9. Entregables

```text
platform-services/
├── docs/plan-P4-S4.md
├── docs/evidencias/S4/
│   ├── S4-P4-01-caos-doc-service.txt
│   ├── S4-P4-03-caos-redis.txt
│   ├── S4-BLOQUEOS.txt
│   ├── S4-P4-02-caos-worker.txt   # pendiente de G-B
│   ├── S4-P4-04-caos-mongo.txt    # pendiente de G-B
│   └── S4-P4-05-runbook.txt       # pendiente de S3-P4-03
└── tests/e2e/chaos/run.sh
```

## 10. Criterio de cierre de S4-P4

- Caos 1 y 3 ejecutados con su DoD completo, no solo parcial.
- Caos 2 y 4 ejecutados con worker real y sin duplicados/huérfanos.
- `S4-P4-05` validado por una persona distinta de quien lo escribió.
- Evidencias versionadas con fecha, commit, duración y resultado.
- Sin mocks ni estados no terminales al final del ciclo de reconciliación.
