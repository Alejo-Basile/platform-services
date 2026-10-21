#!/usr/bin/env python3
"""Genera PDFs mínimos y válidos para los escenarios k6 y el smoke de P4.

Sin dependencias externas: construye un PDF 1.4 de una página con una línea de texto
y calcula la tabla xref real. El texto es único por archivo para evitar que la caché
por hash del monolito convierta la medición de extracción en una medición de cache hit.
"""

from __future__ import annotations

import argparse
import pathlib


def _pdf_bytes(text: str) -> bytes:
    content = f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET\n".encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
        ),
        b"<< /Length " + str(len(content)).encode("ascii") + b" >>\nstream\n" + content + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{index} 0 obj\n".encode("ascii") + body + b"\nendobj\n"

    xref_at = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for offset in offsets[1:]:
        out += f"{offset:010d} 00000 n \n".encode("ascii")
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref_at}\n%%EOF\n"
    ).encode("ascii")
    return bytes(out)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--prefix", default="baseline")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    for index in range(1, args.count + 1):
        # Texto único: incluye índice y run para que el hash cambie entre ejecuciones.
        text = f"PDF EXTRACTEXT {args.prefix} {index:04d}"
        target = args.out / f"{args.prefix}-{index:04d}.pdf"
        target.write_bytes(_pdf_bytes(text))
        print(target)


if __name__ == "__main__":
    main()
