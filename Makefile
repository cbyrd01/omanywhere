TOOLS_IMAGE ?= omanywhere-tools
# Read-only and offline. The repo sits at its own path, and git's common dir
# is mounted as well, so a linked worktree's .git file resolves too.
GIT_COMMON_DIR := $(shell git rev-parse --path-format=absolute --git-common-dir)
TOOLS = docker run --rm --network none -v "$(CURDIR):$(CURDIR):ro" \
	-v "$(GIT_COMMON_DIR):$(GIT_COMMON_DIR):ro" -w "$(CURDIR)" $(TOOLS_IMAGE)

.PHONY: lint tools shellcheck secrets secrets-staged hooks verify-base image test test-boot test-owner \
	test-session-logic test-cli test-desktop test-desktop-vm test-gliff test-gliff-vm test-host-vm

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

# The legs that need no device. The desktop's and gliff's legs need a card or
# /dev/kvm: test-desktop, test-desktop-vm, test-gliff and test-gliff-vm.
test: test-session-logic test-boot test-owner test-cli

# The desktop session's decisions, with no device (the image's Lua runs the
# monitor rules).
test-session-logic: image
	tests/session-logic.sh

test-boot: image
	IMAGE=$(IMAGE) tests/boot.sh

test-owner: image
	IMAGE=$(IMAGE) tests/owner.sh

# bin/omanywhere up, status, ssh-config and down, with no device.
test-cli: image
	IMAGE=$(IMAGE) tests/cli.sh

# OMANYWHERE_TEST_DEVICES gives the container its DRM card (see
# tests/desktop.sh), such as --device nvidia.com/gpu=all.
test-desktop: image
	IMAGE=$(IMAGE) tests/desktop.sh

# tests/desktop.sh in a KVM guest (tests/vm/run): a GPU no display server is
# master of (refused, then allowed), and the CPU-only leg on vkms, which the
# guest loads in its own kernel. Needs /dev/kvm and about 30 GB.
test-desktop-vm: image
	OMANYWHERE_VM_LEGS=desktop IMAGE=$(IMAGE) BASE_IMAGE=$(BASE_IMAGE) tests/vm/run

# A plain gliff client over ssh (tests/gliff.sh) on the container's card.
# OMANYWHERE_TEST_GPU is up's --gpu (auto, nvidia or dri), such as
# OMANYWHERE_TEST_GPU=auto on a host with NVIDIA's CDI spec.
test-gliff: image
	IMAGE=$(IMAGE) tests/gliff.sh

# tests/gliff.sh in the KVM guest, on vkms: the CPU-only leg.
test-gliff-vm: image
	OMANYWHERE_VM_LEGS=gliff IMAGE=$(IMAGE) BASE_IMAGE=$(BASE_IMAGE) tests/vm/run

# bin/omanywhere-host and up --gpu vkms (tests/host.sh) in the KVM guest, as its
# host, over two boots of a throwaway overlay of the guest's disk.
test-host-vm: image
	OMANYWHERE_VM_LEGS=host IMAGE=$(IMAGE) BASE_IMAGE=$(BASE_IMAGE) tests/vm/run
