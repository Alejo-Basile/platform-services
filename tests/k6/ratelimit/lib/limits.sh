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

# limits_expected_paced BURST RATE DURATION_MS TOTAL
#
# Máximo teórico de peticiones que pasan con arribos pautados durante
# DURATION_MS a una tasa superior al límite: el bucket arranca lleno (BURST) y
# repone RATE tokens por segundo durante toda la ventana. Se usa en lugar de
# limites_expected_allowed cuando k6 controla el espaciado de los arribos: así
# la ventana observada es la del escenario y no depende de cuándo el gateway
# alcanzó a evaluar cada petición.
limits_expected_paced() {
  local burst="$1" rate="$2" duration_ms="$3" total="$4"
  awk -v burst="$burst" -v rate="$rate" -v duration_ms="$duration_ms" -v total="$total" '
    BEGIN {
      allowed = int(burst + rate * duration_ms / 1000.0)
      if (allowed > total) allowed = total
      if (allowed < 0) allowed = 0
      printf "%d", allowed
    }'
}

# limits_deviation_tolerant ALLOWED EXPECTED_ALLOWED DENIED EXPECTED_DENIED UNEXPECTED TOL
#
# La cota superior del GCRA es inviolable: nunca pueden pasar más peticiones
# que burst + rate*ventana, así que cualquier sobre-aprobación (allowed >
# esperado) es desviación con tolerancia cero. La sub-aprobación sí admite
# jitter de scheduling/kernel hasta TOL tokens: perder turnos por demora no
# rompe la garantía de límite. Un estado inesperado o un contador ausente (-1)
# nunca se toleran.
limits_deviation_tolerant() {
  local allowed expected_allowed denied expected_denied unexpected tol
  allowed="$(limits_integer_or "$1" -1)"
  expected_allowed="$(limits_integer_or "$2" -1)"
  denied="$(limits_integer_or "$3" -1)"
  expected_denied="$(limits_integer_or "$4" -1)"
  unexpected="$(limits_integer_or "$5" -1)"
  tol="$(limits_integer_or "$6" 0)"

  if ((allowed < 0 || denied < 0 || unexpected != 0)); then
    printf '1'
    return
  fi

  # Sobre-aprobación: ni un solo token por encima del máximo teórico.
  if ((allowed > expected_allowed || denied < expected_denied)); then
    printf '1'
    return
  fi

  local under=$((expected_allowed - allowed))
  if ((under > tol)); then
    printf '1'
  else
    printf '0'
  fi
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
