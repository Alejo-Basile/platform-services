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

## Corpus S8 y runner de replay dos caminos

### Manifiesto del corpus (`S8-P4-01`)

`tests/parity/corpus/build_manifest.py` genera un manifiesto reproducible del
corpus de PDFs (`tests/fixtures/pdf/baseline-*.pdf`, orden lexicográfico):

```bash
python3 tests/parity/corpus/build_manifest.py \
  --pdf-dir tests/fixtures/pdf \
  --out tests/parity/corpus/manifest.json \
  --generated 2026-11-17T00:00:00Z \
  --version s8-expanded-1
```

Formato (`schema_version: "s8-corpus/v1"`):

```json
{
  "schema_version": "s8-corpus/v1",
  "version": "s8-expanded-1",
  "generated": "2026-11-17T00:00:00Z",
  "count": 100,
  "total_bytes": 60900,
  "documents": [
    {
      "name": "baseline-0001.pdf",
      "path": "tests/fixtures/pdf/baseline-0001.pdf",
      "sha256": "<64 hex>",
      "size_bytes": 609
    }
  ]
}
```

El resultado es determinista salvo `generated`, que se congela con
`--generated <ISO8601 UTC>` para tests y CI. `--base-dir` controla la base de
las rutas relativas (por defecto la raíz del repo `platform-services`).

### Runner de replay (`S8-P4-02`)

`tests/parity/replay.py` recorre el manifiesto y ejecuta los dos caminos por
documento, en orden secuencial:

- **v1:** `POST /pdf/process` (`multipart/form-data`, campo `file`). Respuesta
  `200` = bytes del TXT. Un `409` se registra como `v1_duplicate` (error), no
  como éxito silencioso.
- **v2:** `POST /api/v2/documents` (`idempotency_key` + `size_bytes`) →
  subida prefirmada con `upload_url` + `form_fields` + `file` → polling de
  `GET /api/v2/documents/{id}` cada 2 s hasta estado terminal →
  `GET /api/v2/documents/{id}/download` → se sigue `download_url` para bajar
  el TXT.

```bash
python3 tests/parity/replay.py \
  --manifest tests/parity/corpus/manifest.json \
  --v1-base http://localhost:9081 \
  --v2-base http://localhost:9080 \
  --out artifacts/parity/replay \
  --threshold 99.9 \
  --timeout 180 \
  --id-prefix s8p4
```

Salidas bajo `--out`:

```text
artifacts/parity/replay/
  fixtures/<stem>/legacy.txt   # TXT de v1 (solo si ambos caminos respondieron)
  fixtures/<stem>/nuevo.txt    # TXT de v2
  fixtures/<stem>/case.json    # {"corpus": true}
  parity-report.json           # esquema de report.py (schema_version "1")
  run-summary.json             # resumen de la corrida (esquema s8-replay/v1)
```

`run-summary.json` incluye `run_id`, tiempos, manifiesto, endpoints,
`v1_ok`/`v1_errors`/`v2_ok`/`v2_errors`, `docs_compared`, `parity_rate`,
`threshold`, `parity_pass`, `corpus_error_rate` (documentos fallidos /
totales), `error_rate_threshold` (`0.001`), `error_rate_pass`, `verdicts`,
`failed_documents[]` (`name`/`stage`/`detail`) y `exit_code`.

Si un lado falla **no** se escribe un par parcial de fixtures: el documento se
registra en `failed_documents` y cuenta para la tasa de error del corpus.

### Códigos de salida

| Código | Significado |
|---|---|
| `0` | Paridad ≥ umbral, sin `MISMATCH`/`ERROR`, tasa de error < 0.1 %. |
| `1` | Paridad bajo el umbral, algún `MISMATCH`/`ERROR`, o tasa de error ≥ 0.1 %. |
| `2` | Preflight fallido: manifiesto ausente/inválido o endpoint inalcanzable. |

### Notas

- El runner **solo compara texto extraído normalizado**. Nunca compara
  códigos HTTP, cuerpos de respuesta, latencias ni cabeceras: el contrato v2
  es asíncrono y esas diferencias son por diseño (`docs/paridad.md` §5).
- La tolerancia de contenido es cero: cualquier `MISMATCH`/`ERROR` hace
  fallar la corrida.
- `--docs-limit N` toma un subconjunto ordenado y es **solo para smoke**; un
  resultado con límite no representa la paridad del corpus completo.
- `--dry-run` valida manifiesto y alcanzabilidad de endpoints y no crea
  documentos ni artefactos.
- `--cleanup` intenta borrar los documentos v2 creados. Si la API de borrado
  no existe, imprime `cleanup skipped: no delete API` (no se inventa una API).
