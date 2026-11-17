"""Tests del corpus S8 y del runner de replay dos caminos (S8-P4-01/02).

Todo es local y determinista: no se abren sockets, no se toca ``localhost``
ni la pila de replay. Se ejercitan las funciones puras que usan el generador
de manifiesto y el runner.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_CORPUS_DIR = _HERE / "corpus"
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import replay  # noqa: E402
_BUILD_MANIFEST_PATH = _CORPUS_DIR / "build_manifest.py"


def _load_build_manifest():
    spec = importlib.util.spec_from_file_location(
        "build_manifest", _BUILD_MANIFEST_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build_manifest = _load_build_manifest()


def _write_fake_pdfs(root: Path, count: int = 3) -> list[Path]:
    paths = []
    for index in range(1, count + 1):
        path = root / f"baseline-{index:04d}.pdf"
        path.write_bytes(b"%PDF-1.4 fake " + bytes([index]) * (10 * index))
        paths.append(path)
    return paths


class ManifestTests(unittest.TestCase):
    def test_counts_sizes_and_hashes_are_correct(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pdf").mkdir()
            paths = _write_fake_pdfs(root / "pdf")

            manifest = build_manifest.build_manifest(
                root / "pdf",
                base_dir=root,
                generated="2026-11-17T00:00:00Z",
            )

            self.assertEqual(manifest["count"], len(paths))
            self.assertEqual(
                manifest["total_bytes"], sum(path.stat().st_size for path in paths)
            )
            self.assertEqual(
                [doc["name"] for doc in manifest["documents"]],
                sorted(path.name for path in paths),
            )
            for doc, path in zip(manifest["documents"], paths):
                raw = path.read_bytes()
                self.assertEqual(doc["size_bytes"], len(raw))
                self.assertEqual(doc["sha256"], hashlib.sha256(raw).hexdigest())
                self.assertEqual(
                    doc["path"], path.relative_to(root).as_posix()
                )

    def test_manifest_is_deterministic_except_generated(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pdf").mkdir()
            _write_fake_pdfs(root / "pdf")

            first = build_manifest.build_manifest(
                root / "pdf", base_dir=root, generated="2026-11-17T00:00:00Z"
            )
            second = build_manifest.build_manifest(
                root / "pdf", base_dir=root, generated="2026-11-17T00:00:00Z"
            )
            other_day = build_manifest.build_manifest(
                root / "pdf", base_dir=root, generated="2026-11-18T00:00:00Z"
            )

            self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))
            first_wo = dict(first)
            other_wo = dict(other_day)
            first_wo.pop("generated")
            other_wo.pop("generated")
            self.assertEqual(first_wo, other_wo)
            self.assertEqual(first["generated"], "2026-11-17T00:00:00Z")

    def test_schema_and_version_are_pinned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pdf").mkdir()
            _write_fake_pdfs(root / "pdf", count=1)
            manifest = build_manifest.build_manifest(
                root / "pdf", base_dir=root, version="s8-expanded-1"
            )
            self.assertEqual(manifest["schema_version"], "s8-corpus/v1")
            self.assertEqual(manifest["version"], "s8-expanded-1")

    def test_cli_writes_manifest_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pdf").mkdir()
            _write_fake_pdfs(root / "pdf")
            out = root / "manifest.json"
            code = build_manifest.main(
                [
                    "--pdf-dir",
                    str(root / "pdf"),
                    "--out",
                    str(out),
                    "--generated",
                    "2026-11-17T00:00:00Z",
                    "--base-dir",
                    str(root),
                ]
            )
            self.assertEqual(code, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["count"], 3)
            self.assertEqual(data["generated"], "2026-11-17T00:00:00Z")

    def test_committed_manifest_matches_repo_corpus(self):
        manifest_path = _CORPUS_DIR / "manifest.json"
        self.assertTrue(manifest_path.is_file(), "falta corpus/manifest.json")
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(data["count"], 100)
        self.assertEqual(len(data["documents"]), 100)
        self.assertEqual(data["documents"][0]["name"], "baseline-0001.pdf")
        self.assertEqual(data["documents"][-1]["name"], "baseline-0100.pdf")


class MultipartTests(unittest.TestCase):
    def test_field_order_and_closing_boundary(self):
        body, content_type = replay.encode_multipart(
            {"key": "uploads/uno.pdf", "policy": "abc"},
            file_field="file",
            filename="baseline-0001.pdf",
            file_bytes=b"%PDF binary",
            boundary="BOUNDARY123",
        )
        self.assertIn("boundary=BOUNDARY123", content_type)
        self.assertTrue(body.endswith(b"--BOUNDARY123--\r\n"))
        key_at = body.index(b'name="key"')
        policy_at = body.index(b'name="policy"')
        file_at = body.index(b'name="file"')
        self.assertLess(key_at, policy_at)
        self.assertLess(policy_at, file_at)

    def test_file_part_headers_and_bytes(self):
        body, _ = replay.encode_multipart(
            [],
            file_field="file",
            filename="baseline-0002.pdf",
            file_bytes=b"%PDF\x00\xffpayload",
            boundary="B",
        )
        self.assertIn(b'Content-Disposition: form-data; name="file"; filename="baseline-0002.pdf"', body)
        self.assertIn(b"Content-Type: application/pdf", body)
        self.assertIn(b"%PDF\x00\xffpayload", body)
        self.assertIn(b'name="file"', body)

    def test_accepts_ordered_pairs(self):
        body, _ = replay.encode_multipart(
            [("a", "1"), ("b", "2")],
            file_field="file",
            filename="x.pdf",
            file_bytes=b"x",
            boundary="B",
        )
        self.assertLess(body.index(b'name="a"'), body.index(b'name="b"'))


class IdempotencyTests(unittest.TestCase):
    def test_key_derivation_is_stable_and_unique_per_document(self):
        first = replay.derive_idempotency_key("s8p4", "baseline-0001", "run42")
        again = replay.derive_idempotency_key("s8p4", "baseline-0001", "run42")
        other = replay.derive_idempotency_key("s8p4", "baseline-0002", "run42")
        self.assertEqual(first, "s8p4-baseline-0001-run42")
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)


class StatusClassificationTests(unittest.TestCase):
    def test_completed_is_terminal(self):
        self.assertTrue(replay.is_terminal_status("COMPLETED"))
        self.assertTrue(replay.is_terminal_status("FAILED"))
        self.assertTrue(replay.is_terminal_status("REJECTED"))
        self.assertTrue(replay.is_terminal_status("EXTRACT_FAILED"))

    def test_extract_failed_variants_are_terminal(self):
        self.assertTrue(replay.is_terminal_status("EXTRACT_FAILED_TIMEOUT"))
        self.assertTrue(replay.is_terminal_status("EXTRACT_FAILED_ENCRYPTED"))

    def test_in_flight_statuses_are_not_terminal(self):
        for status in ("QUEUED", "UPLOADED", "PROCESSING"):
            self.assertFalse(replay.is_terminal_status(status), status)


class FixtureEmissionTests(unittest.TestCase):
    def test_both_texts_emit_case_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixtures = Path(tmp) / "fixtures"
            case_dir = replay.write_case_fixtures(
                fixtures, "baseline-0001", b"hola\n", b"hola\r\n"
            )
            self.assertIsNotNone(case_dir)
            self.assertEqual((case_dir / "legacy.txt").read_bytes(), b"hola\n")
            self.assertEqual((case_dir / "nuevo.txt").read_bytes(), b"hola\r\n")
            self.assertEqual(
                json.loads((case_dir / "case.json").read_text(encoding="utf-8")),
                {"corpus": True},
            )

    def test_one_missing_side_writes_no_partial_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixtures = Path(tmp) / "fixtures"
            self.assertIsNone(
                replay.write_case_fixtures(fixtures, "baseline-0002", b"hola\n", None)
            )
            self.assertIsNone(
                replay.write_case_fixtures(fixtures, "baseline-0003", None, b"hola\n")
            )
            self.assertFalse((fixtures / "baseline-0002").exists())
            self.assertFalse((fixtures / "baseline-0003").exists())


class RunMetricsTests(unittest.TestCase):
    def test_full_match_passes(self):
        metrics = replay.compute_run_metrics(
            docs_total=100,
            docs_compared=100,
            verdicts={"MATCH": 100},
            threshold=99.9,
        )
        self.assertEqual(metrics["parity_rate"], 100.0)
        self.assertEqual(metrics["corpus_error_rate"], 0.0)
        self.assertTrue(metrics["parity_pass"])
        self.assertTrue(metrics["error_rate_pass"])
        self.assertEqual(metrics["exit_code"], 0)

    def test_mismatch_blocks_parity(self):
        metrics = replay.compute_run_metrics(
            docs_total=100,
            docs_compared=100,
            verdicts={"MATCH": 99, "MISMATCH": 1},
            threshold=99.9,
        )
        self.assertFalse(metrics["parity_pass"])
        self.assertEqual(metrics["exit_code"], 1)

    def test_error_verdict_blocks_parity(self):
        metrics = replay.compute_run_metrics(
            docs_total=100,
            docs_compared=100,
            verdicts={"MATCH": 99, "ERROR": 1},
            threshold=99.9,
        )
        self.assertFalse(metrics["parity_pass"])
        self.assertEqual(metrics["exit_code"], 1)

    def test_below_threshold_blocks_parity(self):
        metrics = replay.compute_run_metrics(
            docs_total=100,
            docs_compared=100,
            verdicts={"MATCH": 99},
            threshold=99.9,
        )
        self.assertAlmostEqual(metrics["parity_rate"], 99.0)
        self.assertEqual(metrics["exit_code"], 1)

    def test_error_rate_at_threshold_fails(self):
        metrics = replay.compute_run_metrics(
            docs_total=1000,
            docs_compared=999,
            verdicts={"MATCH": 999},
            threshold=99.9,
        )
        self.assertEqual(metrics["corpus_error_rate"], 0.001)
        self.assertFalse(metrics["error_rate_pass"])
        self.assertEqual(metrics["exit_code"], 1)

    def test_error_rate_below_threshold_passes(self):
        metrics = replay.compute_run_metrics(
            docs_total=1000,
            docs_compared=1000,
            verdicts={"MATCH": 1000},
            threshold=99.9,
        )
        self.assertEqual(metrics["corpus_error_rate"], 0.0)
        self.assertTrue(metrics["error_rate_pass"])
        self.assertEqual(metrics["exit_code"], 0)


class PreflightManifestTests(unittest.TestCase):
    def test_missing_manifest_raises(self):
        with self.assertRaises(replay.PreflightError):
            replay.load_manifest(Path("/nonexistent/manifest.json"))

    def test_count_mismatch_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.json"
            path.write_text(
                json.dumps(
                    {"count": 2, "documents": [{"name": "one.pdf"}]}
                ),
                encoding="utf-8",
            )
            with self.assertRaises(replay.PreflightError):
                replay.load_manifest(path)

    def test_valid_manifest_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.json"
            path.write_text(
                json.dumps(
                    {
                        "count": 1,
                        "version": "v",
                        "documents": [{"name": "one.pdf", "path": "one.pdf"}],
                    }
                ),
                encoding="utf-8",
            )
            manifest = replay.load_manifest(path)
            self.assertEqual(manifest["count"], 1)


if __name__ == "__main__":
    unittest.main()
