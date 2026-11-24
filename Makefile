TOOLS_IMAGE ?= omanywhere-tools
# Read-only and offline. The repo sits at its own path, and git's common dir
# is mounted as well, so a linked worktree's .git file resolves too.
GIT_COMMON_DIR := $(shell git rev-parse --path-format=absolute --git-common-dir)
TOOLS = docker run --rm --network none -v "$(CURDIR):$(CURDIR):ro" \
	-v "$(GIT_COMMON_DIR):$(GIT_COMMON_DIR):ro" -w "$(CURDIR)" $(TOOLS_IMAGE)

.PHONY: lint tools shellcheck secrets secrets-staged hooks verify-base image test test-boot test-owner \
	test-desktop test-desktop-vm

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

# The repository root is the build context (.dockerignore trims it).
image: verify-base
	docker build -f image/Containerfile -t $(IMAGE) .

test: test-boot test-owner test-desktop

test-boot: image
	IMAGE=$(IMAGE) tests/boot.sh

test-owner: image
	IMAGE=$(IMAGE) tests/owner.sh

# OMANYWHERE_TEST_DEVICES gives the container its DRM card (see
# tests/desktop.sh); without it, the test checks the no-device case.
test-desktop: image
	IMAGE=$(IMAGE) tests/desktop.sh

# The CPU-only leg: tests/desktop.sh on a vkms card, in a KVM guest that loads
# vkms in its own kernel (tests/vm/run). Needs /dev/kvm and about 30 GB.
test-desktop-vm: image
	IMAGE=$(IMAGE) BASE_IMAGE=$(BASE_IMAGE) tests/vm/run
