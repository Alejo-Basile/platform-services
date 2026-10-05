# platform-services

Servicios de plataforma y arnés de pruebas del proyecto de migración a microservicios.

> Especificación arquitectónica (fuente única de verdad): [`infra/docs/SPEC.md`](https://github.com/Alejo-Basile/infra/blob/main/docs/SPEC.md) v2.1

## Qué hace este repo

- **`rate-limiter/`** (Go): servicio de rate limiting distribuido vía **ForwardAuth** de Traefik con conteo en Redis — Opción B del SPEC §8 (el middleware nativo `RateLimit` de Traefik OSS es por instancia, no distribuido). Responde 200/429 antes de que Traefik rutee.
- **`tests/`**: arnés de pruebas E2E y de contrato (k6), incluyendo el **replay del corpus de PDFs** (válidos, inválidos, escaneados, cifrados, grandes) contra los caminos v1 (monolito) y v2 (nuevo), comparando el texto extraído normalizado (SPEC §13, Fase 4).

## Qué NO hace este repo

- **No configura infraestructura**: compose, redes, Traefik y datos viven en `infra/`.
- **No implementa lógica de negocio del documento**: CRUD/SAGA es `doc-service/`; extracción es `extraction-worker/`.
- **No contiene secretos reales**: solo `.env.example` con valores ficticios (repo público).

## Estructura

```
rate-limiter/   # servicio ForwardAuth (Go)
tests/          # arnés E2E/contrato (k6)
docs/adr/       # ADRs locales (las globales van en infra/docs/adr/)
```

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
