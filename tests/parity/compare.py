"""Comparación de paridad por contenido (S0-P4-06 §3, S8-P4-02).

Compara únicamente el texto extraído normalizado de ambos caminos. No mira
códigos HTTP ni cuerpos de respuesta: el contrato v2 es asíncrono y sus
respuestas difieren por diseño.
"""

from __future__ import annotations

import difflib
from dataclasses import dataclass

from normalize import CaseRules, InvalidEncodingError, apply_case_rules, normalize_bytes

MATCH = "MATCH"
MATCH_WITH_DIFF = "MATCH_WITH_DIFF"
MISMATCH = "MISMATCH"
ERROR = "ERROR"


@dataclass(frozen=True)
class Comparison:
    """Resultado de comparar los textos de un caso."""

    verdict: str
    diff: str
    detail: str
    removed_lines: tuple[str, ...] = ()


def unified_diff(legacy: str, nuevo: str) -> str:
    """Diff unificado legible, con etiquetas de camino."""
    return "\n".join(
        difflib.unified_diff(
            legacy.split("\n"),
            nuevo.split("\n"),
            fromfile="legacy",
            tofile="nuevo",
            lineterm="",
        )
    )


def compare_texts(
    legacy_raw: bytes, nuevo_raw: bytes, rules: CaseRules = CaseRules()
) -> Comparison:
    """Normaliza ambos textos y emite el veredicto de §3.

    ``MATCH`` es igualdad tras normalizar; ``MATCH_WITH_DIFF`` es igualdad
    alcanzada solo al eliminar líneas por reglas de caso (con diff adjunto);
    ``MISMATCH`` es diferencia de contenido; ``ERROR`` es codificación
    inválida (§2.1), que no se compara a ciegas.
    """
    try:
        legacy = normalize_bytes(legacy_raw)
        nuevo = normalize_bytes(nuevo_raw)
    except InvalidEncodingError as exc:
        return Comparison(ERROR, "", str(exc))

    legacy_final, removed_legacy = apply_case_rules(legacy, rules)
    nuevo_final, removed_nuevo = apply_case_rules(nuevo, rules)
    removed = tuple(removed_legacy + removed_nuevo)

    if legacy_final == nuevo_final:
        if legacy == nuevo:
            return Comparison(MATCH, "", "textos identicos tras normalizar")
        return Comparison(
            MATCH_WITH_DIFF,
            unified_diff(legacy, nuevo),
            "difieren solo en lineas eliminadas por reglas de caso",
            removed,
        )

    return Comparison(
        MISMATCH,
        unified_diff(legacy_final, nuevo_final),
        "diferencia de contenido",
        removed,
    )
