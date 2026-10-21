-- GCRA atomico (ADR-0005).
-- KEYS[1]: clave del limite (rl:{scope}:{identity})
-- ARGV[1]: rate en peticiones/segundo (admite decimales)
-- ARGV[2]: burst (peticiones inmediatas permitidas)
-- Devuelve {allowed, remaining, retry_after_segundos}.

local key = KEYS[1]
local rate = tonumber(ARGV[1])
local burst = tonumber(ARGV[2])

if not rate or rate <= 0 then
  return redis.error_reply("rate debe ser > 0")
end
if not burst or burst < 1 then
  return redis.error_reply("burst debe ser >= 1")
end

-- Reloj del servidor: nunca el del cliente.
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000000 + tonumber(t[2])

local interval = math.floor(1000000 / rate)
if interval < 1 then
  interval = 1
end
local tolerance = burst * interval

local stored = redis.call('GET', key)
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
  -- La clave expira cuando el estado ya no puede afectar decisiones futuras.
  local ttl = math.ceil((new_tat - now) / 1000000) + 1
  redis.call('SET', key, string.format('%.0f', new_tat), 'EX', ttl)

  local remaining = math.floor((now + tolerance - new_tat) / interval)
  if remaining < 0 then
    remaining = 0
  end
  return {1, remaining, 0}
end

local retry = math.ceil((allow_at - now) / 1000000)
if retry < 1 then
  retry = 1
end
return {0, 0, retry}
