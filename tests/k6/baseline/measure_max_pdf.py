#!/usr/bin/env python3
"""Mide el tamaño máximo de PDF aceptado por POST /pdf/process.

El monolito rechaza `len(contenido) >= max_size`; este script hace búsqueda binaria
contra una instancia en ejecución y reporta el mayor tamaño aceptado (HTTP 200).
No usa dependencias externas: multipart y HTTP con la librería estándar.

Uso:
    python3 measure_max_pdf.py [--base-url http://127.0.0.1:8000]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import urllib.error
import urllib.request
import uuid


def multipart(pdf: bytes, boundary: str) -> bytes:
    return (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="max-size.pdf"\r\n'
        "Content-Type: application/pdf\r\n\r\n"
    ).encode("ascii") + pdf + f"\r\n--{boundary}--\r\n".encode("ascii")


def post_pdf(base_url: str, pdf: bytes) -> tuple[int, str]:
    boundary = "----p4" + uuid.uuid4().hex
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/pdf/process",
        data=multipart(pdf, boundary),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, resp.read(200).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(300).decode("utf-8", "replace")


def padded_pdf(base: bytes, size: int) -> bytes:
    if size <= len(base):
        return base
    # Comentario PDF posterior a %%EOF: los parsers lo ignoran, el tamaño real sube.
    return base + b"\n%" + b"A" * (size - len(base) - 3) + b"\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--pdf", type=pathlib.Path, required=True)
    parser.add_argument("--low", type=int, default=1 * 1024 * 1024)
    parser.add_argument("--high", type=int, default=30 * 1024 * 1024)
    args = parser.parse_args()

    base = args.pdf.read_bytes()
    low, high = args.low, args.high
    accepted = None
    results = []

    while low <= high:
        mid = (low + high) // 2
        status, body = post_pdf(args.base_url, padded_pdf(base, mid))
        results.append({"size_bytes": mid, "status": status})
        print(json.dumps(results[-1]))
        if status == 200:
            accepted = mid
            low = mid + 1
        else:
            high = mid - 1

    print(
        json.dumps(
            {
                "max_accepted_bytes": accepted,
                "max_accepted_mib": round(accepted / 1024 / 1024, 6) if accepted else None,
                "checked": len(results),
            }
        )
    )


if __name__ == "__main__":
    main()
