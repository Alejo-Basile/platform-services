"""Tests del comparador de paridad (S0-P4-06 §3, S8-P4-02).

Se compara solo el texto extraído normalizado. Nunca códigos ni cuerpos HTTP:
el contrato nuevo es asíncrono y las respuestas difieren por diseño.
"""

import unittest

from compare import (
    ERROR,
    MATCH,
    MATCH_WITH_DIFF,
    MISMATCH,
    compare_texts,
)
from normalize import CaseRules


class MatchTests(unittest.TestCase):
    def test_identical_texts_match(self):
        result = compare_texts(b"Factura\nTotal: 100\n", b"Factura\nTotal: 100\n")
        self.assertEqual(result.verdict, MATCH)
        self.assertEqual(result.diff, "")

    def test_crlf_vs_lf_match(self):
        result = compare_texts(b"Factura\nTotal: 100\n", b"Factura\r\nTotal: 100\r\n")
        self.assertEqual(result.verdict, MATCH)

    def test_whitespace_differences_match(self):
        legacy = "Factura\t\nN\u00famero:   123  \n\n\n".encode("utf-8")
        nuevo = "Factura\nN\u00famero: 123\n".encode("utf-8")
        self.assertEqual(compare_texts(legacy, nuevo).verdict, MATCH)

    def test_scanned_document_without_text_matches_when_both_empty(self):
        result = compare_texts(b"", b"")
        self.assertEqual(result.verdict, MATCH)


class MatchWithDiffTests(unittest.TestCase):
    def test_page_number_removed_by_case_rule(self):
        legacy = "P\u00e1gina 1\n\nTexto".encode("utf-8")
        nuevo = "Texto".encode("utf-8")
        result = compare_texts(legacy, nuevo, CaseRules(drop_page_numbers=True))
        self.assertEqual(result.verdict, MATCH_WITH_DIFF)
        self.assertIn("P\u00e1gina 1", result.diff)
        self.assertIn("P\u00e1gina 1", result.removed_lines)

    def test_identical_page_number_on_both_sides_is_plain_match(self):
        text = "P\u00e1gina 1\n\nTexto".encode("utf-8")
        result = compare_texts(text, text, CaseRules(drop_page_numbers=True))
        self.assertEqual(result.verdict, MATCH)


class MismatchTests(unittest.TestCase):
    def test_digit_vs_letter_is_mismatch(self):
        result = compare_texts(b"Total: 100\n", b"Total: 1OO\n")
        self.assertEqual(result.verdict, MISMATCH)
        self.assertIn("Total: 100", result.diff)
        self.assertIn("Total: 1OO", result.diff)

    def test_missing_text_is_mismatch(self):
        result = compare_texts(b"Factura\nTotal: 100\n", b"Factura\n")
        self.assertEqual(result.verdict, MISMATCH)


class ErrorTests(unittest.TestCase):
    def test_invalid_encoding_is_error_not_mismatch(self):
        result = compare_texts(b"\xff\xfeTotal: 100\n", b"Total: 100\n")
        self.assertEqual(result.verdict, ERROR)
        self.assertIn("UTF-8", result.detail)


if __name__ == "__main__":
    unittest.main()
