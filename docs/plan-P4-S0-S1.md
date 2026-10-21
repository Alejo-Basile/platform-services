# Plan de Acción — P4 (Integración y Calidad) — S0 y S1

> **Contexto:** plan operativo de P4 para la Semana 0 (28/09 – 02/10) y la Semana 1
> (05/10 – 09/10). Deriva de `doc-service/docs/pasos-iniciales.md` (§2, §5.5, §6.1, §6.6),
> del SDD `doc-service/docs/SPEC.md` v2.1 y del estado real verificado en `infra/` y
> `doc-service/`.
>
> | Campo | Valor |
> |---|---|
> | Rol | P4 — Integration & Quality Engineer |
> | Repo principal | `platform-services/` |
> | Repos que toca | `infra/` (ADRs globales), `doc-service/` y `extraction-worker/` (contratos y E2E) |
> | Objetivo S0 | Inventario, línea base, contrato OpenAPI, arnés E2E, definición de paridad y ADR-0018 |
> | Objetivo S1 | Decisión de rate limiting, núcleo atómico en Lua, fuzzing de contrato y E2E del camino feliz |
> | Puertas | **G0** al cierre de S0 · checkpoint informal al cierre de S1 |
> | Fuente de verdad | `doc-service/docs/pasos-iniciales.md` y `doc-service/docs/SPEC.md` v2.1 |

---

## 1. Rol de P4 en S0 y S1

P4 no es "QA al final". En S0 construye la capacidad de medir y comparar antes de tocar el
monolito: inventario de endpoints, línea base de rendimiento, contrato OpenAPI, arnés E2E y el
criterio de paridad. En S1 entrega la base del rate limiting distribuido y el primer E2E real.

El `rate-limiter` completo, las reglas Strangler, el canary y el cutover son **S7–S10**. En S0 y
S1 solo se prepara su base:

- S0: contrato que el `rate-limiter` consumirá y arnés de pruebas.
- S1: decisión de algoritmo y núcleo atómico en Redis, no el servicio ForwardAuth completo.

---

## 2. Estado de partida y supuestos

| Elemento | Estado al iniciar el plan | Implicación |
|---|---|---|
| `platform-services/` | README, CI mínima, CODEOWNERS y plantillas; sin código ni tests | P4 parte de cero en `openapi/`, `tests/` y `rate-limiter/` |
| `infra/` | Compose `core`/`full`, Traefik, MinIO, Redis, Mongo y observabilidad operativos | El arnés E2E puede apoyarse en el stack real |
| `doc-service/` | S0 de P2 cerrado; API, webhook y relay con avance | El contrato y el fuzzing se prueban contra código real |
| `extraction-worker/` | Sin implementación al iniciar el plan | `S1-P4-04` puede quedar **BLOQUEADA** si `S1-P3-02` no está `HECHA` |
| Monolito | No está dentro de este workspace | `S0-P4-01` y `S0-P4-02` requieren acceso al repo, imagen o URL del monolito |
| Puertos | Configurables por `.env` (`TRAEFIK_HTTP_PORT`, `TRAEFIK_HTTPS_PORT`) | No hardcodear `80/443` ni `8088/8543`; leer la configuración vigente |
| Host S3 | `MINIO_PUBLIC_ENDPOINT` definido en `infra/.env` | El E2E debe usar el host público, nunca `minio:9000` para la subida |

**Regla:** si falta un prerequisito, la tarea se marca `BLOQUEADA` con causa y owner. No se
inventan resultados, no se simula la línea base y no se cierra un DoD con un stub.

---

## 3. Reglas de ejecución

1. **Definition of Ready:** ID, owner, criterio verificable, dependencia `HECHA` y entorno
   disponible. Si no, `BLOQUEADA`.
2. **Definition of Done:** cambio en `main`, CI verde, evidencia reproducible, rollback escrito
   y documentación/ADR actualizada.
3. **Ramas:** `feat/platform-*`, `fix/platform-*`, `docs/platform-*` o `test/platform-*`; vida
   máxima 2 días. PR con *qué cambia · por qué · cómo se prueba · cómo se revierte*.
4. **ADRs globales:** viven en `infra/docs/adr/` y las revisan las 4 personas. P4 las redacta y
   abre el PR en `infra/` (co-owner P1 + P4).
5. **Evidencias:** `platform-services/docs/evidencias/S0/` y `.../S1/`. Cada archivo incluye
   comando, salida y fecha. Los resultados grandes van en JSON versionado, no solo en capturas.
6. **Sin secretos:** solo `.env.example`; ninguna credencial real en comandos, logs o evidencias.
7. **Aislamiento:** todo test que levante el stack usa un nombre de proyecto Compose propio
   (`-p p4-e2e`) para no borrar volúmenes compartidos.
8. **Alcance:** no adelantar tareas de S2 ni de S7. Si aparece una necesidad de S7, se registra
   como nota de diseño, no se implementa "a medias" en S1.

---

## 4. Semana 0 — Cimientos de integración y calidad

### 4.1 Calendario día a día

| Día | Foco de P4 | Tareas | Hito |
|---|---|---|---|
| **Lun 28/09** | Leer SPEC y arquitectura; preparar inventario; confirmar accesos | Prerrequisitos de `S0-P4-01`; plantillas de evidencia | Preguntas abiertas y accesos resueltos |
| **Mar 29/09** | Inventario de endpoints y clientes | `S0-P4-01`; inicio de `S0-P4-04` | Inventario completo con destino asignado |
| **Mié 30/09** | Línea base del monolito | `S0-P4-02`; revisión del contrato con P2 | Línea base publicada |
| **Jue 01/10** | ADRs y arnés E2E | `S0-P4-03`, `S0-P4-05` | ADR-0001/0002 aceptadas; `run.sh smoke` funcionando |
| **Vie 02/10** | Paridad, compatibilidad de clientes y cierre G0 | `S0-P4-06`, `S0-P4-07`, cierre de `S0-P4-04` | G0 de P4 listo |

> El calendario original ubica el inventario el martes y la línea base el miércoles. La primera
> mañana se usa para resolver accesos y preparar el material, no para escribir resultados.

### 4.2 `S0-P4-01` — Inventario de endpoints del monolito y de sus clientes

**Día:** Mar 29/09 · **Prioridad:** P0 · **Depende de:** `S0-P1-01` y acceso al monolito.

**Pasos:**

1. Obtener las rutas del monolito desde su fuente real: `GET /openapi.json` si es FastAPI, el
   router del repo si el código está disponible, y los access logs para detectar rutas no
   documentadas.
2. Completar una fila por endpoint con: método, ruta, request, response, autenticación, errores,
   quién lo consume y destino en la arquitectura nueva (`doc-service`, `worker`, `se elimina`
   o `queda en el monolito`).
3. Cruzar cada endpoint con los clientes que lo consumen usando access logs y código de los
   clientes. Registrar el cliente, su responsable y la frecuencia de uso.
4. Revisar el inventario con P2 (contrato) y con el negocio (clientes). Las rutas dudosas se
   marcan `PENDIENTE DE DECISIÓN`, no se inventa un destino.

**Artefactos:**

- `platform-services/docs/inventario-endpoints.md`: tabla legible y decisiones.
- `platform-services/docs/inventario-endpoints.csv`: misma información para conteos y diffs.
- `platform-services/docs/clientes.md`: semilla del inventario de clientes de `S0-P4-07`.

**DoD:**

- Todas las rutas del monolito están inventariadas.
- El 100 % tiene destino asignado.
- Cada endpoint tiene al menos un consumidor identificado o la marca explícita `sin consumidor`.
- P2 y P1 revisaron el inventario.

**Evidencia:** commit del inventario + salida del conteo de rutas (por ejemplo,
`wc -l inventario-endpoints.csv`) en `docs/evidencias/S0/`.

**Rollback:** solo documentación; `git revert` del commit.

**Riesgo:** sin acceso al monolito la tarea queda `BLOQUEADA`. No se sustituye por una lista
inventada a partir del SPEC.

---

### 4.3 `S0-P4-02` — Línea base del monolito con k6

**Día:** Mié 30/09 · **Prioridad:** P0 · **Depende de:** `S0-P4-01`.

**Pasos:**

1. Crear escenarios k6 en `platform-services/tests/k6/baseline/`, uno por flujo del inventario.
   Usar un PDF de fixture pequeño y endpoints seguros; no ejecutar pruebas destructivas.
2. Medir p50, p95, p99, RPS sostenible, error rate y tamaño máximo de PDF aceptado. Para el
   tamaño máximo, subir de forma incremental hasta el rechazo y registrar el límite exacto y el
   código de respuesta.
3. Ejecutar cada escenario **3 veces** con calentamiento previo. Guardar la salida JSON cruda y
   el resumen. Documentar hardware, versión del monolito y configuración del entorno.
4. Congelar la versión de los escenarios y sus umbrales: serán la referencia de `S2-P4-02` y del
   replay de S8. Cambiar un escenario después invalida la comparación.

**Comandos de referencia:**

```bash
k6 run --out json=benchmarks/baseline/<escenario>.json tests/k6/baseline/<escenario>.js
```

**Artefactos:**

- `platform-services/benchmarks/baseline/<escenario>.json`
- `platform-services/benchmarks/baseline/INFORME.md`
- `platform-services/tests/k6/baseline/README.md` con el procedimiento y los prerequisitos.

**DoD:**

- Existe un informe versionado con p50/p95/p99, RPS sostenible, error rate y tamaño máximo.
- El informe incluye el entorno y las 3 ejecuciones, no solo el mejor resultado.
- Los escenarios quedan versionados y son reproducibles por otra persona.

**Evidencia:** `INFORME.md`, JSON crudo y salida de la ejecución en `docs/evidencias/S0/`.

**Rollback:** eliminar datos de prueba creados por el escenario; no borrar volúmenes compartidos.

**Riesgo:** sin monolito ejecutable no hay línea base. La tarea queda `BLOQUEADA` y G0 es
**No-Go** hasta resolverlo.

---

### 4.4 `S0-P4-03` — ADR-0001 y ADR-0002

**Día:** Jue 01/10 · **Prioridad:** P0 · **Depende de:** `S0-P4-01`.

**Pasos:**

1. Redactar `infra/docs/adr/ADR-0001-microservicios.md`: por qué microservicios y no un
   monolito modular. Incluir contexto, opciones descartadas, consecuencias y riesgos.
2. Redactar `infra/docs/adr/ADR-0002-strangler-fig.md`: por qué Strangler Fig y no big bang.
   Explicar la migración incremental, el costo de mantener dos caminos y la condición de
   apagado del monolito.
3. Presentar ambas en la revisión de arquitectura del miércoles. Incorporar observaciones y
   dejar el estado en `Aceptado`.

**DoD:** ambas ADRs aceptadas, con contexto, opciones descartadas y consecuencias; enlazadas
desde `infra/docs/adr/` y desde el README de `platform-services/`.

**Evidencia:** PR en `infra/` con las dos ADRs y el acta/nota de revisión.

**Rollback:** `git revert` del PR documental.

---

### 4.5 `S0-P4-04` — Contrato OpenAPI v2 inicial

**Día:** Mar–Jue (cierre jueves) · **Prioridad:** P0 · **Depende de:** `S0-P4-01`.

**Pasos:**

1. Crear `platform-services/openapi/documents.yaml` con:
   - `POST /api/v2/documents` → `201` con `document_id`, `upload_url`, `method`, `form_fields`,
     `required_headers` y `expires_in`.
   - `GET /api/v2/documents/{id}` → estado y `updated_at`.
   - `GET /api/v2/documents` → listado con paginación y filtros.
   - `GET /api/v2/documents/{id}/download` → URL prefirmada de lectura.
   - Errores con RFC 9457 (`application/problem+json`), autenticación, `X-Correlation-Id` y
     estados de la SAGA.
2. Validar el YAML con un linter de OpenAPI fijado por versión (Redocly, Spectral o el que se
   acuerde). Agregar el job a la CI de `platform-services/`.
3. Revisar con P2: el contrato es la fuente de verdad de la API, no una descripción posterior.
   Cualquier diferencia entre contrato e implementación se resuelve con PR, no con excepciones.

**DoD:** el YAML valida sin errores; los 4 endpoints están definidos; P2 lo acepta como fuente
de verdad; la CI falla si el contrato deja de validar.

**Evidencia:** salida del linter y enlace al PR de revisión con P2.

**Rollback:** `git revert`; la CI vuelve al estado anterior.

---

### 4.6 `S0-P4-05` — Arnés de pruebas E2E

**Día:** Jue–Vie · **Prioridad:** P1 · **Depende de:** `S0-P1-03`.

**Pasos:**

1. Crear `platform-services/tests/e2e/run.sh` con subcomandos (`smoke`, y más adelante
   `happy`). Debe levantar el stack con el perfil `full`, esperar los health checks con timeout,
   ejecutar el escenario y limpiar **siempre**, incluso si el test falla (`trap`).
2. Usar un proyecto Compose aislado (`-p p4-e2e`) y volúmenes propios. No ejecutar
   `docker compose down -v` sobre el proyecto compartido del equipo.
3. Reutilizar el script de P1 (`infra/scripts/e2e-01.sh`) como referencia para la subida
   prefirmada; el arnés de P4 agrega determinismo, repetición y limpieza.
4. En S0 el `smoke` valida lo que ya existe: salud de Traefik, respuesta del monolito por
   `api.localhost` y salud de MinIO por `s3.localhost`. No se simula un E2E del flujo v2 que
   todavía no existe.

**DoD:** `./tests/e2e/run.sh smoke` funciona desde un entorno limpio con un solo comando, deja
el entorno limpio y devuelve `0`; si falla, devuelve distinto de `0` y conserva logs útiles.

**Evidencia:** `docs/evidencias/S0/S0-P4-05-smoke.txt` con la salida completa.

**Rollback:** `docker compose -p p4-e2e down -v` (solo el proyecto aislado) y `git revert`.

---

### 4.7 `S0-P4-06` — Definición de paridad por resultado

**Día:** Vie 02/10 · **Prioridad:** P0 · **Depende de:** `S0-P4-02`.

**Pasos:**

1. Crear `platform-services/docs/paridad.md`. La paridad se define sobre el **texto extraído
   normalizado**, no sobre códigos HTTP, cuerpos ni tiempos: el camino v2 es asíncrono y sus
   respuestas son distintas por diseño.
2. Definir la normalización exacta: codificación UTF-8, normalización Unicode, saltos de línea,
   espacios repetidos, orden de lectura, separación entre páginas y tratamiento de cabeceras o
   pies de página.
3. Definir el veredicto y la tolerancia: cuándo dos textos son equivalentes, qué diferencia es
   aceptable y qué se considera divergencia. Guardar siempre el diff crudo para auditoría.
4. Validar el criterio con el corpus disponible y con P2/P3. Firmarlo las 4 personas. El corpus
   del replay de S8 debe producir el mismo veredicto con este documento.

**DoD:** documento firmado por las 4 personas, con normalización, tolerancia, ejemplos de
equivalencia y de divergencia; el criterio es reproducible sin intervención manual.

**Evidencia:** commit del documento con la firma/acuse de las 4 personas.

**Rollback:** `git revert` del documento; no afecta runtime.

**Riesgo:** una normalización demasiado agresiva oculta regresiones. El diff crudo y los casos
de ejemplo son obligatorios.

---

### 4.8 `S0-P4-07` — Estrategia de compatibilidad de clientes (ADR-0018)

**Día:** Vie 02/10 · **Prioridad:** P0 · **Depende de:** `S0-P4-01`.

**Pasos:**

1. Partir del inventario de clientes de `S0-P4-01`: cliente, sistema, ruta usada, uso real
   medido en access logs, responsable y fecha de migración.
2. Redactar `infra/docs/adr/ADR-0018-compatibilidad-clientes.md` con la decisión **(b)
   migración de clientes con fecha límite**. Documentar como descartadas: (a) fachada síncrona
   permanente y (c) monolito solo para el flujo síncrono.
3. Incluir el plan operativo: comunicación a cada responsable, qué cambia en su integración,
   qué pasa con los que no migran (excepción firmada), y la condición técnica de apagado de v1:
   **0 tráfico a rutas legacy durante 7 días consecutivos**.
4. Obtener la fecha límite **por escrito con el negocio**. Si el negocio no está disponible, la
   ADR queda `BLOQUEADA`; no se inventa una fecha.

**DoD:** ADR-0018 aceptada, con la fecha acordada por escrito, inventario de clientes con
responsable y fecha, y consecuencias de las opciones descartadas.

**Evidencia:** ADR + inventario de clientes + acuse del negocio.

**Rollback:** `git revert` del PR documental.

---

### 4.9 Cierre de S0 — checklist de P4 para G0

- [ ] `S0-P4-01`: inventario completo y el 100 % con destino asignado.
- [x] `S0-P4-02`: línea base versionada con p50/p95/p99, RPS, error rate y tamaño máximo.
- [ ] `S0-P4-03`: ADR-0001 y ADR-0002 aceptadas.
- [x] `S0-P4-04`: OpenAPI v2 valida y P2 lo acepta como fuente de verdad.
- [x] `S0-P4-05`: `./tests/e2e/run.sh smoke` funciona y limpia.
- [ ] `S0-P4-06`: paridad firmada por las 4 personas.
- [ ] `S0-P4-07`: ADR-0018 aceptada con fecha límite escrita y clientes inventariados.
- [x] Evidencias de S0 publicadas en `platform-services/docs/evidencias/S0/`.

Si falta cualquiera de los puntos P0, **G0 es No-Go** para P4.

---

## 5. Semana 1 — Rate limiting base y primer E2E

### 5.1 Calendario día a día

| Día | Foco de P4 | Tareas | Hito |
|---|---|---|---|
| **Lun 05/10** | Comparar algoritmos de rate limit | `S1-P4-01` | Borrador de ADR-0005 |
| **Mar 06/10** | Fuzzing del contrato + preparación del núcleo Lua | `S1-P4-03`; esqueleto de `S1-P4-02` | Contrato fuzzeado; entorno Redis listo |
| **Mié 07/10** | Decisión de algoritmo y script atómico | `S1-P4-01` (aceptación), `S1-P4-02` | ADR-0005 aceptada; GCRA en Lua probado |
| **Jue 08/10** | Concurrencia y ajuste del rate limit | `S1-P4-02` (cierre), revisión con P1 | 100 clientes concurrentes sin exceder |
| **Vie 09/10** | E2E del camino feliz | `S1-P4-04` | 10/10 ejecuciones deterministas o tarea `BLOQUEADA` |

### 5.2 `S1-P4-01` — Decisión del algoritmo de rate limit

**Día:** Lun–Mié · **Prioridad:** P0 · **Depende de:** `S0-P4-04`.

**Pasos:**

1. Comparar **token bucket**, **sliding window log** y **GCRA** con: precisión, costo de
   memoria por identidad, comportamiento bajo ráfaga, atomicidad en Redis, operaciones por
   request y modos de fallo.
2. Escribir `infra/docs/adr/ADR-0005-rate-limiting.md` con la decisión y las opciones
   descartadas. Si la decisión es GCRA, dejar explícito el cálculo del `TAT` y el tiempo
   teórico de reintento.
3. Presentar en la revisión del miércoles y dejar el estado en `Aceptado` antes de escribir el
   código de producción.

**DoD:** ADR-0005 aceptada, con comparación cuantitativa y consecuencias operativas; el
algoritmo elegido es implementable con un único `EVAL` en Redis.

**Evidencia:** ADR-0005 en `infra/docs/adr/` y nota de revisión.

**Rollback:** `git revert` del PR documental.

---

### 5.3 `S1-P4-02` — Script Lua atómico

**Día:** Mié–Jue · **Prioridad:** P0 · **Depende de:** `S1-P4-01`.

**Pasos:**

1. Implementar el núcleo del `rate-limiter` en `platform-services/rate-limiter/` con:
   - un único script Lua que lea el tiempo del servidor Redis (`TIME`), actualice el estado y
     devuelva `allowed`, `remaining` y `retry_after`;
   - `EVAL` para incremento + expiración en una sola operación atómica;
   - TTL en la clave para no dejar contadores huérfanos.
2. Prohibido `INCR` seguido de `EXPIRE` desde el cliente: deja una ventana de inconsistencia.
3. Probar contra la instancia real `redis-ratelimit` del Compose. Incluir tests unitarios del
   cálculo y un test de concurrencia.
4. Ejecutar la prueba de carga: **100 clientes concurrentes sobre el mismo límite**; ninguno
   debe superar el límite configurado.

**Comandos de referencia:**

```bash
# Ajustar host/puerto/credenciales al .env vigente; nunca pegar secretos en la evidencia.
redis-cli -h <host> -p <puerto> --eval rate-limiter/internal/limiter/gcra.lua <clave> <params>
k6 run tests/k6/ratelimit/concurrency.js
```

**DoD:** 100 clientes concurrentes no superan nunca el límite; el conteo sigue siendo correcto
tras las expiraciones; no quedan claves de prueba; el script no usa `INCR` + `EXPIRE`.

**Evidencia:** `docs/evidencias/S1/S1-P4-02-lua-concurrency.txt` con el resumen de k6 y la
limpieza de claves.

**Rollback:** `FLUSHDB` solo en la instancia de rate limit aislada, o borrar las claves de
prueba por prefijo; detener el proceso de prueba. No tocar `redis-streams`.

---

### 5.4 `S1-P4-03` — Fuzzing de contrato

**Día:** Mar–Mié · **Prioridad:** P1 · **Depende de:** `S0-P4-04`.

**Pasos:**

1. Generar casos a partir de `openapi/documents.yaml` con una herramienta de fuzzing de
   contrato (Schemathesis o equivalente), fijada por versión en `tests/contract/`.
2. Ejecutar **1000 casos** contra el `doc-service` real por el gateway local. Un 400/401/404/413
   esperado es correcto; un **500 es un fallo**.
3. Triage: cada 500 se convierte en issue para P2 con request reproducible y `correlation_id`.
   No se baja el umbral ni se excluye el caso sin justificación escrita.
4. Agregar el job a la CI de `platform-services/` cuando el entorno de CI pueda levantar el
   stack; mientras tanto, documentar el comando local reproducible.

**DoD:** una ejecución de 1000 casos no encuentra ningún 500; los hallazgos están triados y
asignados; el comando queda versionado.

**Evidencia:** `docs/evidencias/S1/S1-P4-03-fuzz.txt` y reporte JSON.

**Rollback:** ninguno sobre runtime; los datos de prueba se limpian al finalizar.

---

### 5.5 `S1-P4-04` — E2E del camino feliz

**Día:** Vie 09/10 · **Prioridad:** P0 · **Depende de:** `S1-P1-04`, `S1-P2-06`,
`S1-P2-03` y `S1-P3-02`.

**Pasos:**

1. Extender `tests/e2e/run.sh` con el subcomando `happy`:
   - crear documento por la API v2;
   - obtener la URL prefirmada y subir el PDF **directo a MinIO** por el host público;
   - esperar el webhook y verificar `PENDING_UPLOAD → UPLOADED` en Mongo;
   - verificar el mensaje en `stream:pdf-processing` con el `document_id` correcto.
2. No usar mocks: MinIO, Redis, Mongo y el servicio real. Si el worker no está listo, el E2E
   puede verificar la cola, pero **no se cierra el DoD** de `S1-P4-04` sin la dependencia
   `S1-P3-02` `HECHA`.
3. Ejecutar el escenario **10 veces seguidas** desde un entorno limpio. Si una ejecución falla,
   conservar logs y no promediar el resultado.
4. Limpiar documento, objeto y mensaje de prueba con el `document_id` generado. Verificar que no
   quedan huérfanos.

**DoD:** el script pasa de forma determinista **10/10**, sin intervención manual, y deja el
entorno limpio.

**Evidencia:** `docs/evidencias/S1/S1-P4-04-e2e-10x.txt` con las 10 ejecuciones y la limpieza.

**Rollback:** borrar el documento y los objetos del `document_id` de prueba; `XDEL` del mensaje;
`docker compose -p p4-e2e down -v` solo si se usó el proyecto aislado.

**Bloqueo:** si `S1-P3-02` no está `HECHA`, la tarea queda `BLOQUEADA`. Se adelanta `S1-P4-02`
y `S1-P4-03`, no se simula el worker.

---

### 5.6 Cierre de S1 — checklist de P4

- [x] `S1-P4-01`: ADR-0005 aceptada.
- [x] `S1-P4-02`: script Lua atómico; 100 concurrentes sin superar el límite.
- [x] `S1-P4-03`: 1000 casos de fuzzing sin ningún 500.
- [ ] `S1-P4-04`: E2E del camino feliz 10/10 — **BLOQUEADA (DoD)** por `S1-P3-02`; el arnés valida 10/10 hasta `UPLOADED` + stream y limpia. Ver `docs/evidencias/S1/INFORME-EJECUCION.md`.
- [x] Evidencias de S1 publicadas en `platform-services/docs/evidencias/S1/`.
- [x] Sin tareas de S2/S7 adelantadas a medias.

---

## 6. Dependencias, bloqueos y plan B

| Tarea | Depende de | Si falta la dependencia | Plan B permitido |
|---|---|---|---|
| `S0-P4-01` | `S0-P1-01`, acceso al monolito | `BLOQUEADA` | Recolectar solo lo verificable desde access logs y marcar lo demás `PENDIENTE`; no inventar |
| `S0-P4-02` | `S0-P4-01`, monolito ejecutable | G0 No-Go | Ninguno: sin línea base no hay comparación válida |
| `S0-P4-03` | `S0-P4-01` | Avanzar con el SPEC y revisar después | ADR en estado `Propuesto` hasta la revisión |
| `S0-P4-04` | `S0-P4-01` | Usar el SPEC §11.2 como insumo, no como inventario | Contrato `0.x` hasta la revisión con P2 |
| `S0-P4-05` | `S0-P1-03` | Esperar el Compose o usar `core` para lo que no requiera gateway | Smoke mínimo contra perfiles disponibles |
| `S0-P4-06` | `S0-P4-02` | Documentar el criterio, pero no firmarlo como válido sin baseline | Revisión técnica con P2/P3 |
| `S0-P4-07` | `S0-P4-01`, negocio | ADR `BLOQUEADA` | Escalar a P1/sponsor; no fijar fecha inventada |
| `S1-P4-01` | `S0-P4-04` | Trabajar con el borrador del contrato | Decisión provisional, no aceptada |
| `S1-P4-02` | `S1-P4-01`, `redis-ratelimit` | Implementar el cálculo y probar con Redis local aislado | No cerrar DoD sin Redis real |
| `S1-P4-03` | `S0-P4-04`, doc-service levantado | Ejecutar contra el contrato con un servidor de prueba | Reportar como parcial; no declarar 1000 casos |
| `S1-P4-04` | `S1-P1-04`, `S1-P2-06`, `S1-P2-03`, `S1-P3-02` | `BLOQUEADA` | Adelantar `S1-P4-02`/`S1-P4-03`; nunca simular el worker |

---

## 7. Riesgos de P4 en S0 y S1

| Riesgo | Prob. | Impacto | Mitigación |
|---|---|---|---|
| Sin acceso al monolito para inventario y baseline | Media | **Alto**: G0 No-Go | Confirmar acceso el lunes; escalar a P1/sponsor el mismo día |
| Línea base medida en un portátil ruidoso y no comparable | Alta | Medio | Documentar hardware y entorno; 3 ejecuciones; congelar escenarios |
| Contrato OpenAPI se desvía de la implementación de P2 | Media | Alto | Revisión conjunta y fuzzing; el contrato es la fuente de verdad |
| Fuzzing descubre 500 reales del doc-service | Media | Medio | Triage a P2 con request reproducible; no bajar el umbral |
| `S1-P4-04` bloqueado porque el worker no está listo | Alta | Alto | Adelantar `S1-P4-02`/`S1-P4-03`; declarar el bloqueo el lunes |
| ADR-0018 sin fecha del negocio | Media | **Alto**: G0 No-Go | Escalar a P1/sponsor; no inventar fecha |
| Herramientas (k6, Schemathesis, linter OpenAPI) no están en el bootstrap | Media | Medio | Documentar en `platform-services/README.md`; pedir a P1 que las agregue si son compartidas |
| Sobrecarga de tareas en S0 | Alta | Alto | Proteger `S0-P4-01` y `S0-P4-02`; el resto son documentos y arnés |
| Se adelanta el `rate-limiter` completo en S1 | Media | Medio | Guardarraíl: en S1 solo algoritmo + núcleo Lua; ForwardAuth completo es S7 |

---

## 8. Estructura de entregables

```text
platform-services/
├── openapi/
│   └── documents.yaml                  # S0-P4-04
├── benchmarks/
│   └── baseline/
│       ├── INFORME.md                  # S0-P4-02
│       └── <escenario>.json            # salida cruda de k6
├── rate-limiter/
│   └── internal/limiter/gcra.lua       # S1-P4-02
├── tests/
│   ├── e2e/run.sh                      # S0-P4-05 + S1-P4-04
│   ├── k6/baseline/                    # S0-P4-02
│   ├── k6/ratelimit/                   # S1-P4-02
│   └── contract/                       # S1-P4-03
├── docs/
│   ├── inventario-endpoints.md         # S0-P4-01
│   ├── inventario-endpoints.csv        # S0-P4-01
│   ├── clientes.md                     # S0-P4-01 / S0-P4-07
│   ├── paridad.md                      # S0-P4-06
│   └── evidencias/
│       ├── S0/
│       └── S1/
└── README.md                           # cómo ejecutar cada arnés

infra/docs/adr/
├── ADR-0001-microservicios.md          # S0-P4-03
├── ADR-0002-strangler-fig.md           # S0-P4-03
├── ADR-0005-rate-limiting.md           # S1-P4-01
└── ADR-0018-compatibilidad-clientes.md # S0-P4-07
```

---

## 9. Primeras tres acciones antes de escribir código

1. **Confirmar accesos:** repo/imagen/URL del monolito, `.env` de `infra/` y estado real de
   `S1-P3-02`. Esto decide si `S0-P4-01`, `S0-P4-02` y `S1-P4-04` arrancan o quedan bloqueadas.
2. **Publicar el tablero de P4:** las 11 tareas (`S0-P4-01..07`, `S1-P4-01..04`) con owner,
   dependencia, DoD y estado inicial `PENDIENTE` o `BLOQUEADA`.
3. **Crear los esqueletos documentales y de carpetas:** `docs/evidencias/S0|S1/`,
   `openapi/`, `benchmarks/baseline/`, `tests/` y los ADR en estado `Propuesto`. Sin secretos
   y sin resultados inventados.
