TOOLS_IMAGE ?= omanywhere-tools
TOOLS = docker run --rm -v "$(CURDIR):/src" -w /src $(TOOLS_IMAGE)

.PHONY: lint tools shellcheck secrets secrets-staged hooks

lint: shellcheck secrets

tools:
	docker build -q -f tools/Containerfile -t $(TOOLS_IMAGE) tools >/dev/null

# Every tracked file whose first line is a sh or bash shebang.
shellcheck: tools
	$(TOOLS) sh -c "git ls-files -z | xargs -0 awk 'FNR == 1 && /^#!.*[/ ](ba)?sh\$$/ { print FILENAME } { nextfile }' | xargs -r shellcheck"

secrets-staged: GITLEAKS_ARGS = --staged
secrets secrets-staged: tools
	$(TOOLS) gitleaks git $(GITLEAKS_ARGS) --redact --no-banner

hooks:
	git config core.hooksPath .githooks
