# Paridad de texto v1/v2 (`S8-P4-02`)

Herramientas para verificar la paridad por **contenido** entre el monolito
(v1) y el stack nuevo (v2), según la definición de `docs/paridad.md`
(`S0-P4-06`). Solo se compara el **texto extraído normalizado**: nunca
códigos HTTP, cuerpos de respuesta, latencias ni cabeceras de transporte,
porque el contrato v2 es asíncrono y esas diferencias son de diseño.

## Convención de casos

Cada caso es un directorio bajo `tests/parity/fixtures/`:

```text
tests/parity/fixtures/<caso>/
  legacy.txt     # texto extraído por el camino v1 (monolito)
  nuevo.txt      # texto extraído por el camino v2 (stack nuevo)
  case.json      # opcional: reglas y metadatos del caso
```

`case.json` (todos los campos opcionales):

```json
{
  "corpus": true,
  "expected_verdict": "MATCH",
  "drop_page_numbers": false,
  "repeated_lines": []
}
```

- `corpus` (default `true`): el caso cuenta para la tasa de paridad. Los
  fixtures de autotest (divergencia a propósito, codificación inválida) usan
  `false` para no contaminar la tasa.
- `expected_verdict`: veredicto esperado; el reporte cuenta como
  `unexpected` cualquier caso que no coincida y CI falla.
- `drop_page_numbers`: habilita §2.9 solo para este caso.
- `repeated_lines`: líneas exactas de cabecera/pie repetido a eliminar,
  habilitado solo con evidencia para este caso (§2.8).

## Salida

`report.py` emite un JSON versionado con `schema_version`,
`version_normalizador`, `generado`, `commit`, `threshold`, `summary` y un
`caso` por fixture (`archivo`, hashes SHA256, `veredicto`, `diff`,
`version_normalizador`). La tasa de paridad se calcula sobre **todo** el
corpus (`MATCH + MATCH_WITH_DIFF` / casos de corpus); `MISMATCH` y `ERROR`
cuentan en contra. Umbral por defecto: `99.9` (G4). La tolerancia de
contenido es cero: cualquier `MISMATCH` hace fallar CI.

Uso local:

```bash
python3 -m unittest discover tests/parity -v
python3 tests/parity/report.py \
  --fixtures tests/parity/fixtures \
  --report artifacts/parity-report.json \
  --threshold 99.9
```

En CI (`.github/workflows/parity.yml`) el reporte se sube como artefacto.
La tarea programada queda para la tanda de `S8-P4-03` (T7).

## Veredictos

| Veredicto | Significado |
|---|---|
| `MATCH` | Textos idénticos después de normalizar. |
| `MATCH_WITH_DIFF` | Iguales solo al eliminar líneas por reglas del caso; se adjunta el diff. Cuenta como paridad. |
| `MISMATCH` | Diferencia de contenido, texto faltante o extra. No cuenta. |
| `ERROR` | Codificación no UTF-8 u otro error de corpus; no se compara a ciegas. |

## Decisiones de normalización y ambigüedades resueltas

- **§2.1 Codificación:** decodificación UTF-8 estricta. Un archivo inválido
  produce `ERROR` y no se compara (no se reemplaza con `errors="replace"`).
- **§2.4 Espacios:** solo se colapsan espacio y tabulación ASCII. Un NBSP u
  otro whitespace se conserva para no borrar diferencias reales (el texto de
  §2.4 habla de "espacios y tabulaciones").
- **§2.8 Cabeceras/pies:** no hay heurística global. Se eliminan solo si el
  caso declara `repeated_lines` con evidencia, tal como exige la regla.
- **§2.9 Números de página:** desactivado por defecto; se habilita por caso
  con `drop_page_numbers`. Se acepta el número aislado (`12`) y las formas
  `Página N` / `Page N`, porque el ejemplo de §6 usa `Página 1` aunque §2.9
  diga "número de página" aislado. Al eliminar líneas se recortan las líneas
  vacías que quedan al inicio para que ese ejemplo compare.
- **Documento escaneado sin texto:** si ambos caminos producen `.txt` vacío,
  el veredicto es `MATCH` (no hay contenido que difiera). Si solo uno está
  vacío, es `MISMATCH`.
- **Orden de lectura:** se conserva el orden del extractor; no se reordena
  para "hacer coincidir" (§2.7).

## Pendiente para el DoD completo

- Corpus real completo (PDFs válidos, escaneados, cifrados, corruptos, 30 MB,
  hostiles y reales) — depende de `S8-P4-01` (T6).
- Tarea programada con ventana de alerta — `S8-P4-03` (T7).
- Versionar un reporte base en el repo cuando el corpus esté completo.
