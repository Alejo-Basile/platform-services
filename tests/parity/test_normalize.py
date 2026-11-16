"""Tests de la normalización de paridad (S0-P4-06 §2, S8-P4-02).

La normalización debe ser la misma para ambos caminos (v1 monolito y v2
stack nuevo). Estos tests fijan cada regla de §2 por separado.
"""

import unittest

from normalize import (
    NORMALIZER_VERSION,
    CaseRules,
    InvalidEncodingError,
    apply_case_rules,
    collapse_blank_lines,
    collapse_spaces,
    decode_utf8,
    is_page_number_line,
    normalize_bytes,
    normalize_newlines,
    normalize_text,
)


class DecodeTests(unittest.TestCase):
    def test_valid_utf8_decodes(self):
        self.assertEqual(decode_utf8("Factura".encode("utf-8")), "Factura")

    def test_invalid_utf8_raises(self):
        with self.assertRaises(InvalidEncodingError):
            decode_utf8(b"\xff\xfeTotal: 100\n")

    def test_normalize_bytes_propagates_encoding_error(self):
        with self.assertRaises(InvalidEncodingError):
            normalize_bytes(b"\xff")


class NewlineTests(unittest.TestCase):
    def test_crlf_and_cr_become_lf(self):
        self.assertEqual(normalize_newlines("a\r\nb\rc\n"), "a\nb\nc\n")


class SpaceTests(unittest.TestCase):
    def test_spaces_and_tabs_collapse_per_line(self):
        self.assertEqual(collapse_spaces("  a \t b  \n\tc\t\n"), "a b\nc\n")

    def test_only_ascii_space_and_tab_collapse(self):
        # §2.4 habla de espacios y tabulaciones: un NBSP no es espacio ASCII
        # y se conserva para no borrar diferencias reales.
        self.assertEqual(collapse_spaces("a\u00a0b"), "a\u00a0b")


class BlankLineTests(unittest.TestCase):
    def test_consecutive_blank_lines_collapse_to_one(self):
        self.assertEqual(collapse_blank_lines("a\n\n\n\nb\n\n\nc\n"), "a\n\nb\n\nc\n")


class NormalizeTextTests(unittest.TestCase):
    def test_nfc_composes_decomposed_accents(self):
        decomposed = "Nu\u0301mero: 123"  # u + combining acute
        self.assertEqual(normalize_text(decomposed), "N\u00famero: 123")

    def test_full_pipeline(self):
        raw = "Factura\t\r\n  N\u00famero:   123  \r\nTotal:\t100\r\n\r\n\r\n"
        self.assertEqual(
            normalize_text(raw),
            "Factura\nN\u00famero: 123\nTotal: 100",
        )

    def test_trailing_whitespace_is_removed(self):
        self.assertEqual(normalize_text("a\n\n\n"), "a")


class PageNumberTests(unittest.TestCase):
    def test_bare_number_is_page_number(self):
        self.assertTrue(is_page_number_line("12"))

    def test_page_label_is_page_number(self):
        self.assertTrue(is_page_number_line("P\u00e1gina 3"))
        self.assertTrue(is_page_number_line("Page 4"))

    def test_content_with_number_is_not_page_number(self):
        self.assertFalse(is_page_number_line("12 hojas"))


class CaseRulesTests(unittest.TestCase):
    def test_no_rules_keeps_text_untouched(self):
        text = "P\u00e1gina 1\n\nTexto"
        self.assertEqual(apply_case_rules(text, CaseRules()), (text, []))

    def test_drop_page_number_removes_line_and_leading_blank(self):
        text = "P\u00e1gina 1\n\nTexto"
        result, removed = apply_case_rules(text, CaseRules(drop_page_numbers=True))
        self.assertEqual(result, "Texto")
        self.assertEqual(removed, ["P\u00e1gina 1"])

    def test_repeated_header_is_removed(self):
        text = "Confidencial\nFactura\nConfidencial"
        rules = CaseRules(repeated_lines=("Confidencial",))
        result, removed = apply_case_rules(text, rules)
        self.assertEqual(result, "Factura")
        self.assertEqual(removed, ["Confidencial", "Confidencial"])

    def test_normalizer_version_is_declared(self):
        self.assertTrue(NORMALIZER_VERSION)


if __name__ == "__main__":
    unittest.main()
