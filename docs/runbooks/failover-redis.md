# Runbook: failover de Redis Streams con Sentinel

**Alcance:** recuperar el primario de Redis Streams (`redis-streams`) cuando el
nodo actual no responde, o ejecutar un failover planificado, manteniendo el
stream `stream:pdf-processing` y su grupo de consumo.

**Disparador**

- El primario `redis-streams` está caído, en `READONLY`, o el grupo
  `extraction-workers` deja de avanzar y el backlog de la PEL crece.
- `SENTINEL get-master-addr-by-name myprimary` devuelve un nodo que no acepta
  escrituras.
- Ventana de mantenimiento con failover controlado.

**Precondiciones obligatorias**

1. Los tres Sentinels están corriendo y tienen quórum (2 de 3).
2. Existe al menos una réplica de `redis-streams` conectada. En este compose las
   réplicas están en el perfil `sentinel` y **no** se levantan con
   `--profile full`; si `connected_slaves` es 0, no hay failover posible.
3. `doc-service` y `extraction-worker` pueden resolver el maestro por Sentinel.
   El worker en modo directo no sigue un failover; si se va a hacer failover,
   recréelo con el override de Sentinel.

## Preparación de la shell

```bash
set -euo pipefail

if [[ -f infra/compose/docker-compose.yml ]]; then
  WORKSPACE_ROOT="$PWD"
elif [[ -f ../infra/compose/docker-compose.yml ]]; then
  WORKSPACE_ROOT="$(cd .. && pwd)"
else
  echo "ERROR: ejecute desde la raíz del workspace o desde platform-services" >&2
  exit 1
fi
cd "$WORKSPACE_ROOT"

export DOCKER_GID="${DOCKER_GID:-$(stat -c '%g' /var/run/docker.sock)}"
PROJECT="${P4_COMPOSE_PROJECT:-infra}"

C=(docker compose \
  -f infra/compose/docker-compose.yml \
  --env-file infra/.env \
  -p "$PROJECT" \
  --profile full)

C_SENTINEL=(docker compose \
  -f infra/compose/docker-compose.yml \
  --env-file infra/.env \
  -p "$PROJECT" \
  --profile full \
  --profile sentinel)
```

Helper para Redis con autenticación desde el secreto:

```bash
redis_cli() {
  "${C[@]}" exec -T redis-streams sh -c '
    PW=$(cat /run/secrets/redis_streams_password)
    redis-cli -a "$PW" --no-auth-warning "$@"
  ' sh "$@"
}
```

## Diagnóstico

### 1. Estado de los Sentinels

```bash
for s in 1 2 3; do
  printf 'sentinel-%s -> ' "$s"
  "${C_SENTINEL[@]}" exec -T "sentinel-$s" \
    redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | paste -sd ':' -
done
```

Los tres deben devolver el mismo host y puerto. Si no coinciden, no fuerce un
failover: primero revise quórum y conectividad.

```bash
"${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL master myprimary

"${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL replicas myprimary

"${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL sentinels myprimary
```

### 2. Estado del primario y de las réplicas

```bash
"${C[@]}" exec -T redis-streams sh -c '
  PW=$(cat /run/secrets/redis_streams_password)
  redis-cli -a "$PW" --no-auth-warning INFO replication
' | grep -E '^(role|connected_slaves|slave[0-9])'
```

Interpretación:

- `role:master` y `connected_slaves:0` significa que no hay réplica. **No hay
  failover**. Levante las réplicas antes de continuar.
- `role:slave` en `redis-streams` significa que el primario ya cambió; consulte
  a Sentinel y no reinicie el contenedor a ciegas.

### 3. Verificar que hay réplica

```bash
for r in redis-streams-replica-1 redis-streams-replica-2; do
  printf '%s: ' "$r"
  "${C_SENTINEL[@]}" exec -T "$r" sh -c '
    PW=$(cat /run/secrets/redis_streams_password)
    redis-cli -a "$PW" --no-auth-warning ROLE | head -n1
  ' || echo "no disponible"
done
```

Si las réplicas no existen o no están corriendo, levántelas:

```bash
"${C_SENTINEL[@]}" up -d redis-streams-replica-1 redis-streams-replica-2
```

Espere a que `connected_slaves` sea al menos 1 y a que Sentinel vea las réplicas
en `SENTINEL replicas myprimary`. No promueva manualmente un nodo con
`REPLICAOF NO ONE`; deje que Sentinel lo haga.

## Failover planificado

Use esta ruta cuando el primario está sano pero necesita mover el rol.

```bash
"${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL FAILOVER myprimary
```

Sentinel elige una réplica, la promueve y reconfigura a los demás nodos. Espere
y verifique:

```bash
for _ in $(seq 1 30); do
  MASTER="$("${C_SENTINEL[@]}" exec -T sentinel-1 \
    redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | paste -sd ':' -)"
  printf 'master=%s\n' "$MASTER"
  [[ "$MASTER" == "redis-streams-replica-1:6379" || "$MASTER" == "redis-streams-replica-2:6379" ]] && break
  sleep 2
done
```

## Failover de emergencia

Use esta ruta cuando el primario no responde. No detenga los Sentinels.

```bash
"${C[@]}" stop redis-streams
```

Espere a que se cumplan `down-after-milliseconds` (5000 ms) y
`failover-timeout` (30000 ms). Sentinel promueve una réplica y anuncia el nuevo
maestro. Verifique con el bloque de diagnóstico y con:

```bash
"${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary
```

Si no hay réplica disponible, Sentinel no puede promover nada. En ese caso no
invente un maestro ni borre el stream: deténgase, conserve el volumen
`infra_redis-streams-data` y escale. La recuperación de datos desde AOF es un
procedimiento aparte.

## Verificación posterior

### 1. Estado del nuevo primario

```bash
NEW_MASTER="$("${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | head -n1)"

printf 'nuevo maestro: %s\n' "$NEW_MASTER"

"${C_SENTINEL[@]}" exec -T "$NEW_MASTER" sh -c '
  PW=$(cat /run/secrets/redis_streams_password)
  redis-cli -a "$PW" --no-auth-warning INFO replication
' | grep -E '^(role|connected_slaves|slave[0-9])'
```

Criterios:

- `role:master`.
- `connected_slaves` al menos 1 si el nodo antiguo sigue disponible.
- Los tres Sentinels devuelven el mismo maestro.

### 2. Stream, grupo y PEL

```bash
NEW_MASTER="$("${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | head -n1)"

"${C_SENTINEL[@]}" exec -T "$NEW_MASTER" sh -c '
  PW=$(cat /run/secrets/redis_streams_password)
  redis-cli -a "$PW" --no-auth-warning XLEN stream:pdf-processing
  redis-cli -a "$PW" --no-auth-warning XINFO GROUPS stream:pdf-processing
  redis-cli -a "$PW" --no-auth-warning XPENDING stream:pdf-processing extraction-workers
  redis-cli -a "$PW" --no-auth-warning XLEN stream:pdf-processing-dlq
'
```

Criterios:

- `XLEN` del stream principal es mayor que 0 si hay trabajo pendiente.
- El grupo `extraction-workers` existe y su `lag`/`pending` es coherente.
- La DLQ no creció por el failover.
- El PEL drena a medida que el worker reclama mensajes. El worker usa
  `WORKER_MIN_IDLE_MS` (por defecto 600001 ms en compose); un mensaje puede
  tardar hasta ese umbral en ser reclamado. No lo fuerce con `XACK` ni `XDEL`.

### 3. Aplicaciones

```bash
"${C[@]}" ps -a

"${C[@]}" exec -T doc-service wget -qO- http://localhost:8080/healthz
"${C[@]}" exec -T extraction-worker curl -fsS http://localhost:8081/readyz

"${C[@]}" logs --since 15m doc-service | grep -Ei 'readonly|redis|sentinel' || true
"${C[@]}" logs --since 15m extraction-worker | grep -Ei 'readonly|redis|sentinel|xautoclaim' || true
```

Si el worker estaba en modo directo y muestra `READONLY`, recréelo con el
override de Sentinel (solo después de que el nuevo maestro esté estable):

```bash
docker compose \
  -f infra/compose/docker-compose.yml \
  -f infra/compose/docker-compose.sentinel-worker.yml \
  --env-file infra/.env \
  -p "$PROJECT" \
  --profile full \
  up -d --no-build extraction-worker
```

`doc-service` ya usa Sentinel en compose (`REDIS_SENTINEL_ADDRS`); no requiere
recreación.

### 4. Prueba de escritura controlada

En el nuevo primario, escriba una clave efímera y bórrela:

```bash
NEW_MASTER="$("${C_SENTINEL[@]}" exec -T sentinel-1 \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | head -n1)"

"${C_SENTINEL[@]}" exec -T "$NEW_MASTER" sh -c '
  PW=$(cat /run/secrets/redis_streams_password)
  redis-cli -a "$PW" --no-auth-warning SET failover:probe "$(date -u +%FT%TZ)" EX 60
  redis-cli -a "$PW" --no-auth-warning GET failover:probe
  redis-cli -a "$PW" --no-auth-warning DEL failover:probe
'
```

Un `OK` y un valor seguido de `(integer) 1` confirman que el nuevo maestro acepta
escrituras.

## Rollback

Un failover no se "deshace" reiniciando el nodo antiguo. Opciones:

1. **Dejar el nuevo maestro.** Es la opción recomendada. El nodo antiguo, al
   volver, queda como réplica y Sentinel lo reconfigura.
2. **Volver al nodo original** con un failover planificado, solo si el nodo
   original ya se reincorporó como réplica sana:
   ```bash
   "${C_SENTINEL[@]}" exec -T sentinel-1 \
     redis-cli -p 26379 SENTINEL FAILOVER myprimary
   ```
   No arranque el nodo original esperando que sea maestro: Sentinel lo degradará.
3. **Worker en modo directo:** si lo recreó con el override de Sentinel y el
   despliegue no usa Sentinel, vuelva a crearlo sin el override solo cuando el
   maestro estable sea `redis-streams`. Mientras el maestro sea una réplica
   promovida, el modo directo apunta al nodo equivocado.

## Registro de ensayo

| Fecha (UTC) | Autor | Entorno | Resultado | Evidencia | Firma |
|---|---|---|---|---|---|
| _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ |

## Referencias

- `infra/runbooks/failover-redis.md`
- `infra/compose/redis/sentinel.conf.tmpl`
- `infra/compose/redis/sentinel-entrypoint.sh`
- `infra/compose/docker-compose.sentinel-worker.yml`
- `doc-service/internal/adapters/redis/queue.go`
