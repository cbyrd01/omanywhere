TOOLS_IMAGE ?= omanywhere-tools
# Read-only and offline. The repo sits at its own path, and git's common dir
# is mounted as well, so a linked worktree's .git file resolves too.
GIT_COMMON_DIR := $(shell git rev-parse --path-format=absolute --git-common-dir)
TOOLS = docker run --rm --network none -v "$(CURDIR):$(CURDIR):ro" \
	-v "$(GIT_COMMON_DIR):$(GIT_COMMON_DIR):ro" -w "$(CURDIR)" $(TOOLS_IMAGE)

.PHONY: lint tools shellcheck secrets secrets-staged hooks verify-base image test test-boot test-owner

lint: shellcheck secrets

tools:
	docker build -q -f tools/Containerfile -t $(TOOLS_IMAGE) tools >/dev/null

# Every tracked file whose first line is a sh, bash, dash or ksh shebang.
shellcheck: tools
	$(TOOLS) sh -c "git ls-files -z | xargs -0 awk 'FNR == 1 && /^#!.*[\/ ](ba|da|k)?sh([ \t]|\$$)/ { print FILENAME } { nextfile }' | xargs -r shellcheck"

secrets-staged: GITLEAKS_ARGS = --staged
secrets secrets-staged: tools
	$(TOOLS) gitleaks git $(GITLEAKS_ARGS) --redact --no-banner

hooks:
	git config core.hooksPath .githooks

IMAGE ?= omanywhere:dev
# The base the Containerfile builds FROM, read from it so the ref lives in one place.
BASE_IMAGE := $(shell awk -F= '/^ARG BASE_IMAGE=/ { print $$2; exit }' image/Containerfile)

verify-base: tools
	TOOLS_IMAGE=$(TOOLS_IMAGE) scripts/verify-base $(BASE_IMAGE)

# package/ is the omanywhere-src build context: the package stage builds it.
image: verify-base
	docker build --build-context omanywhere-src=package -f image/Containerfile -t $(IMAGE) image

test: test-boot test-owner

test-boot: image
	IMAGE=$(IMAGE) tests/boot.sh

test-owner: image
	IMAGE=$(IMAGE) tests/owner.sh
