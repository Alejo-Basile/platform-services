-- GCRA atomico multi-clave (ADR-0005).
-- Evalua N limites en un unico EVAL. Solo consume cuando todos admiten: un
-- rechazo no modifica ninguna clave, de modo que una ruta ya rechazada tampoco
-- consume el limite global. Mantiene la atomicidad exigida por ADR-0005.
-- KEYS[1..n]: claves de limite (rl:{scope}:{identity} / rl:route:{...}:{identity})
-- ARGV[1]: n
-- ARGV[2 + 2*(i-1)]: rate_i (peticiones/segundo, admite decimales)
-- ARGV[3 + 2*(i-1)]: burst_i (peticiones inmediatas permitidas)
-- Devuelve {allowed, remaining_minimo, retry_after_maximo_segundos}.

local n = tonumber(ARGV[1])
if not n or n < 1 then
  return redis.error_reply("se requiere al menos un limite")
end

-- Reloj del servidor: nunca el del cliente.
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000000 + tonumber(t[2])

local new_tats = {}
local remaining_min = -1
local retry_max = 0
local all_allowed = true

for i = 1, n do
  local rate = tonumber(ARGV[2 + (i - 1) * 2])
  local burst = tonumber(ARGV[3 + (i - 1) * 2])
  if not rate or rate <= 0 then
    return redis.error_reply("rate debe ser > 0")
  end
  if not burst or burst < 1 then
    return redis.error_reply("burst debe ser >= 1")
  end

  local interval = math.floor(1000000 / rate)
  if interval < 1 then
    interval = 1
  end
  local tolerance = burst * interval

  local stored = redis.call('GET', KEYS[i])
  local tat = now
  if stored then
    tat = tonumber(stored)
    if not tat then
      tat = now
    end
  end

  local new_tat = math.max(tat, now) + interval
  local allow_at = new_tat - tolerance

  if now >= allow_at then
    new_tats[i] = new_tat
    local remaining = math.floor((now + tolerance - new_tat) / interval)
    if remaining < 0 then
      remaining = 0
    end
    if remaining_min < 0 or remaining < remaining_min then
      remaining_min = remaining
    end
  else
    all_allowed = false
    local retry = math.ceil((allow_at - now) / 1000000)
    if retry < 1 then
      retry = 1
    end
    if retry > retry_max then
      retry_max = retry
    end
  end
end

if not all_allowed then
  return {0, 0, retry_max}
end

for i = 1, n do
  -- La clave expira cuando el estado ya no puede afectar decisiones futuras.
  local ttl = math.ceil((new_tats[i] - now) / 1000000) + 1
  redis.call('SET', KEYS[i], string.format('%.0f', new_tats[i]), 'EX', ttl)
end

if remaining_min < 0 then
  remaining_min = 0
end
return {1, remaining_min, 0}
