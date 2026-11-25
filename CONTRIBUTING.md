# Contributing

Omanywhere is maintained by Christopher Byrd ([@cbyrd01](https://github.com/cbyrd01)).

## The rules

The five [rules in the README](README.md#rules) are binding: a change that breaks one won't be
merged. Two more:

- **Third-party code needs the maintainer's approval** before it is added. That is anything not
  from Arch Linux, Omarchy/Omacom, Hyprland, Apple or Anthropic: container images, packages
  outside Arch's and Omarchy's repositories, and tools. Open an issue and name it first.
- **No `privileged` mode, host cgroups or host networking.** If something seems to need them,
  open an issue instead.

## Making a change

Each change goes on its own branch and lands through a pull request.

Everything runs in containers, so the host needs only Docker and `make`. The tools (cosign,
gitleaks, shellcheck) come from Arch Linux's signed repositories, in a small image built from
`tools/Containerfile`.

```sh
make hooks   # once per clone: gitleaks scans each commit's staged changes
make lint    # shellcheck + gitleaks over the full history (what CI runs)
make image   # cosign-verify the Arch base, then build omanywhere:dev (image/Containerfile)
make test-boot    # boot the image under systemd with no privilege and check it (tests/boot.sh)
make test-owner   # the owner account, ssh, and recreating over the same volumes (tests/owner.sh)
make test-session-logic # the session's card, DRM master and monitor-rule decisions, no device
make test-cli     # bin/omanywhere up, status, ssh-config and down, no device (tests/cli.sh)
make test         # these four; the no-card desktop case is in tests/boot.sh
make test-desktop # the desktop session on a card (tests/desktop.sh): set
                  # OMANYWHERE_TEST_DEVICES, such as --device nvidia.com/gpu=all
make test-desktop-vm # the desktop in a KVM guest, never touching the host's display: a GPU
                     # nobody is master of (refused, then allowed), and a vkms card loaded in
                     # the guest's kernel (tests/vm/run; needs /dev/kvm and ~30 GB)
make test-gliff   # a plain gliff client over ssh (tests/gliff.sh): set
                  # OMANYWHERE_TEST_GPU, up's --gpu, such as auto on an NVIDIA CDI host
make test-gliff-vm # tests/gliff.sh in the KVM guest on vkms: the CPU-only leg
```

CI runs `make lint` and `make test` only, because its runners have no GPU, DRM card or
`/dev/kvm`. A pull request that touches the desktop session, the GPU paths or gliff should
include the results of the legs that need a device:

- `make test-desktop-vm` and `make test-gliff-vm` (a KVM guest; needs `/dev/kvm` and about
  30 GB);
- `make test-desktop` and `make test-gliff` on a GPU host, when the change concerns one.

## The base image

`image/Containerfile` pins Arch's official base image by digest (`ARG BASE_IMAGE`). Dependabot
doesn't update it. Bump it by hand: set the new tag and digest, keep its date at or before
Omarchy's stable snapshot (the Containerfile's comment says why), then run `make verify-base`
to check its signature before `make image`.
