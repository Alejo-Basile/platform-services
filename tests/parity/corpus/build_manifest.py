"""Generador reproducible del manifiesto del corpus S8 (S8-P4-01).

Escanea los PDFs del corpus, calcula SHA256 y tamaño de cada uno y emite un
manifiesto JSON versionado. El resultado es determinista salvo por el campo
``generated``, que se puede congelar con ``--generated`` para tests y CI.

Uso::

    python3 tests/parity/corpus/build_manifest.py \
        --pdf-dir tests/fixtures/pdf \
        --out tests/parity/corpus/manifest.json \
        --generated 2026-11-17T00:00:00Z \
        --version s8-expanded-1
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = "s8-corpus/v1"
DEFAULT_VERSION = "s8-expanded-1"
DEFAULT_PATTERN = "baseline-*.pdf"

# platform-services/ (este archivo vive en tests/parity/corpus/).
_REPO_ROOT = Path(__file__).resolve().parents[3]


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _posix_relative(path: Path, base_dir: Path) -> str:
    """Ruta relativa POSIX; si está fuera de base_dir, se conserva el nombre."""
    try:
        relative = path.resolve().relative_to(base_dir.resolve())
    except ValueError:
        return path.name
    return relative.as_posix()


def build_manifest(
    pdf_dir: Path,
    base_dir: Path | None = None,
    version: str = DEFAULT_VERSION,
    generated: str | None = None,
    pattern: str = DEFAULT_PATTERN,
) -> dict:
    """Construye el manifiesto sobre los PDFs ordenados lexicográficamente."""
    pdf_dir = Path(pdf_dir)
    base_dir = Path(base_dir) if base_dir is not None else _REPO_ROOT

    paths = sorted(pdf_dir.glob(pattern), key=lambda path: path.name)
    documents = []
    total_bytes = 0
    for path in paths:
        raw = path.read_bytes()
        size = len(raw)
        total_bytes += size
        documents.append(
            {
                "name": path.name,
                "path": _posix_relative(path, base_dir),
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": size,
            }
        )

    return {
        "schema_version": SCHEMA_VERSION,
        "version": version,
        "generated": generated or _utc_now(),
        "count": len(documents),
        "total_bytes": total_bytes,
        "documents": documents,
    }


def write_manifest(manifest: dict, out: Path) -> None:
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    out.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Genera el manifiesto reproducible del corpus S8"
    )
    parser.add_argument("--pdf-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--generated", default=None, help="ISO8601 UTC congelado")
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument(
        "--base-dir",
        type=Path,
        default=None,
        help="base para rutas relativas (por defecto la raíz del repo)",
    )
    args = parser.parse_args(argv)

    if not args.pdf_dir.is_dir():
        print(f"error: no existe el directorio {args.pdf_dir}", file=sys.stderr)
        return 2

    manifest = build_manifest(
        args.pdf_dir,
        base_dir=args.base_dir,
        version=args.version,
        generated=args.generated,
    )
    if manifest["count"] == 0:
        print(f"error: no hay PDFs en {args.pdf_dir}", file=sys.stderr)
        return 2

    write_manifest(manifest, args.out)
    print(
        f"manifest {args.out}: {manifest['count']} documentos, "
        f"{manifest['total_bytes']} bytes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
