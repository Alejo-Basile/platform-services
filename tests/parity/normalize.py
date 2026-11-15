"""Normalización de texto para la paridad v1/v2 (S0-P4-06 §2, S8-P4-02).

Una sola función de normalización para ambos caminos. El detalle de las
reglas y las decisiones de ambigüedad está en ``tests/parity/README.md``.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

# Se versiona: si cambia la normalización hay que volver a correr el corpus.
NORMALIZER_VERSION = "1.0.0"

_SPACES = re.compile(r"[ \t]+")
_PAGE_NUMBER = re.compile(r"^(?:p[aá]gina|page)\s+\d+$", re.IGNORECASE)


class InvalidEncodingError(ValueError):
    """El texto no es UTF-8 válido; se registra como error del corpus (§2.1)."""


@dataclass(frozen=True)
class CaseRules:
    """Reglas de §2.8/§2.9 habilitadas solo con evidencia por caso."""

    drop_page_numbers: bool = False
    repeated_lines: tuple[str, ...] = ()


def decode_utf8(raw: bytes) -> str:
    """Decodifica UTF-8 estricto; una codificación inválida no se compara."""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise InvalidEncodingError(f"el texto no es UTF-8 valido: {exc}") from exc


def normalize_newlines(text: str) -> str:
    """Convierte ``\\r\\n`` y ``\\r`` a ``\\n`` (§2.3)."""
    return text.replace("\r\n", "\n").replace("\r", "\n")


def collapse_spaces(text: str) -> str:
    """Colapsa espacios y tabulaciones ASCII por línea y recorta sus extremos.

    Solo se tocan espacio y tabulación (§2.4): un NBSP u otro whitespace se
    conserva para no borrar diferencias reales.
    """
    lines = (_SPACES.sub(" ", line).strip(" \t") for line in text.split("\n"))
    return "\n".join(lines)


def collapse_blank_lines(text: str) -> str:
    """Colapsa secuencias de líneas vacías a una sola (§2.5)."""
    result: list[str] = []
    previous_blank = False
    for line in text.split("\n"):
        blank = line == ""
        if blank and previous_blank:
            continue
        result.append(line)
        previous_blank = blank
    return "\n".join(result)


def normalize_text(text: str) -> str:
    """Aplica la normalización obligatoria de §2 (sin reglas por caso)."""
    text = unicodedata.normalize("NFC", text)
    text = normalize_newlines(text)
    text = collapse_spaces(text)
    text = collapse_blank_lines(text)
    return text.rstrip()


def normalize_bytes(raw: bytes) -> str:
    """Decodifica y normaliza; propaga ``InvalidEncodingError``."""
    return normalize_text(decode_utf8(raw))


def is_page_number_line(line: str) -> bool:
    """Verdadero si la línea es un número de página aislado (§2.9).

    Se aceptan el número solo y las formas ``Página N`` / ``Page N`` que
    aparecen en el ejemplo de §6. Solo se usa si el caso lo habilita.
    """
    if line.isascii() and line.isdigit():
        return True
    return bool(_PAGE_NUMBER.match(line))


def apply_case_rules(
    normalized: str, rules: CaseRules
) -> tuple[str, list[str]]:
    """Elimina líneas justificadas por el caso y devuelve las eliminadas.

    Sin reglas activas el texto queda intacto. Con líneas eliminadas se
    recortan las líneas vacías que quedan al inicio para que el ejemplo
    ``MATCH_WITH_DIFF`` de §6 (cabecera de página) compare bien.
    """
    if not rules.drop_page_numbers and not rules.repeated_lines:
        return normalized, []

    kept: list[str] = []
    removed: list[str] = []
    for line in normalized.split("\n"):
        if line and (
            line in rules.repeated_lines
            or (rules.drop_page_numbers and is_page_number_line(line))
        ):
            removed.append(line)
            continue
        kept.append(line)

    if not removed:
        return normalized, []

    result = collapse_blank_lines("\n".join(kept)).strip("\n")
    return result, removed
