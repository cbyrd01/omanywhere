# Contributing

Omanywhere is maintained by Christopher Byrd ([@cbyrd01](https://github.com/cbyrd01)).

## The rules

The five [rules in the README](README.md#rules) are binding. In short: Omarchy stays stock,
the base image is official and verified, the container follows best practice, the GPU is
optional, and fixes go upstream first. A change that breaks one of them won't be merged.

- **Fix things upstream first.** If Omarchy, Hyprland or gliff needs a change, propose it there
  before adding a workaround here, and write the reason (and the upstream link, once there is
  one) next to the workaround.
- **Third-party code needs the maintainer's approval** before it is added. That is anything not
  from Arch Linux, Omarchy/Omacom, Hyprland, Apple or Anthropic: container images, packages
  outside Arch's and Omarchy's repositories, and tools. Open an issue and name it first.
- **Never weaken signature checks.** Package signatures (`SigLevel`) stay required, and the base
  image is always cosign-verified.
- **No `privileged` mode, host cgroups or host networking.** If something seems to need them,
  open an issue instead.

## Making a change

Each change goes on its own branch and lands through a pull request.

```sh
make hooks   # once per clone: gitleaks scans each commit's staged changes
make lint    # shellcheck and gitleaks, as CI runs them
make test    # build the image and run the legs that need no device
```

CI runs `make lint` and `make test` only, because its runners have no GPU, DRM card or
`/dev/kvm`. A pull request that touches the desktop session, the GPU paths or gliff should
include the results of the legs that need a device:

- `make test-desktop-vm` and `make test-gliff-vm` (a KVM guest; needs `/dev/kvm` and about
  30 GB);
- `make test-desktop` and `make test-gliff` on a GPU host, when the change concerns one.

The README's [Development](README.md#development) section describes each target.

## The base image

`image/Containerfile` pins Arch's official base image by digest (`ARG BASE_IMAGE`). Dependabot
doesn't update it; bump it by hand: set the new tag and digest, keep its date at or before
Omarchy's stable snapshot (the Containerfile's comment says why), then run `make verify-base`
to check its signature before `make image`.
