# Omanywhere

Omanywhere runs a stock [Omarchy](https://omarchy.org) desktop in a container with no screen
attached. You connect to it over ssh with a [gliff](https://github.com/omacom/gliff) client,
such as gliff itself or [Glifftop](https://github.com/cbyrd01/glifftop). It runs on
hosts with a GPU and on hosts with only a CPU. It is in the same family as LinuxServer Webtop
and Kasm Workspaces, with an unmodified Omarchy as the desktop.

Omanywhere is an unofficial community project based on Arch Linux. It is not affiliated with or
endorsed by Omacom, Omarchy, Arch Linux, Hyprland or Docker. Omarchy is a pending trademark of
its owners.

## Status

Version 0, experimental: commands, flags and the image's layout may change. There is no
prebuilt image, so you build it yourself.

## Requirements

- A Linux host with Docker 29 or newer and `make`. The build needs about 30 GB of free disk,
  and the image is about 12 GB. On Arch, `sudo bin/omanywhere-host setup` prepares the host,
  and [`host/cloud-init.yaml`](host/cloud-init.yaml) does it all on a new cloud host (see
  [Setting up a host](docs/usage.md#setting-up-a-host)).
- A DRM card for the desktop: a GPU (NVIDIA through CDI, AMD or Intel), or, on a host with no
  GPU, a `vkms` card that the host loads. See
  [CPU and GPU hosts](docs/usage.md#cpu-and-gpu-hosts).
- A gliff client: [gliff](https://github.com/omacom/gliff) itself, which Omarchy installs, or
  another such as [Glifftop](https://github.com/cbyrd01/glifftop).

## Quick start

```sh
make image                      # build omanywhere:dev
bin/omanywhere up desk          # start omanywhere-desk with your ssh agent's keys
bin/omanywhere ssh-config desk >>~/.ssh/config
gliff --headless omanywhere-desk
```

`up` publishes ssh on `127.0.0.1` only. The keys that may log in come from your ssh agent,
`--key FILE` or `--github USER`. By default the owner has no password: sudo and polkit don't
ask for one, and the idle lock is off. `up --password` gives the owner one. The owner's home and
the container's identity live in two Docker volumes; `up --data DIR` keeps them in a directory
instead, where the host's backups reach them. `docker logs omanywhere-desk` shows the boot and
the container's warnings and errors, as `up` gives systemd a console.
[docs/usage.md](docs/usage.md) covers every command and flag, access from other machines, and
troubleshooting.

## Uses

- A cloud desktop per person.
- A shared GPU machine in a homelab or rack, one Omarchy per user.
- Disposable sandboxes for agents.
- Acceptance tests and CI for Omarchy work.
- Demo and classroom machines.

## Host size

Estimates for one desktop, not yet tested at these limits:

| Host | Memory | CPU |
|---|---|---|
| With a GPU | 2 GB | 0.5 core |
| CPU-only (vkms) | 2 GB | 2 cores |

- An idle desktop with no client connected used 0.8 to 1.0 GiB of memory on both kinds of
  host. That leaves about 1 GiB for apps; a browser with many tabs needs more.
- With a GPU, rendering and encoding run on the GPU, and the idle container used under 1% of
  one core.
- CPU-only, in an active session at 1060x618, Hyprland (llvmpipe) used 0.4 to 2.3 cores and
  gliff's encoder 0.1 to 0.15 cores. A 1080p session costs more.

## How it works

- A systemd unit starts Omarchy's Hyprland for the owner, under uwsm in a logind session,
  where a stock install would start sddm.
- Hyprland needs a DRM card even with no screen. On a GPU, the card's connectors are the
  host's displays, so the session keeps Hyprland off them and draws on a headless output. On
  a CPU-only host, the container's vkms card is its monitor.
- gliff-server, from Omarchy's base packages, captures the desktop and injects input through
  Wayland, so the container needs no input devices or seat. The container sets gliff's video
  and capture modes for its card, so a plain gliff client needs no flags.
- ssh is the only way in. It takes keys, or only the password on a
  [password-only desktop](docs/usage.md#password-only-desktops).
- The container runs with no `--privileged`, no added capabilities, and no host network or
  cgroups. Its seccomp profile is Docker's default plus the namespaces Chromium's sandbox
  needs. [The run flags](docs/usage.md#the-run-flags) explains each one, and how to run the
  image without `bin/omanywhere`.

## Security

- With no password, any program running as the owner can become root in the container. With
  rootful Docker, that is uid 0 on the host, confined only by the container's limits. Use
  `--password` where that matters.
- On a GPU that the host's own display also uses, a process in the container can take DRM
  master while no host display server holds it (at a text console, or logged out), and lock
  the host's display out. Don't run untrusted code there. See
  [DRM master](docs/usage.md#drm-master).

Report vulnerabilities privately, as [SECURITY.md](SECURITY.md) describes.

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

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers building, testing and sending a change.

## License and credits

Omanywhere is under the MIT License ([LICENSE](LICENSE)). It is built on:

- [Omarchy](https://github.com/omacom/omarchy) (MIT);
- [gliff](https://github.com/omacom/gliff) (MIT);
- [Hyprland](https://github.com/hyprwm/Hyprland) (BSD-3-Clause);
- Arch Linux's official image.

The approach follows [try-omarchy](https://github.com/omacom/try-omarchy).
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the third-party files in this
repository and their licenses.
