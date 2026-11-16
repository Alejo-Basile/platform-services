"""Tests del reporte de paridad versionado (S8-P4-02).

El reporte corre en CI y su salida incluye la tasa de paridad sobre el corpus
completo (no una muestra), más un diff por caso divergente.
"""

import json
import tempfile
import unittest
from pathlib import Path

from compare import ERROR, MATCH, MATCH_WITH_DIFF, MISMATCH
from normalize import NORMALIZER_VERSION
from report import (
    CASE_CONFIG_FILENAME,
    build_report,
    main,
    summarize,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class FixtureReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = build_report(FIXTURES, commit="test-sha")
        cls.by_name = {case["archivo"]: case for case in cls.report["casos"]}

    def test_expected_verdicts_for_every_fixture(self):
        expected = {
            "match-basico": MATCH,
            "match-crlf": MATCH,
            "match-espacios": MATCH,
            "match-unicode-nfc": MATCH,
            "match-sin-texto": MATCH,
            "match-pagina": MATCH_WITH_DIFF,
            "mismatch-contenido": MISMATCH,
            "mismatch-falta-texto": MISMATCH,
            "error-encoding": ERROR,
        }
        self.assertEqual(set(self.by_name), set(expected))
        for name, verdict in expected.items():
            self.assertEqual(self.by_name[name]["veredicto"], verdict, name)

    def test_no_unexpected_verdicts(self):
        self.assertEqual(self.report["summary"]["unexpected"], 0)

    def test_parity_rate_covers_whole_corpus(self):
        summary = self.report["summary"]
        self.assertEqual(summary["casos_corpus"], 6)
        self.assertEqual(summary["paridad"], 6)
        self.assertEqual(summary["parity_rate"], 100.0)
        self.assertEqual(summary["mismatch"], 0)
        self.assertEqual(summary["error"], 0)

    def test_self_test_cases_are_excluded_from_rate(self):
        summary = self.report["summary"]
        self.assertEqual(summary["casos_totales"], 9)
        self.assertEqual(summary["casos_autotest"], 3)

    def test_report_carries_versioned_metadata(self):
        self.assertEqual(self.report["version_normalizador"], NORMALIZER_VERSION)
        self.assertEqual(self.report["commit"], "test-sha")
        self.assertIn("generado", self.report)
        self.assertEqual(self.report["schema_version"], "1")

    def test_every_case_records_hashes(self):
        for case in self.report["casos"]:
            if case["veredicto"] == ERROR and case["hash_legacy"] is None:
                continue
            self.assertRegex(case["hash_legacy"], r"^[0-9a-f]{64}$", case["archivo"])
            self.assertRegex(case["hash_nuevo"], r"^[0-9a-f]{64}$", case["archivo"])


class SummaryTests(unittest.TestCase):
    def test_rate_is_parity_over_corpus(self):
        records = [
            {"corpus": True, "veredicto": MATCH, "esperado": None},
            {"corpus": True, "veredicto": MATCH_WITH_DIFF, "esperado": None},
            {"corpus": True, "veredicto": MISMATCH, "esperado": None},
            {"corpus": False, "veredicto": MISMATCH, "esperado": MISMATCH},
        ]
        summary = summarize(records)
        self.assertEqual(summary["casos_corpus"], 3)
        self.assertEqual(summary["paridad"], 2)
        self.assertEqual(summary["parity_rate"], 66.6667)
        self.assertEqual(summary["unexpected"], 0)

    def test_unexpected_verdict_is_counted(self):
        records = [
            {"corpus": False, "veredicto": MATCH, "esperado": MISMATCH},
        ]
        self.assertEqual(summarize(records)["unexpected"], 1)


class CliTests(unittest.TestCase):
    def test_cli_passes_on_matching_corpus_and_writes_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "parity-report.json"
            code = main(
                [
                    "--fixtures",
                    str(FIXTURES),
                    "--report",
                    str(out),
                    "--commit",
                    "abc123",
                ]
            )
            self.assertEqual(code, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["commit"], "abc123")
            self.assertEqual(data["summary"]["parity_rate"], 100.0)

    def test_cli_fails_on_corpus_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            case = Path(tmp) / "caso"
            case.mkdir()
            (case / "legacy.txt").write_text("Total: 100\n", encoding="utf-8")
            (case / "nuevo.txt").write_text("Total: 1OO\n", encoding="utf-8")
            code = main(["--fixtures", tmp])
            self.assertEqual(code, 1)

    def test_cli_returns_two_for_empty_corpus(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = main(["--fixtures", tmp])
            self.assertEqual(code, 2)

    def test_cli_reports_missing_pair_as_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            case = Path(tmp) / "incompleto"
            case.mkdir()
            (case / "legacy.txt").write_text("texto\n", encoding="utf-8")
            code = main(["--fixtures", tmp])
            self.assertEqual(code, 1)


class ConventionTests(unittest.TestCase):
    def test_config_filename_constant(self):
        self.assertEqual(CASE_CONFIG_FILENAME, "case.json")


if __name__ == "__main__":
    unittest.main()
