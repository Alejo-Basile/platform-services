# platform-services

Servicios de plataforma y arnés de pruebas del proyecto de migración a microservicios.

> Especificación arquitectónica (fuente única de verdad): [`infra/docs/SPEC.md`](https://github.com/Alejo-Basile/infra/blob/main/docs/SPEC.md) v2.1

## Qué hace este repo

- **`rate-limiter/`** (Go, `ratelimitd`): rate limiting distribuido vía **ForwardAuth** de Traefik con conteo en Redis (**GCRA**). Responde 200/429 antes de que Traefik rutee — Opción B del SPEC §8 (el middleware nativo `RateLimit` de Traefik OSS es por instancia, no distribuido). Soporta **multi-identidad** (clave por identidad), **hot-reload** de política desde Consul (`configkv`), **registro en Consul** (`consulreg`) y **métricas Prometheus** en `/metrics`.
- **`slo-exporter/`** (Go): exportador Prometheus que expone métricas de documentos por estado desde MongoDB (`docservice_*`, p. ej. `docservice_docs_total`, `docservice_docs_non_terminal`). Útil para vigilancia de SLO del pipeline.
- **`openapi/`**: contrato OpenAPI v2 de la API (`documents.yaml`), validado con Redocly en CI.
- **`tests/`**: arnés de pruebas del pipeline — E2E, contrato, **k6**, carga, **caos**, **paridad de corpus** (replay de PDFs válidos/inválidos/escaneados/cifrados/grandes contra los caminos v1 monolito y v2, comparando el texto extraído normalizado — SPEC §13) y colecciones **Postman**.
- **`benchmarks/`**: datos e informes de benchmark (baseline, v2, S9).

## Qué NO hace este repo

- **No configura infraestructura**: compose, redes, Traefik y datos viven en `infra/`.
- **No implementa lógica de negocio del documento**: CRUD/SAGA es `doc-service/`; extracción es `extraction-worker/`.
- **No contiene secretos reales**: solo `.env.example` con valores ficticios (repo público).

## Estructura

```
rate-limiter/    # servicio ForwardAuth (Go) — GCRA, multi-identidad, hot-reload Consul, métricas
slo-exporter/    # exportador Prometheus de métricas doc-service (Mongo)
openapi/         # contrato OpenAPI v2 (documents.yaml)
tests/           # arnés: e2e, contract, k6, load, parity, postman, fixtures
benchmarks/      # datos e informes de benchmark (baseline, v2, S9)
docs/            # inventario de endpoints, paridad, clientes, planes P4, runbooks, evidencias
  runbooks/      # procedimientos operativos (failover, DLQ, restore, deployment, atascos)
  evidencias/    # evidencias de ejecución por spec (S0–S7)
  adr/           # ADRs locales (reservado; las globales van en infra/docs/adr/)
odd/             # especificaciones de tareas y evidencia (ODD)
```

## Cómo ejecutar y verificar

Calidad local (replica el CI):

```bash
make lint                # shellcheck + yamllint + bash -n
make test-rate-limiter   # go vet + go test del servicio rate-limiter
make test-e2e-smoke      # ./tests/e2e/run.sh smoke
```

Otros puntos de entrada frecuentes:

```bash
./tests/e2e/run.sh happy [--runs N --keep-stack]   # camino v2 hasta UPLOADED + mensaje en Redis
./tests/e2e/chaos/run.sh --all --full              # caos (S4)
python3 -m unittest discover tests/parity -v       # tests de paridad de corpus
npx @redocly/cli@2.66.1 lint openapi/documents.yaml
cd slo-exporter && go build ./...                  # sin tests aún
```

Los workflows de CI (`.github/workflows/`): `ci.yml` (lint + rate-limiter + openapi + imágenes), `e2e.yml`, `parity.yml`, `gitleaks.yml`.

## Estado actual

Madurez por componente:

| Componente / área | Estado |
|---|---|
| `rate-limiter` (S7) | Maduro — probado en vivo (GCRA, multi-identidad, hot-reload Consul, métricas); S7-P4-03/04/05 cerrados |
| Cadena de extracción / E2E (S1–S3) | Completo **localmente** (chain 10/10, correlación 5/5, matriz de estados 7/7); CI pendiente del PR abierto |
| Caos (S4) | Parcial — S4-P4-01/03/04 con evidencia; **S4-P4-02/05 sin cumplir** (reclaim no acepta `PROCESSING`; retry no reencola dentro de la ventana de dedup) |
| Paridad de corpus / replay (S8) | Tooling (normalize/compare/report + fixtures + CI) en `main`; corpus real en PR #19; canary 1% y alerta de divergencia pendientes |
| Carga / endurance / SLO (S5) | Pendiente (S5-P4-01/02/03; scripts k6/S9 en curso) |
| Rollback / migración / cutover (S9–S10) | Pendiente |
| `slo-exporter` | Temprano — compila, sin tests ni wiring de CI/Makefile |

> Detalle por spec/DoD (con evidencia y causas raíz): [`odd/tasks/p4-complete-spec.md`](odd/tasks/p4-complete-spec.md).

## Escaneo de secretos (gitleaks, S0-P1-04)

- **Local (primera capa):** instalar el hook de pre-commit **una vez** en este clone
  (gitleaks no tiene comando `install`; el hook es un `.git/hooks/pre-commit` que
  ejecuta `gitleaks git --staged`):

  ```bash
  printf '#!/usr/bin/env bash\nexec gitleaks git --staged --verbose\n' \
    > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
  ```
- **CI (segunda capa):** el job `gitleaks` (`.github/workflows/gitleaks.yml`)
  escanea el diff de cada PR y cada push a `main`.

## Gobernanza

- Rama `main` protegida por ruleset: push directo y force push denegados, PR obligatorio con CI en verde y al menos 1 aprobación de code owner (`@MaJuVer`, co-owner `@Alejo-Basile`).
- Plantilla de PR obligatoria: *qué cambia · por qué · cómo se prueba · cómo se revierte*.
