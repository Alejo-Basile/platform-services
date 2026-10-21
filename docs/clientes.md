# Inventario de clientes del monolito (`S0-P4-01` / `S0-P4-07`)

> **Estado:** PARCIAL — bloqueado en la parte que exige datos de producción.
>
> El código del monolito permite inventariar rutas, pero **no** permite saber qué clientes las
> consumen. El plan exige uso real medido en access logs, no estimaciones. Hasta que existan esos
> logs, esta tabla no se puede cerrar y ADR-0018 no se puede aceptar.

## 1. Qué falta y por qué

| Dato | Fuente requerida | Estado |
|---|---|---|
| Cliente / sistema | Access logs del monolito o de Traefik, con IP/identidad y `User-Agent` | Pendiente |
| Ruta usada | Access logs (método + path) | Pendiente |
| Uso real semanal | Agregación de logs por cliente y ruta | Pendiente |
| Responsable | Contacto del negocio | Pendiente |
| Fecha de migración | Acuerdo escrito con el negocio (ADR-0018) | Pendiente |

No se completa con "clientes típicos" ni con rutas del README: eso sería una estimación y el
riesgo R21 (clientes que no migran) se gestiona con datos, no con supuestos.

## 2. Consumidores técnicos confirmados

| Consumidor | Evidencia | Rutas |
|---|---|---|
| Traefik (router legacy `/*`) | `infra/compose/docker-compose.yml`, labels `traefik.http.routers.legacy.rule=Host(api.localhost)` | Todas las del monolito, por fallback |
| Tests del monolito | `pdf-extractext/tests/interface/test_health.py` | `GET /health`, `GET /health/ready` |
| Equipo / operación | `README.md` del monolito | `GET /health`, `GET /registros`, `POST /pdf/process` (manual) |

Estos consumidores no son suficientes para ADR-0018: son técnicos, no clientes de negocio.

## 3. Plantilla para completar (no inventar)

| Cliente | Sistema / repo | Responsable | Ruta(s) usada(s) | Uso real/semana | Destino v2 | Fecha comprometida | Estado |
|---|---|---|---|---|---|---|---|
| _pendiente_ | | | | | | | |

## 4. Cómo se completa

1. Pedir al negocio/ops una ventana de access logs del monolito (o de Traefik) que cubra al menos
   7 días representativos.
2. Agregar por `cliente` (IP/identidad/User-Agent) y por `método + path`.
3. Cruzar con el inventario de endpoints (`docs/inventario-endpoints.md`): toda ruta con uso > 0
   debe tener al menos un cliente identificado.
4. Contactar a cada responsable y registrar la fecha de migración acordada por escrito.
5. Los clientes que no migran se registran como **excepción firmada** con impacto y nueva fecha;
   no se dejan como deuda invisible.

## 5. Criterio de cierre

- [ ] Toda ruta del inventario con uso > 0 tiene al menos un cliente identificado.
- [ ] Todo cliente tiene responsable y fecha de migración.
- [ ] El negocio firmó la fecha límite de ADR-0018.
- [ ] Las excepciones están inventariadas con impacto y fecha.

Mientras estos puntos no se cumplan, `S0-P4-07` queda **BLOQUEADA** y G0 es **No-Go** para P4.
