# shellcheck shell=bash
# Cálculo puro de la verificación de límite (S7-P4-04).
#
# Se sourcea desde run-limit-verification.sh (que dispara las corridas) y desde
# test-limits.sh (que prueba estas funciones sin stack). Mantener aquí la
# aritmética permite verificarla de forma determinista.

# limits_integer_or RAW FALLBACK
# Imprime RAW si es un entero decimal; si no (p. ej. "null" o "" de jq),
# imprime FALLBACK. Evita que un contador ausente rompa la comparación.
limits_integer_or() {
  local raw="$1" fallback="$2"
  if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$raw"
  else
    printf '%s' "$fallback"
  fi
}

# limits_expected_allowed BURST RATE WINDOW_MS TOTAL
#
# Máximo de peticiones que pueden pasar en la ventana observada de la ráfaga.
# El bucket arranca lleno: dispone de BURST tokens más el relleno continuo
# RATE por segundo durante WINDOW_MS, acotado por TOTAL (no se pueden pasar
# más peticiones que las disparadas). Truncar a entero refleja que un token
# fraccionario todavía no habilita una petición.
limits_expected_allowed() {
  local burst="$1" rate="$2" window_ms="$3" total="$4"
  awk -v burst="$burst" -v rate="$rate" -v window_ms="$window_ms" -v total="$total" '
    BEGIN {
      allowed = int(burst + rate * window_ms / 1000.0)
      if (allowed > total) allowed = total
      if (allowed < 0) allowed = 0
      printf "%d", allowed
    }'
}

# limits_deviation ALLOWED EXPECTED_ALLOWED DENIED EXPECTED_DENIED UNEXPECTED
#
# "0" si la corrida pasó exactamente el límite esperado (allowed y denied
# cuadran y no hubo estados inesperados); "1" en cualquier otro caso. Un
# contador ausente (-1) siempre es desviación.
limits_deviation() {
  local allowed expected_allowed denied expected_denied unexpected
  allowed="$(limits_integer_or "$1" -1)"
  expected_allowed="$(limits_integer_or "$2" -1)"
  denied="$(limits_integer_or "$3" -1)"
  expected_denied="$(limits_integer_or "$4" -1)"
  unexpected="$(limits_integer_or "$5" -1)"

  if ((allowed != expected_allowed || denied != expected_denied || unexpected != 0)); then
    printf '1'
  else
    printf '0'
  fi
}
