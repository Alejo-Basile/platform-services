# Definición de paridad por resultado (`S0-P4-06`)

- **Estado:** Propuesto para firma de las 4 personas
- **Owner:** P4
- **Depende de:** `S0-P4-02` (línea base) y `S0-P4-01` (inventario)
- **Aplica a:** replay de S8 (`S8-P4-01`, `S8-P4-02`), canary y puerta G4

## 1. Qué significa "equivalente"

El sistema nuevo es equivalente al monolito cuando, para el mismo PDF de entrada, el **texto
extraído normalizado** coincide con el del camino viejo.

**No se comparan:**

- códigos HTTP (`200` síncrono del monolito vs `201` asíncrono de v2);
- cuerpos de respuesta (v1 devuelve el `.txt`; v2 devuelve una URL prefirmada);
- latencias (v1 incluye extracción en la request; v2 es un pipeline asíncrono);
- nombres de archivo, cabeceras de transporte o `Content-Disposition`.

Comparar esas cosas produce divergencias falsas que nadie puede arreglar porque son diferencias
de diseño, no de resultado. La paridad es del **contenido**, no del protocolo.

## 2. Normalización obligatoria

Antes de comparar, ambos textos pasan por la misma función de normalización:

1. **Decodificación:** UTF-8. Si el archivo no es UTF-8 válido, se registra como caso de error
   del corpus, no se compara a ciegas.
2. **Unicode:** normalización NFC.
3. **Saltos de línea:** `\r\n` y `\r` se convierten a `\n`.
4. **Espacios:** se colapsan espacios y tabulaciones consecutivas a un espacio simple; se eliminan
   los espacios al inicio y al final de cada línea.
5. **Líneas vacías:** se colapsan las secuencias de líneas vacías a una sola.
6. **Fin de archivo:** se elimina el whitespace final.
7. **Orden de lectura:** se conserva el orden del extractor de cada camino. No se reordena para
   "hacer coincidir" los textos.
8. **Cabeceras y pies de página:** se eliminan solo si el corpus demuestra que son ruido repetido
   del mismo documento. La regla se documenta por caso; no se aplica una heurística global sin
   evidencia.
9. **Números de página:** se eliminan si aparecen como línea aislada con el número de página. La
   decisión se registra en el reporte del corpus.

La función de normalización vive en `tests/parity/normalize.py` (S8) y debe ser la misma para
ambos caminos. Si cambia, se versiona y se vuelve a correr el corpus completo.

## 3. Veredicto y tolerancia

| Veredicto | Condición | Acción |
|---|---|---|
| `MATCH` | Textos idénticos después de normalizar | Cuenta como paridad |
| `MATCH_WITH_DIFF` | Diferencia solo en whitespace/orden de líneas permitido por §2 y documentada | Cuenta como paridad, con el diff adjunto |
| `MISMATCH` | Diferencia de contenido, texto faltante o texto extra | **No cuenta**; se abre issue con el PDF y el diff |

**Tolerancia:** 0 diferencias de contenido. La paridad exigida por G4 es **≥ 99.9 %** del corpus
en dos ejecuciones consecutivas. Un `MISMATCH` no se compensa con un porcentaje global: el
reporte debe listar cada caso.

> La tolerancia no es una excusa para normalizar de más. Si una regla de §2 hace desaparecer una
> diferencia real, la regla está mal y se corrige.

## 4. Corpus mínimo

El corpus de S8 incluye, como mínimo:

- PDFs válidos con texto (una y varias páginas);
- PDFs escaneados sin capa de texto;
- PDFs cifrados;
- PDFs corruptos;
- PDF de 30 MB (límite de negocio);
- PDFs hostiles (muchas páginas, estructuras malformadas);
- PDFs reales del negocio, aportados por los clientes.

Cada archivo se identifica por hash SHA256 y se versiona en el corpus. El reporte guarda:
`archivo`, `hash`, `veredicto`, `diff`, `version_normalizador`, `fecha` y `commit` de ambos
caminos.

## 5. Cómo se produce el `.txt` en cada camino

| Camino | Cómo se obtiene el texto |
|---|---|
| v1 (monolito) | `POST /pdf/process` con el PDF; la respuesta `200` es el `.txt` |
| v2 (nuevo) | `POST /api/v2/documents` → subida prefirmada a MinIO → esperar estado terminal → `GET /api/v2/documents/{id}/download` → descargar el `.txt` |

El replay no compara el estado HTTP de ambos caminos: solo verifica que el v2 llegue a
`COMPLETED` y que el `.txt` exista; después compara texto contra texto.

## 6. Ejemplos

Caso `MATCH`:

```text
v1: "Factura\nNúmero: 123\nTotal: 100"
v2: "Factura\r\nNúmero: 123\r\nTotal: 100"
```

Después de normalizar, ambos son `Factura\nNúmero: 123\nTotal: 100` → `MATCH`.

Caso `MISMATCH`:

```text
v1: "Total: 100"
v2: "Total: 1OO"
```

La diferencia es de contenido (dígito vs letra) → `MISMATCH`, aunque la forma sea parecida.

Caso `MATCH_WITH_DIFF`:

```text
v1: "Página 1\n\nTexto"
v2: "Texto"
```

Solo si la regla de §2.9 justifica eliminar el número de página y el resto del contenido coincide.

## 7. Firma

| Persona | Rol | Firma / acuse | Fecha |
|---|---|---|---|
| P1 | Platform / DevOps | pendiente | |
| P2 | Backend Go | pendiente | |
| P3 | Systems Rust | pendiente | |
| P4 | Integración / Calidad | pendiente | |

El documento no se considera aceptado hasta que las 4 personas lo firmen. Sin firma, el replay de
S8 no puede declarar paridad y G4 es No-Go.
