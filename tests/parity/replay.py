"""Runner de replay dos caminos v1/v2 para el corpus S8 (S8-P4-02).

Recorre el manifiesto del corpus, obtiene el texto extraído por el monolito
(v1) y por el stack nuevo (v2), escribe los fixtures ``legacy.txt`` /
``nuevo.txt`` y delega la comparación en ``tests/parity/report.py``.

Solo se compara **texto extraído normalizado**: nunca códigos HTTP, cuerpos
de respuesta, latencias ni cabeceras. El contrato v2 es asíncrono y esas
diferencias son de diseño (``docs/paridad.md`` §5).

Uso::

    python3 tests/parity/replay.py \
        --manifest tests/parity/corpus/manifest.json \
        --v1-base http://localhost:9081 \
        --v2-base http://localhost:9080 \
        --out artifacts/parity/replay \
        --threshold 99.9 \
        --timeout 180 \
        --id-prefix s8p4
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence

from compare import ERROR, MATCH, MATCH_WITH_DIFF, MISMATCH, compare_texts
from normalize import CaseRules
from report import build_report

SCHEMA_VERSION = "s8-replay/v1"
DEFAULT_THRESHOLD = 99.9
DEFAULT_TIMEOUT = 180
DEFAULT_ERROR_RATE_THRESHOLD = 0.001
DEFAULT_POLL_INTERVAL = 2.0
EXIT_OK = 0
EXIT_FAIL = 1
EXIT_PREFLIGHT = 2

TERMINAL_STATUSES = frozenset({"COMPLETED", "FAILED", "REJECTED"})
CLEANUP_SKIPPED_MESSAGE = "cleanup skipped: no delete API"

_VERDICT_ORDER = (MATCH, MATCH_WITH_DIFF, MISMATCH, ERROR)


class PreflightError(RuntimeError):
    """Falla de preflight: manifiesto inválido o endpoint inalcanzable."""


class ReplayError(RuntimeError):
    """Falla de transporte o de protocolo durante el replay."""


# ---------------------------------------------------------------------------
# Utilidades puras (testeables sin red)
# ---------------------------------------------------------------------------
def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def derive_idempotency_key(prefix: str, stem: str, run_id: str) -> str:
    """Clave determinista por documento y corrida."""
    return f"{prefix}-{stem}-{run_id}"


def make_run_id() -> str:
    return utc_now().replace(":", "").replace("-", "") + "-" + secrets.token_hex(3)


def is_terminal_status(status: str | None) -> bool:
    """Verdadero si el estado v2 ya no va a cambiar."""
    if not status:
        return False
    return status in TERMINAL_STATUSES or status.startswith("EXTRACT_FAILED")


def encode_multipart(
    fields: Mapping[str, str] | Sequence[tuple[str, str]],
    file_field: str,
    filename: str,
    file_bytes: bytes,
    content_type: str = "application/pdf",
    boundary: str | None = None,
) -> tuple[bytes, str]:
    """Codifica ``multipart/form-data`` con los campos antes que el archivo.

    No depende de terceros: arma el cuerpo a mano para no agregar
    dependencias. El orden de ``fields`` se preserva (el orden importa para
    las políticas S3 aunque MinIO lo tolere).
    """
    boundary = boundary or ("----s8replay" + secrets.token_hex(16))
    items = list(fields.items()) if isinstance(fields, Mapping) else list(fields)

    chunks: list[bytes] = []
    for name, value in items:
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8")
        )
        chunks.append(str(value).encode("utf-8"))
        chunks.append(b"\r\n")

    chunks.append(f"--{boundary}\r\n".encode("utf-8"))
    chunks.append(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'.encode(
            "utf-8"
        )
    )
    chunks.append(f"Content-Type: {content_type}\r\n\r\n".encode("utf-8"))
    chunks.append(file_bytes)
    chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))

    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def write_case_fixtures(
    fixtures_root: Path, stem: str, legacy: bytes | None, nuevo: bytes | None
) -> Path | None:
    """Escribe el par de textos y ``case.json`` solo si ambos existen.

    Si falta un lado no se deja un par incompleto: el runner lo registra como
    error del documento.
    """
    if legacy is None or nuevo is None:
        return None

    case_dir = Path(fixtures_root) / stem
    case_dir.mkdir(parents=True, exist_ok=True)
    (case_dir / "legacy.txt").write_bytes(legacy)
    (case_dir / "nuevo.txt").write_bytes(nuevo)
    (case_dir / "case.json").write_text(
        json.dumps({"corpus": True}) + "\n", encoding="utf-8"
    )
    return case_dir


def compute_run_metrics(
    docs_total: int,
    docs_compared: int,
    verdicts: Mapping[str, int],
    threshold: float,
    error_rate_threshold: float = DEFAULT_ERROR_RATE_THRESHOLD,
) -> dict:
    """Calcula tasa de paridad, tasa de error y veredicto de salida."""
    parity = int(verdicts.get(MATCH, 0)) + int(verdicts.get(MATCH_WITH_DIFF, 0))
    parity_rate = (
        round(parity * 100.0 / docs_compared, 4) if docs_compared else None
    )
    failed_docs = max(docs_total - docs_compared, 0)
    corpus_error_rate = round(failed_docs / docs_total, 6) if docs_total else None

    parity_pass = (
        docs_compared > 0
        and parity_rate is not None
        and parity_rate >= threshold
        and int(verdicts.get(MISMATCH, 0)) == 0
        and int(verdicts.get(ERROR, 0)) == 0
    )
    error_rate_pass = (
        corpus_error_rate is not None and corpus_error_rate < error_rate_threshold
    )
    exit_code = EXIT_OK if (parity_pass and error_rate_pass) else EXIT_FAIL

    return {
        "parity_rate": parity_rate,
        "parity_pass": parity_pass,
        "corpus_error_rate": corpus_error_rate,
        "error_rate_threshold": error_rate_threshold,
        "error_rate_pass": error_rate_pass,
        "exit_code": exit_code,
    }


def load_manifest(path: Path) -> dict:
    """Carga y valida el manifiesto; falla en preflight si no cuadra."""
    path = Path(path)
    if not path.is_file():
        raise PreflightError(f"no existe el manifiesto: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PreflightError(f"manifiesto ilegible {path}: {exc}") from exc

    documents = data.get("documents")
    if not isinstance(documents, list):
        raise PreflightError(f"manifiesto sin lista 'documents': {path}")
    if data.get("count") != len(documents):
        raise PreflightError(
            f"count={data.get('count')} no coincide con {len(documents)} documentos"
        )
    return data


# ---------------------------------------------------------------------------
# HTTP (stdlib)
# ---------------------------------------------------------------------------
def _request(
    url: str,
    method: str = "GET",
    data: bytes | None = None,
    headers: Mapping[str, str] | None = None,
    timeout: float = 30.0,
) -> tuple[int, bytes, dict]:
    """Request HTTP que devuelve (status, body, headers) incluso en 4xx/5xx."""
    request = urllib.request.Request(url, data=data, method=method, headers=dict(headers or {}))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), dict(exc.headers or {})
    except (urllib.error.URLError, OSError) as exc:
        raise ReplayError(f"{method} {url} falló: {exc}") from exc


def _request_json(
    url: str,
    method: str = "GET",
    payload: dict | None = None,
    headers: Mapping[str, str] | None = None,
    timeout: float = 30.0,
) -> tuple[int, dict]:
    body = None
    merged = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        merged["Content-Type"] = "application/json"
    merged.update(headers or {})
    status, raw, _ = _request(url, method=method, data=body, headers=merged, timeout=timeout)
    try:
        parsed = json.loads(raw.decode("utf-8")) if raw else {}
    except (UnicodeDecodeError, json.JSONDecodeError):
        parsed = {}
    return status, parsed


def probe_endpoint(base: str, timeout: float = 5.0) -> None:
    """Preflight: cualquier respuesta HTTP cuenta como endpoint alcanzable."""
    url = base.rstrip("/") + "/"
    try:
        _request(url, method="GET", timeout=timeout)
    except ReplayError as exc:
        raise PreflightError(f"endpoint inalcanzable {base}: {exc}") from exc


# ---------------------------------------------------------------------------
# Caminos v1 / v2
# ---------------------------------------------------------------------------
def run_v1(v1_base: str, filename: str, pdf_bytes: bytes, timeout: float) -> tuple[int, bytes]:
    """POST /pdf/process multipart; 200 devuelve el TXT (streaming, no JSON)."""
    body, content_type = encode_multipart(
        [], file_field="file", filename=filename, file_bytes=pdf_bytes
    )
    status, raw, _ = _request(
        v1_base.rstrip("/") + "/pdf/process",
        method="POST",
        data=body,
        headers={"Content-Type": content_type},
        timeout=timeout,
    )
    return status, raw


def run_v2(
    v2_base: str,
    filename: str,
    pdf_bytes: bytes,
    idempotency_key: str,
    timeout: float,
    poll_interval: float = DEFAULT_POLL_INTERVAL,
) -> tuple[str, bytes | None, str]:
    """Crea, sube, espera estado terminal y descarga el TXT del stack nuevo.

    Devuelve ``(status, txt_bytes, detail)``. ``txt_bytes`` es ``None`` si el
    estado terminal no es ``COMPLETED``.
    """
    base = v2_base.rstrip("/")

    status, created = _request_json(
        base + "/api/v2/documents",
        method="POST",
        payload={"idempotency_key": idempotency_key, "size_bytes": len(pdf_bytes)},
        headers={"X-Correlation-Id": idempotency_key},
        timeout=timeout,
    )
    if status not in (200, 201):
        raise ReplayError(f"create HTTP {status}")
    document_id = created.get("id") or created.get("document_id")
    upload_url = created.get("upload_url")
    form_fields = created.get("form_fields") or {}
    if not document_id or not upload_url:
        raise ReplayError("respuesta create incompleta (id/upload_url)")

    upload_body, upload_content_type = encode_multipart(
        form_fields, file_field="file", filename=filename, file_bytes=pdf_bytes
    )
    upload_status, _, _ = _request(
        upload_url,
        method="POST",
        data=upload_body,
        headers={"Content-Type": upload_content_type},
        timeout=timeout,
    )
    if not 200 <= upload_status < 300:
        raise ReplayError(f"upload HTTP {upload_status}")

    deadline = datetime.now(timezone.utc).timestamp() + timeout
    status_value = "QUEUED"
    while True:
        poll_status, document = _request_json(
            f"{base}/api/v2/documents/{document_id}", timeout=timeout
        )
        if poll_status == 200 and document.get("status"):
            status_value = document["status"]
        if is_terminal_status(status_value):
            break
        if datetime.now(timezone.utc).timestamp() >= deadline:
            return status_value, None, f"timeout esperando estado terminal ({status_value})"
        time.sleep(poll_interval)

    if status_value != "COMPLETED":
        return status_value, None, f"estado terminal {status_value}"

    download_status, download = _request_json(
        f"{base}/api/v2/documents/{document_id}/download", timeout=timeout
    )
    if download_status != 200:
        raise ReplayError(f"download endpoint HTTP {download_status}")
    download_url = download.get("download_url")
    if not download_url:
        raise ReplayError("download sin download_url")

    txt_status, txt_bytes, _ = _request(download_url, timeout=timeout)
    if txt_status != 200:
        raise ReplayError(f"descarga presignada HTTP {txt_status}")
    return status_value, txt_bytes, f"id={document_id}"


def cleanup_document(v2_base: str, document_id: str, timeout: float) -> bool:
    """Intenta borrar el documento v2; ``False`` si no hay API de borrado."""
    try:
        status, _ = _request_json(
            v2_base.rstrip("/") + f"/api/v2/documents/{document_id}",
            method="DELETE",
            timeout=timeout,
        )
    except ReplayError:
        return False
    return 200 <= status < 300


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def _build_run_summary(
    *,
    run_id: str,
    started_at: str,
    finished_at: str,
    manifest_path: Path,
    manifest: dict,
    v1_base: str,
    v2_base: str,
    docs_total: int,
    v1_ok: int,
    v1_errors: int,
    v2_ok: int,
    v2_errors: int,
    report_summary: dict,
    threshold: float,
    failed_documents: list[dict],
) -> dict:
    verdicts = {verdict: report_summary.get(verdict.lower(), 0) for verdict in _VERDICT_ORDER}
    docs_compared = int(report_summary.get("casos_corpus", 0))
    metrics = compute_run_metrics(
        docs_total=docs_total,
        docs_compared=docs_compared,
        verdicts=verdicts,
        threshold=threshold,
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "started_at": started_at,
        "finished_at": finished_at,
        "manifest": {
            "path": str(manifest_path),
            "count": manifest.get("count"),
            "version": manifest.get("version"),
        },
        "endpoints": {"v1": v1_base, "v2": v2_base},
        "docs_total": docs_total,
        "v1_ok": v1_ok,
        "v1_errors": v1_errors,
        "v2_ok": v2_ok,
        "v2_errors": v2_errors,
        "docs_compared": docs_compared,
        "parity_rate": metrics["parity_rate"],
        "threshold": threshold,
        "parity_pass": metrics["parity_pass"],
        "corpus_error_rate": metrics["corpus_error_rate"],
        "error_rate_threshold": metrics["error_rate_threshold"],
        "error_rate_pass": metrics["error_rate_pass"],
        "verdicts": verdicts,
        "failed_documents": failed_documents,
        "exit_code": metrics["exit_code"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Replay dos caminos v1/v2 sobre el corpus S8 (solo compara texto extraído)"
    )
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--v1-base", default="http://localhost:9081")
    parser.add_argument("--v2-base", default="http://localhost:9080")
    parser.add_argument("--out", type=Path, default=Path("artifacts/parity/replay"))
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--id-prefix", default="s8p4")
    parser.add_argument("--docs-limit", type=int, default=None, help="subconjunto para smoke")
    parser.add_argument("--cleanup", action="store_true", help="borra documentos v2 al terminar")
    parser.add_argument("--dry-run", action="store_true", help="valida manifiesto y endpoints; no crea nada")
    args = parser.parse_args(argv)

    # Preflight
    try:
        manifest = load_manifest(args.manifest)
        probe_endpoint(args.v1_base)
        probe_endpoint(args.v2_base)
    except PreflightError as exc:
        print(f"error: preflight: {exc}", file=sys.stderr)
        return EXIT_PREFLIGHT

    documents = list(manifest["documents"])
    if args.docs_limit is not None:
        documents = documents[: max(args.docs_limit, 0)]
    docs_total = len(documents)

    if args.dry_run:
        print(
            f"dry-run ok: manifest={args.manifest} count={manifest['count']} "
            f"seleccionados={docs_total} v1={args.v1_base} v2={args.v2_base}"
        )
        return EXIT_OK

    started_at = utc_now()
    run_id = make_run_id()
    out = args.out
    fixtures_dir = out / "fixtures"
    fixtures_dir.mkdir(parents=True, exist_ok=True)

    v1_ok = v1_errors = v2_ok = v2_errors = 0
    failed_documents: list[dict] = []
    cleanup_skip_logged = False

    for index, document in enumerate(documents, start=1):
        name = document["name"]
        stem = Path(name).stem
        pdf_path = Path(document.get("path") or name)
        if not pdf_path.is_file():
            pdf_path = Path(args.manifest).resolve().parents[3] / document.get("path", name)
        v1_label = "-"
        v2_label = "-"
        verdict = "-"

        try:
            pdf_bytes = pdf_path.read_bytes()
        except OSError as exc:
            v1_errors += 1
            failed_documents.append(
                {"name": name, "stage": "source", "detail": f"no se pudo leer {pdf_path}: {exc}"}
            )
            print(f"[{index:04d}/{docs_total:04d}] {name} v1=error v2=- verdict=ERROR")
            continue

        legacy: bytes | None = None
        try:
            v1_status, v1_body = run_v1(args.v1_base, name, pdf_bytes, args.timeout)
            v1_label = str(v1_status)
            if v1_status == 200:
                legacy = v1_body
                v1_ok += 1
            elif v1_status == 409:
                v1_errors += 1
                failed_documents.append(
                    {"name": name, "stage": "v1", "detail": "duplicate (HTTP 409)"}
                )
            else:
                v1_errors += 1
                failed_documents.append(
                    {"name": name, "stage": "v1", "detail": f"HTTP {v1_status}"}
                )
        except ReplayError as exc:
            v1_errors += 1
            v1_label = "error"
            failed_documents.append({"name": name, "stage": "v1", "detail": str(exc)})

        if legacy is None:
            print(f"[{index:04d}/{docs_total:04d}] {name} v1={v1_label} v2=- verdict=ERROR")
            continue

        nuevo: bytes | None = None
        try:
            idempotency_key = derive_idempotency_key(args.id_prefix, stem, run_id)
            v2_status, nuevo, detail = run_v2(
                args.v2_base, name, pdf_bytes, idempotency_key, args.timeout
            )
            v2_label = v2_status
            if v2_status == "COMPLETED" and nuevo is not None:
                v2_ok += 1
            else:
                v2_errors += 1
                failed_documents.append(
                    {"name": name, "stage": "v2", "detail": detail or v2_status}
                )
            if args.cleanup and detail.startswith("id="):
                document_id = detail.split("=", 1)[1]
                if not cleanup_document(args.v2_base, document_id, args.timeout) and not cleanup_skip_logged:
                    print(CLEANUP_SKIPPED_MESSAGE)
                    cleanup_skip_logged = True
        except ReplayError as exc:
            v2_errors += 1
            v2_label = "error"
            failed_documents.append({"name": name, "stage": "v2", "detail": str(exc)})

        if nuevo is None:
            print(f"[{index:04d}/{docs_total:04d}] {name} v1={v1_label} v2={v2_label} verdict=ERROR")
            continue

        verdict = compare_texts(legacy, nuevo, CaseRules()).verdict
        write_case_fixtures(fixtures_dir, stem, legacy, nuevo)
        print(f"[{index:04d}/{docs_total:04d}] {name} v1={v1_label} v2={v2_label} verdict={verdict}")

    # Reporte de paridad reutilizando report.py (no se reimplementa la lógica).
    if docs_total:
        parity_report = build_report(fixtures_dir, threshold=args.threshold)
    else:
        parity_report = {
            "summary": {
                "casos_corpus": 0,
                "match": 0,
                "match_with_diff": 0,
                "mismatch": 0,
                "error": 0,
            }
        }
    _write_json(out / "parity-report.json", parity_report)

    finished_at = utc_now()
    run_summary = _build_run_summary(
        run_id=run_id,
        started_at=started_at,
        finished_at=finished_at,
        manifest_path=args.manifest,
        manifest=manifest,
        v1_base=args.v1_base,
        v2_base=args.v2_base,
        docs_total=docs_total,
        v1_ok=v1_ok,
        v1_errors=v1_errors,
        v2_ok=v2_ok,
        v2_errors=v2_errors,
        report_summary=parity_report["summary"],
        threshold=args.threshold,
        failed_documents=failed_documents,
    )
    _write_json(out / "run-summary.json", run_summary)

    print("==== replay summary ====")
    print(
        f"run_id={run_id} docs_total={docs_total} docs_compared={run_summary['docs_compared']}"
    )
    print(
        f"v1_ok={v1_ok} v1_errors={v1_errors} v2_ok={v2_ok} v2_errors={v2_errors}"
    )
    print(
        f"parity_rate={run_summary['parity_rate']} threshold={args.threshold} "
        f"parity_pass={run_summary['parity_pass']}"
    )
    print(
        f"corpus_error_rate={run_summary['corpus_error_rate']} "
        f"error_rate_pass={run_summary['error_rate_pass']}"
    )
    print(f"verdicts={run_summary['verdicts']}")
    if failed_documents:
        print(f"failed_documents={len(failed_documents)}")
    print(f"artifacts={out}")
    print(f"exit_code={run_summary['exit_code']}")
    return run_summary["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
