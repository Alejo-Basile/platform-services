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

- T1 [S0/S1] baseline, tooling, contracts, and P4 documentation gaps — inline — partial
- T2 [S1/S2/S3] real worker chain, happy/error E2E, correlation, and state matrix — inline — partial
- T3 [S4] chaos scenarios and operational runbook validation — delegated — pending
- T4 [S5/S7] 1000-document load, 24-hour endurance, SLOs, rate-limit and ForwardAuth verification — delegated — pending
- T5 [S8] corpus replay, normalized-text parity, divergence alerts, and canary — delegated — pending
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
