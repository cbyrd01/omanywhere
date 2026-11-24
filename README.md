# Omanywhere

Stock [Omarchy](https://omarchy.org) as a headless desktop in a container, reached over
[gliff](https://github.com/omacom/gliff), on hosts with a GPU and on hosts with only a CPU.
Think LinuxServer Webtop or Kasm Workspaces, but the desktop is an unmodified Omarchy.

An unofficial community project, not affiliated with Omacom or Omarchy.

## Status

Not started. The research and the approach are in `notes/` (local, not committed).

## Uses

- A cloud desktop per person.
- A shared GPU machine in a homelab or rack, one Omarchy per user.
- Disposable sandboxes for agents.
- Fast acceptance tests and CI for Omarchy work.
- Demo and classroom machines.

## Rules

1. **Omarchy stays stock.** Install the official `omarchy` packages from Omarchy's own signed
   repositories, unmodified. Add one package of our own (`omanywhere`) and change no file
   Omarchy owns, as [try-omarchy](https://github.com/omacom/try-omarchy) does.
2. **Start from official images.** Arch Linux's official OCI image, pinned by digest and
   cosign-verified. Package signatures are always required.
3. **Container best practice.** No `privileged` mode, no host cgroups, no host keys baked into
   the image, state only in volumes, and systemd run as systemd documents for containers.
4. **The GPU is optional.** One image. It gets a render node when the host has a GPU and
   renders and encodes on the CPU when it doesn't.
5. **Fix things upstream first.** If Omarchy, Hyprland or gliff needs a change, propose it there
   before adding a workaround here. Write the reason next to any workaround.

## How it should work

- `omanywhere-session.service` starts Omarchy's Hyprland for the owner under uwsm, in a logind
  session, in place of sddm. Hyprland needs a DRM card node: aquamarine allocates its buffers
  through one even with no screen, and nothing reads `AQ_NO_KMS_REQUIREMENT`. With a GPU's card
  (`--device nvidia.com/gpu=all`, or `/dev/dri`) every connector, the host's displays, is turned
  off and Hyprland creates its own headless output. Without a card the session is skipped, and
  the journal says which device is missing.
- gliff-server (already in Omarchy's base packages) captures that output and injects input
  through Wayland, so the container needs no `uinput`, input devices or seat.
- Access is ssh only (`ssh host gliff-server --stdio`), with keys only and no published ports.
  [Glifftop](https://github.com/cbyrd01/glifftop) or any other gliff client connects.
- CPU-only hosts still need some DRM device today: a `vkms` card the host loads, whose
  connector is then the desktop's monitor. See `notes/`.

## Development

Everything runs in containers; the host needs only Docker and `make`.

```sh
make hooks   # once per clone: gitleaks scans each commit's staged changes
make lint    # shellcheck + gitleaks over the full history (what CI runs)
make image   # cosign-verify the Arch base, then build omanywhere:dev (image/Containerfile)
make test-boot    # boot the image under systemd with no privilege and check it (tests/boot.sh)
make test-owner   # the owner account, ssh, and recreating over the same volumes (tests/owner.sh)
make test-desktop # the desktop session (tests/desktop.sh); with no DRM card, that it's skipped.
                  # OMANYWHERE_TEST_DEVICES gives it a card: see the top of tests/desktop.sh
make test         # all three
make test-desktop-vm # the desktop on a vkms card, in a KVM guest that loads vkms in its own
                     # kernel, never the host's (tests/vm/run; needs /dev/kvm and ~30 GB)
```

The image adds one package of its own, `omanywhere` (`package/omanywhere/`), built in the
image's `package` stage. It makes the owner account at boot from `OMANYWHERE_USER`,
`OMANYWHERE_UID`, `OMANYWHERE_AUTHORIZED_KEYS`, `OMANYWHERE_PASSWORD` and `TZ`, given with
`docker run -e` or as files under `/run/secrets/` (see `package/omanywhere/owner`).
The keys given to the container are authoritative and set again on every boot (sshd reads them
from `/run/omanywhere/authorized_keys/`); keys the owner adds to `~/.ssh/authorized_keys`
themselves are kept. State lives in two named volumes, `/home` and `/var/lib/omanywhere` (the
machine-id and the ssh host key); use named volumes, which Docker fills from the image. A
bind-mounted state directory starts empty, so its first boot can't keep a machine-id and is
degraded; from the second boot on it behaves like a named volume.

The tools (cosign, gitleaks, shellcheck) come from Arch Linux's signed repositories,
installed in a small image built from `tools/Containerfile`.
