"""Reporte versionado de paridad de texto (S8-P4-02, S0-P4-06 §3/§4).

Recorre los casos del corpus, compara ``legacy.txt`` contra ``nuevo.txt`` y
emite un reporte con la tasa de paridad sobre el corpus completo. Se ejecuta
en CI; la tarea programada queda enganchada para una tanda posterior.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from compare import ERROR, MATCH, MATCH_WITH_DIFF, MISMATCH, compare_texts
from normalize import NORMALIZER_VERSION, CaseRules

SCHEMA_VERSION = "1"
DEFAULT_THRESHOLD = 99.9
LEGACY_FILENAME = "legacy.txt"
NEW_FILENAME = "nuevo.txt"
CASE_CONFIG_FILENAME = "case.json"
DEFAULT_FIXTURES = Path(__file__).resolve().parent / "fixtures"

_VERDICTS = (MATCH, MATCH_WITH_DIFF, MISMATCH, ERROR)


def sha256_hex(raw: bytes) -> str:
    """Hash SHA256 usado para identificar cada archivo del corpus (§4)."""
    return hashlib.sha256(raw).hexdigest()


def load_case_config(case_dir: Path) -> dict:
    """Lee ``case.json``; ausente equivale a un caso de corpus sin reglas."""
    config_path = case_dir / CASE_CONFIG_FILENAME
    if not config_path.is_file():
        return {}
    return json.loads(config_path.read_text(encoding="utf-8"))


def case_rules_from_config(config: dict) -> CaseRules:
    return CaseRules(
        drop_page_numbers=bool(config.get("drop_page_numbers", False)),
        repeated_lines=tuple(config.get("repeated_lines", ())),
    )


def discover_cases(fixtures_dir: Path) -> list[Path]:
    """Cada subdirectorio es un caso; el orden es determinista."""
    return sorted(path for path in fixtures_dir.iterdir() if path.is_dir())


def build_case_record(case_dir: Path) -> dict:
    """Compara un caso y arma su entrada de reporte."""
    config = load_case_config(case_dir)
    record = {
        "archivo": case_dir.name,
        "hash_legacy": None,
        "hash_nuevo": None,
        "veredicto": None,
        "esperado": config.get("expected_verdict"),
        "corpus": bool(config.get("corpus", True)),
        "diff": "",
        "detalle": "",
        "version_normalizador": NORMALIZER_VERSION,
    }

    legacy_path = case_dir / LEGACY_FILENAME
    nuevo_path = case_dir / NEW_FILENAME
    if not legacy_path.is_file() or not nuevo_path.is_file():
        record["veredicto"] = ERROR
        record["detalle"] = "faltan legacy.txt o nuevo.txt"
        return record

    legacy_raw = legacy_path.read_bytes()
    nuevo_raw = nuevo_path.read_bytes()
    record["hash_legacy"] = sha256_hex(legacy_raw)
    record["hash_nuevo"] = sha256_hex(nuevo_raw)

    comparison = compare_texts(legacy_raw, nuevo_raw, case_rules_from_config(config))
    record["veredicto"] = comparison.verdict
    record["diff"] = comparison.diff
    record["detalle"] = comparison.detail
    if comparison.removed_lines:
        record["lineas_eliminadas"] = list(comparison.removed_lines)
    return record


def summarize(records: list[dict]) -> dict:
    """Tasa de paridad sobre el corpus; los autotests no la alteran."""
    corpus = [record for record in records if record.get("corpus", True)]
    counts = {verdict: 0 for verdict in _VERDICTS}
    for record in corpus:
        counts[record["veredicto"]] = counts.get(record["veredicto"], 0) + 1

    total = len(corpus)
    parity = counts[MATCH] + counts[MATCH_WITH_DIFF]
    rate = round(parity * 100.0 / total, 4) if total else None
    unexpected = sum(
        1
        for record in records
        if record.get("esperado") and record["veredicto"] != record["esperado"]
    )

    return {
        "casos_totales": len(records),
        "casos_corpus": total,
        "casos_autotest": len(records) - total,
        "paridad": parity,
        "match": counts[MATCH],
        "match_with_diff": counts[MATCH_WITH_DIFF],
        "mismatch": counts[MISMATCH],
        "error": counts[ERROR],
        "parity_rate": rate,
        "unexpected": unexpected,
    }


def build_report(
    fixtures_dir: Path,
    threshold: float = DEFAULT_THRESHOLD,
    commit: str = "unknown",
    generated_at: str | None = None,
) -> dict:
    """Reporte completo: metadatos versionados + veredicto por caso."""
    records = [build_case_record(path) for path in discover_cases(fixtures_dir)]
    return {
        "schema_version": SCHEMA_VERSION,
        "version_normalizador": NORMALIZER_VERSION,
        "generado": generated_at or datetime.now(timezone.utc).isoformat(),
        "commit": commit,
        "threshold": threshold,
        "comparacion": "texto extraido normalizado (no codigos ni cuerpos HTTP)",
        "caminos": {"legacy": "v1 (monolito)", "nuevo": "v2 (stack nuevo)"},
        "summary": summarize(records),
        "casos": records,
    }


def _exit_code(summary: dict, threshold: float) -> int:
    if summary["casos_corpus"] == 0:
        print("error: corpus vacio; no hay casos de paridad", file=sys.stderr)
        return 2
    if summary["unexpected"]:
        print(
            f"error: {summary['unexpected']} caso(s) con veredicto inesperado",
            file=sys.stderr,
        )
        return 1
    if summary["mismatch"] or summary["error"]:
        print("error: hay casos MISMATCH o ERROR en el corpus", file=sys.stderr)
        return 1
    if summary["parity_rate"] < threshold:
        print(
            f"error: paridad {summary['parity_rate']}% < umbral {threshold}%",
            file=sys.stderr,
        )
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Reporte de paridad v1/v2")
    parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES)
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA", "unknown"))
    args = parser.parse_args(argv)

    if not args.fixtures.is_dir():
        print(f"error: no existe el directorio {args.fixtures}", file=sys.stderr)
        return 2

    report = build_report(
        args.fixtures, threshold=args.threshold, commit=args.commit
    )
    text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.report is not None:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8")

    print(json.dumps(report["summary"], ensure_ascii=False, sort_keys=True))
    return _exit_code(report["summary"], args.threshold)


if __name__ == "__main__":
    raise SystemExit(main())
