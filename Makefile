# Makefile para platform-services (P4).
# Targets de calidad que replican el CI (jobs `lint`, `openapi` y `rate-limiter` de ci.yml).

.PHONY: lint shellcheck yamllint syntax test-e2e-smoke test-rate-limiter openapi-lint govulncheck build-image verify-image-user scan-image build-slo-exporter

lint: shellcheck yamllint syntax

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck no instalado"; exit 1; }
	git ls-files '*.sh' -z | xargs -0 shellcheck
	@echo "shellcheck OK"

yamllint:
	@command -v yamllint >/dev/null 2>&1 || { echo "yamllint no instalado"; exit 1; }
	yamllint -d relaxed .
	@echo "yamllint OK"

syntax:
	@for f in $$(git ls-files '*.sh'); do \
		bash -n "$$f" || { echo "ERROR de sintaxis en $$f"; exit 1; }; \
	done
	@echo "bash -n OK"

test-e2e-smoke:
	./tests/e2e/run.sh smoke

# Rate limiter (Go): paridad local del job `rate-limiter` de ci.yml.
test-rate-limiter:
	cd rate-limiter && go vet ./... && go test ./...
	@echo "rate-limiter OK"

# Contrato OpenAPI v2: paridad con el job `openapi` de ci.yml.
openapi-lint:
	npx --yes @redocly/cli@2.66.1 lint openapi/documents.yaml
	@echo "openapi-lint OK"

# Escaneo de vulnerabilidades Go: paridad con el step `govulncheck` de ci.yml.
govulncheck:
	@command -v go >/dev/null 2>&1 || { echo "go no instalado"; exit 1; }
	cd rate-limiter && go install golang.org/x/vuln/cmd/govulncheck@latest
	cd rate-limiter && "$$(go env GOPATH)/bin/govulncheck" ./...
	@echo "govulncheck OK"

# Imagen no-root de ratelimitd: paridad con el step "Build de imagen no-root" de ci.yml.
build-image:
	docker build -t ratelimitd:ci rate-limiter
	@echo "imagen ratelimitd:ci OK"

# Usuario no-root 10001:10001: paridad con el step "Verificar usuario no-root" de ci.yml.
verify-image-user: build-image
	@user="$$(docker image inspect -f '{{.Config.User}}' ratelimitd:ci)"; \
	test "$$user" = "10001:10001" || { echo "usuario inesperado: $${user}"; exit 1; }; \
	echo "usuario de imagen: $${user}"

# Escaneo de imagen CRITICAL/HIGH (exit 1): paridad con el step trivy de ci.yml.
scan-image: build-image
	@command -v trivy >/dev/null 2>&1 || { echo "trivy no instalado"; exit 1; }
	trivy image --severity CRITICAL,HIGH --exit-code 1 ratelimitd:ci
	@echo "scan-image OK"

# slo-exporter: build local de cordura (aún sin job en CI).
build-slo-exporter:
	@command -v go >/dev/null 2>&1 || { echo "go no instalado"; exit 1; }
	cd slo-exporter && go build ./...
	@echo "slo-exporter OK"
