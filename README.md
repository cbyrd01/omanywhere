# Omanywhere

Stock [Omarchy](https://omarchy.org) as a headless desktop in a container, reached over
[gliff](https://github.com/omacom/gliff), on hosts with a GPU and on hosts with only a CPU.
Think LinuxServer Webtop or Kasm Workspaces, but the desktop is an unmodified Omarchy.

An unofficial community project based on Arch Linux. It is not affiliated with or endorsed by
Omacom, Omarchy, Arch Linux, Hyprland or Docker. Omarchy is a pending trademark of its owners.

## Status

Version 0, experimental: the image, the owner account and ssh, the desktop session on a GPU or
a vkms card, and the `omanywhere` command. CI builds the image and runs the tests that need no
device.

There is no prebuilt image. `make image` builds it locally: the image is about 12 GB, and the
build needs about 30 GB of free disk. The host needs Docker 29 or newer and `make`. To connect,
you need a gliff client: [gliff](https://github.com/omacom/gliff) itself (Omarchy installs it
with its base packages), or another such as [Glifftop](https://github.com/cbyrd01/glifftop).

## Use

```sh
make image                     # build omanywhere:dev
bin/omanywhere up desk         # a container, omanywhere-desk, with your ssh agent's keys
bin/omanywhere ssh-config desk >>~/.ssh/config
gliff --headless omanywhere-desk
```

[docs/usage.md](docs/usage.md) covers the rest: the commands and their flags, GPU and CPU-only
hosts, DRM master, gliff, and troubleshooting.

## Host size

Estimates for one desktop, not yet tested at these limits:

| Host | Memory | CPU |
|---|---|---|
| With a GPU | 2 GB | 0.5 core |
| CPU-only (vkms) | 2 GB | 2 cores |

- Memory: an idle desktop with no client connected used 0.8 to 1.0 GiB (2026-11-24), on both
  kinds of host. A gliff session adds tens of MiB, which leaves about 1 GiB for apps. A browser
  with many tabs needs more.
- CPU with a GPU: rendering and encoding run on the GPU, and the idle container used under
  1% of one core.
- CPU-only: Hyprland with llvmpipe used 0.4 to 2.3 cores in an active session at 1060x618, and
  gliff's OpenH264 encoder 0.1 to 0.15. An active 1080p session costs more (see
  [CPU and GPU hosts](docs/usage.md#cpu-and-gpu-hosts)).

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

[docs/differences.md](docs/differences.md) lists every place the image differs from Arch's
image and a stock Omarchy install, and why.

## How it works

- `omanywhere-session.service` starts Omarchy's Hyprland for the owner under uwsm, in a logind
  session, in place of sddm.
- Hyprland needs a DRM card node, because aquamarine allocates its buffers through one even
  with no screen. Nothing reads `AQ_NO_KMS_REQUIREMENT`.
- On a GPU's card (`--device nvidia.com/gpu=all`, or `/dev/dri`), the connectors are the
  host's displays. The session turns every one of them off, at start and whenever one
  appears, and Hyprland draws on a headless output of its own.
- CPU-only hosts need a `vkms` card that the host loads, one per container. Its connector is
  the desktop's monitor. On a host with a desktop of its own, see docs/usage.md (DRM master).
- Without a usable card, the session is skipped. The journal and `docker logs` say why.
- The session refuses a GPU that no display server is DRM master of, because Hyprland would
  take master and turn the host's outputs off. On a host with no display of its own, set
  `OMANYWHERE_DRM_MASTER=allow`.
  - The session checks master again just before it starts Hyprland. Master can still change
    hands in the second between that check and Hyprland opening the card. That window can't
    be closed while Hyprland opens the card itself.
  - The real fix is upstream: a headless compositor that needs no card.
- A refused or skipped desktop stays down until the container restarts.
- gliff-server, already in Omarchy's base packages, captures the desktop and injects input
  through Wayland. The container needs no `uinput`, input devices or seat.
- Access is ssh only (`ssh host gliff-server --stdio`), with keys only, or with the password
  on a desktop made with `up --password` and no key. The session sets
  `GLIFF_VIDEO` and `GLIFF_CAPTURE` for the card it chose, through sshd, so a plain gliff
  client needs no flags.
- [Glifftop](https://github.com/cbyrd01/glifftop) or any other gliff client connects.

## The container's interface

`bin/omanywhere` runs the container much like this. To run it some other way, such as from
Compose, use the same flags:

```sh
docker run -d --tty --cgroupns=private --security-opt writable-cgroups=true \
  --security-opt seccomp=lib/seccomp.json \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp --tmpfs /run/secrets:mode=0700 \
  -v NAME-home:/home -v NAME-state:/var/lib/omanywhere \
  -v ./authorized_keys:/run/secrets/authorized_keys:ro [-v ./password:/run/secrets/password:ro] \
  -p 127.0.0.1:2222:22 [--device nvidia.com/gpu=all | --device /dev/dri] omanywhere:dev
```

[docs/usage.md](docs/usage.md#the-run-flags) explains each flag. There is no `--privileged`,
no `--cap-add`, and no host network or cgroups. The seccomp profile is Docker's default plus
namespaces for Chromium's sandbox, with netfilter kept out of reach.

The `omanywhere` package (`package/omanywhere/`) makes the owner account at boot from these
inputs (`package/omanywhere/owner` has the details):

- `OMANYWHERE_USER`, `OMANYWHERE_UID`, `TZ`, and `OMANYWHERE_DRM_MASTER`, with `docker run -e`;
- the ssh keys: the file `/run/secrets/authorized_keys`, or `OMANYWHERE_AUTHORIZED_KEYS`. With
  a password and no key, ssh takes the password instead; with keys, keys only;
- the optional password for sudo, polkit and the lock screen: only the file
  `/run/secrets/password`, bound read-only inside the root-only `/run/secrets` tmpfs as above
  (leave the `-v ./password:...` out for none). The owner unit fails if `OMANYWHERE_PASSWORD` is
  in the environment, where `docker inspect` and the host's process list would show it. With no
  password file, the owner's password is locked, sudo and polkit ask the owner for none, and
  Omarchy's idle lock is turned off in the owner's `shell.json` (restored when a password
  comes). `omanywhere up` has a password only when its config has a `password` file
  (`--password`).

The keys given to the container are authoritative, and are set again on every boot. sshd
reads them from `/run/omanywhere/authorized_keys/`. Keys that the owner adds to
`~/.ssh/authorized_keys` themselves are kept, and log in too, except on a password-only
desktop, where ssh takes only the password.

State lives in two named volumes:

- `/home`;
- `/var/lib/omanywhere`, which holds the machine-id and the ssh host key.

Use named volumes, which Docker fills from the image. A bind-mounted state directory starts
empty, so its first boot can't keep a machine-id and is degraded. From the second boot on it
behaves like a named volume.

## Development

Everything runs in containers; the host needs only Docker and `make`.
[CONTRIBUTING.md](CONTRIBUTING.md) says how to send a change, and [SECURITY.md](SECURITY.md)
how to report a vulnerability.

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

The image adds one package of its own, `omanywhere` (`package/omanywhere/`), built in the
image's `package` stage.

The tools (cosign, gitleaks, shellcheck) come from Arch Linux's signed repositories,
installed in a small image built from `tools/Containerfile`.

## License and credits

Omanywhere is under the MIT License ([LICENSE](LICENSE)). It is built on:

- [Omarchy](https://github.com/omacom/omarchy) (MIT);
- [gliff](https://github.com/omacom/gliff) (MIT);
- [Hyprland](https://github.com/hyprwm/Hyprland) (BSD-3-Clause);
- Arch Linux's official image.

The approach follows [try-omarchy](https://github.com/omacom/try-omarchy). The seccomp profile
derives from Moby's (Apache-2.0). [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the
third-party files in this repository and their licenses.
