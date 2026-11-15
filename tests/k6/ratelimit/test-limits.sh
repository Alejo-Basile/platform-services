#!/usr/bin/env bash
# Pruebas deterministas del cálculo de la verificación de límite (S7-P4-04).
#
# No requiere stack ni k6: ejercita las funciones puras de lib/limits.sh que
# usa run-limit-verification.sh para decidir si una corrida se desvió.
#
# Uso:
#   ./tests/k6/ratelimit/test-limits.sh
#
# Exit 0 si todos los casos pasan; exit 1 si alguno falla.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/limits.sh
source "$SCRIPT_DIR/lib/limits.sh"

checks=0
failures=0

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  checks=$((checks + 1))
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s\n  esperado=%s\n  obtenido=%s\n' \
      "$description" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

# limits_expected_allowed: límite de tokens disponibles en la ventana medida.
assert_eq 'ventana 0 ms => solo el burst' \
  '20' "$(limits_expected_allowed 20 10 0 100)"
assert_eq 'ventana 1200 ms a 10 rps => burst + 12' \
  '32' "$(limits_expected_allowed 20 10 1200 100)"
assert_eq 'tope en TOTAL_REQUESTS' \
  '100' "$(limits_expected_allowed 20 10 12000 100)"
assert_eq 'tasa fraccionaria se trunca' \
  '2' "$(limits_expected_allowed 1 0.5 2000 100)"
assert_eq 'TOTAL menor que burst => pasan todas' \
  '5' "$(limits_expected_allowed 20 10 0 5)"

# limits_deviation: 0 cuando todos los contadores cuadran.
assert_eq 'sin desviación cuando allowed y denied cuadran' \
  '0' "$(limits_deviation 32 32 68 68 0)"
assert_eq 'desviación si allowed no cuadra' \
  '1' "$(limits_deviation 33 32 67 68 0)"
assert_eq 'desviación si denied no cuadra' \
  '1' "$(limits_deviation 32 32 67 68 0)"
assert_eq 'desviación si aparecen estados inesperados' \
  '1' "$(limits_deviation 32 32 68 68 1)"
assert_eq 'desviación si falta el contador de allowed (-1)' \
  '1' "$(limits_deviation -1 32 68 68 0)"

# limits_integer_or: normaliza valores de jq antes de comparar.
assert_eq 'entero válido pasa tal cual' \
  '42' "$(limits_integer_or '42' '-1')"
assert_eq 'entero negativo válido pasa tal cual' \
  '-7' "$(limits_integer_or '-7' '0')"
assert_eq 'null de jq cae al fallback' \
  '-1' "$(limits_integer_or 'null' '-1')"
assert_eq 'cadena vacía cae al fallback' \
  '-1' "$(limits_integer_or '' '-1')"
assert_eq 'decimal cae al fallback (no es entero)' \
  '0' "$(limits_integer_or '3.5' '0')"

if ((failures > 0)); then
  printf '\n%d de %d casos fallaron.\n' "$failures" "$checks" >&2
  exit 1
fi

printf 'OK: %d casos.\n' "$checks"
