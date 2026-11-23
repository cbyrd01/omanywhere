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

- Hyprland runs with `AQ_NO_KMS_REQUIREMENT=1` on a render node only (no card node, no outputs)
  and creates its own headless output.
- gliff-server (already in Omarchy's base packages) captures that output and injects input
  through Wayland, so the container needs no `uinput`, input devices or seat.
- Access is ssh only (`ssh host gliff-server --stdio`), with keys only and no published ports.
  [Glifftop](https://github.com/cbyrd01/glifftop) or any other gliff client connects.
- CPU-only hosts still need some DRM device today (for example `vkms`). See `notes/`.

## Development

Everything runs in containers; the host needs only Docker and `make`.

```sh
make hooks   # once per clone: gitleaks scans each commit's staged changes
make lint    # shellcheck + gitleaks over the full history (what CI runs)
```

The tools (cosign, gitleaks, shellcheck) come from Arch Linux's signed repositories,
installed in a small image built from `tools/Containerfile`.
