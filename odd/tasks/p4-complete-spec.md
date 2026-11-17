# P4 completo según SPEC.md
Branch: feat/p4-k6-gateway-runner
Delivery: work units, tests and evidence kept together; no scope recuts
Runner: Docker Compose, Go tests, k6, Schemathesis, ShellCheck, yamllint, Redocly

## Specs

### S1 — Alcance autorizado
User request: "Genera el plan y ejecutalo"
User decision: "se exige alcance completo de SPEC.md"
The full P4 scope includes all P4 tasks in `infra/docs/SPEC.md`, including the previously deferred S5 load/endurance/SLO work and the S8-S10 migration, canary, rollback, handover, and v1 shutdown work. No mocks may replace the real worker path.

### S2 — Acceptance gates
1. Tooling and Compose environment are reproducible and all applicable checks run.
2. The real worker path completes create → upload → webhook → relay → extraction → `.txt` → `COMPLETED` → download.
3. P4 E2E, error, correlation, state-matrix, chaos, load, endurance, rate-limit, replay, canary, migration, rollback, handover, and cutover evidence satisfies each task's DoD in `infra/docs/SPEC.md`.
4. Every completed task records command, result, evidence path, and known limitations; blocked work remains explicitly blocked with its dependency.

## Tasks

- T1 [S0/S1] baseline, tooling, contracts, and P4 documentation gaps — inline — partial (missing: S0-P4-01/03/06/07 signatures and real access logs; ADR-0018 still Proposed)
- T2 [S1/S2/S3] real worker chain, happy/error E2E, correlation, and state matrix — inline — in progress (local chain 1/1 COMPLETED after #68; CI e2e does not start or exercise the worker; correlation and state matrix not re-run since G-B closure)
- T3 [S4] chaos scenarios and operational runbook validation — delegated — partial (chaos campaign reached 6/10 at L14; worker-dependent cases still unimplemented)
- T4 [S5/S7] 1000-document load, 24-hour endurance, SLOs, rate-limit and ForwardAuth verification — delegated — partial (S7-P4-03/04/05 and S2-P4-02 closed; S5-P4-01/02/03 pending)
- T5 [S8] corpus replay, normalized-text parity, divergence alerts, and canary — delegated — partial (normalize/compare/report + fixtures + CI on main; real corpus lives in open PR #19; canary only at 1% in infra)
- T6 [S9/S10] rollback, client migration, grace period, handover, v1 deprecation and shutdown — delegated — pending
- T7 [ALL] final evidence, differential checks, and release-readiness report — inline — pending

## Log

L1: "identifica las tareas restantes de P4, genera un plan de accion para completarlas,utiliza subagentes segun sea necesario"
L2: "se exige alcance completo de SPEC.md"
L3: "Genera el plan y ejecutalo"
L4: Current baseline: `doc-service` was fast-forwarded to `115f57b`; `infra` was already current at `f2b8924`; `platform-services` has pre-existing local changes and must not be overwritten.
L5: Prior checks: P4 smoke and k6 health passed; k6 create failed with mostly 429 responses; happy, error, and chain harnesses timed out; Go, ShellCheck, yamllint, Schemathesis, and Redocly were unavailable in the environment.
L6: Route declaration: T1 and T7 inline; T2-T6 delegated only when their dependency gates are independently satisfied and their edit surfaces are disjoint.
L7: Baseline execution: `make lint` passed ShellCheck, yamllint, and bash syntax (yamllint emitted existing line-length warnings); rate-limiter `go test ./...` passed; doc-service Go tests and extraction-worker Rust tests exceeded the bounded execution window while compiling/downloading dependencies.
L8: Environment: Go 1.26.10, ShellCheck, yamllint, Schemathesis 4.33.4, and Redocly CLI were installed into user/temp tool locations; no repository source was changed by setup.
L9: Fixes applied during execution: aligned the local MinIO webhook secret file with `.env`; raised Mongo `pids_limit` from 200 to 512 after `pthread_create` health failures; made the notification init read its mounted secrets; made the relay persist `UPLOADED→QUEUED` before enqueue; fixed the chain harness to check `extracted-txt/<txt_ref>`; made the happy harness tolerate a worker that consumes the stream immediately.
L10: Verification: ShellCheck/yamllint/syntax passed; Schemathesis generated 1000/1000 passing cases with a warning for download test data; rate-limiter Go tests passed; one real S3 chain run passed through `COMPLETED` and download prerequisites. Full happy/error/chaos/load/endurance/replay/canary/cutover evidence is still pending.
L11: Blocking evidence: the running Compose stack had an invalid/stale Change Stream resume token and lost an event while restarting the watcher; the happy harness then timed out during initialization/stream progression. Long Go/Rust builds exceeded bounded command windows under host resource pressure.
L12: Rerun after remote verification: `doc-service`, `infra`, and `extraction-worker` matched their `origin/main`; local `platform-services` branch was intentionally not fast-forwarded because it is dirty and one commit ahead/behind. A detached worktree at `origin/main` validated the new Postman collection JSON and lint. On the local fixed stack: smoke passed, chain passed 10/10, Schemathesis passed 1000/1000, non-chaos errors passed 4/4 with 4 worker-fixture blocks, chaos errors passed 7/7 with one known relay issue and 3 worker-fixture blocks, rate-limit gateway passed 100/100, and k6 create still failed because the 5-VU scenario exceeds the configured rate limit and receives 429. The full chaos harness still failed because it assumes an unconsumed Redis stream entry and cannot yet account for a real worker consuming/ACKing it.
L13: New execution plan: first make chaos assertions terminal-state/ACK aware; then parameterize k6 so functional traffic stays below the configured limit while a separate scenario asserts 429; then add deterministic worker fixtures/cases; finally rerun all P4 checks and preserve failures as evidence rather than relabeling expected behavior as a pass.
L14: Execution update: chaos harness now parses both flat and legacy stream payloads and accepts an ACKed entry only with Mongo COMPLETED evidence, one worker completion history entry, correlation_id, and extracted TXT. k6 functional smoke now uses constant-arrival-rate 5/s and pacing; the complete smoke passed health/create/state/list with zero failures. Gateway rate-limit validation remains separate and passed 100/100. The chaos campaign progressed through 6/10 iterations before the bounded run was terminated by host/process pressure; worker-dependent error fixtures remain unimplemented.
L15 (2026-11-17, scope decision): user: "p4-complete-spec es el que va, por lo demas arranca con tu plan". This document is the authoritative scope. The recuts in `plan-P4-S5.md` §0.2 and the closed plan in `odd/tasks/p4-ejecucion-platform.md` are subordinate and do not close SPEC tasks on their own.
L16 (2026-11-17, state reconciliation): all four repos fast-forwarded to `origin/main`; local P4 branches were squash-merged and their trees matched main, so checkouts moved to main. platform-services#18 (2026-11-16T21:58Z) and infra#68 (2026-11-17T05:22Z) are MERGED. Confirmed gap for T2/S3-P4-01: `.github/workflows/e2e.yml` has the extraction-worker checkout commented out and never runs `tests/e2e/chain/run.sh`; `tests/e2e/ci/smoke.sh` brings the stack up without `extraction-worker` (it lives in the `full` profile). The published image is public and `ghcr.io/alejo-basile/extraction-worker:sha-d3d8c80` matches extraction-worker main HEAD.
L17 (2026-11-17, route declaration): unit "CI e2e with the real worker + chain step" is inline (parent); edit surfaces `platform-services/.github/workflows/e2e.yml`, `platform-services/tests/e2e/ci/smoke.sh`, this document. Verification: yamllint, `bash -n`, `docker compose config -q`, and a local chain run against the running stack.
L18 (2026-11-17, unit CI-worker executed): `e2e.yml` pulls the published worker image (`EXTRACTION_WORKER_TAG`, default `latest`), `smoke.sh --ci` enables the `full` profile and starts/awaits `extraction-worker`, and a new step runs `tests/e2e/chain/run.sh` with `P4_CHAIN_RUNS` (default 1). Checks: yamllint OK (pre-existing line-length warnings), shellcheck OK, `bash -n` OK, `docker compose config -q --profile full` OK, local `smoke.sh` Gate A OK, local chain 1/1 PASS (`chain-1794937457-6d7f34c079f3` → COMPLETED with `.txt`). Limitation: the running stack is doc-service@722bae2, so this validates the harness and worker path, not the 3 newer doc-service commits. Local `infra/.env` lacked `DOCKER_GID`; `prepare-env.sh` (local mode) added it, which is what unblocked every compose call in the harness.
