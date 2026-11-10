# Makefile para platform-services (P4).
# Targets de calidad que replican el CI.

.PHONY: lint shellcheck yamllint syntax test-e2e-smoke

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
