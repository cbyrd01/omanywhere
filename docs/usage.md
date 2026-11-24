# Using Omanywhere

`bin/omanywhere` runs an Omanywhere container and tells you how to reach it. Each container
holds one stock Omarchy desktop for one owner. You reach it with ssh, and you see it with
[gliff](https://github.com/omacom/gliff).

## Quick start

On the host, you need Docker 29 or newer, `make`, and the image:

```sh
make image                     # builds omanywhere:dev
bin/omanywhere up desk         # the container omanywhere-desk
bin/omanywhere ssh-config desk >>~/.ssh/config
gliff --headless omanywhere-desk
```

`up` takes your ssh keys from your ssh agent (`ssh-add -L`), or from `--key FILE`. It picks
the GPU, starts the container, waits for systemd, and then reports what came up:

```
container  running
systemd    running
owner      active (omarchy)
desktop    running on /dev/dri/card1, gpu, nvidia; GLIFF_VIDEO=gpu GLIFF_CAPTURE=auto
ssh        127.0.0.1:32768 (Host omanywhere-desk: omanywhere ssh-config desk)
```

`gliff --headless omanywhere-desk` opens a private screen on that desktop, sized to your
window. You need no other gliff flags on a GPU host or on a CPU-only host (see
[gliff](#gliff)).

## Commands

| Command | What it does |
|---|---|
| `up NAME [options]` | Makes and starts `omanywhere-NAME`, or starts it if it is stopped. If it is already running, it says so and exits 0. |
| `status NAME` | Shows the container, systemd, the owner unit, the desktop session (and why it was skipped, if it was), and the ssh endpoint. Exits 1 if the container doesn't exist. |
| `ssh-config NAME` | Prints a `Host omanywhere-NAME` block for `~/.ssh/config`. |
| `down NAME` | Stops and removes the container. It keeps the volumes and the config. |
| `down NAME --purge [--yes]` | Also removes the volumes and the config, after you confirm. Use `--yes` to skip the prompt, which you need when there's no terminal. |

NAME is 1 to 32 lower-case letters, digits and inner hyphens. From it come these names:

- the container `omanywhere-NAME`, whose hostname is NAME;
- the volumes `omanywhere-NAME-home` (`/home`) and `omanywhere-NAME-state` (`/var/lib/omanywhere`,
  which holds the machine-id and the ssh host key);
- the config directory `~/.config/omanywhere/NAME` (mode 0700). Set `OMANYWHERE_CONFIG_DIR`
  to use another parent directory.

`OMANYWHERE_IMAGE` picks the image. The default is `omanywhere:dev`. `up` never pulls an image.

### `up` options

These options apply when the container is made. `up` saves them in the config directory, so a
later `up` (after `down`) makes the container the same way. To change one on an existing
container, run `down NAME` and then `up NAME --option`.

| Option | Default | Meaning |
|---|---|---|
| `--gpu auto\|none\|nvidia\|dri` | `auto` | The DRM card the desktop runs on (see [CPU and GPU hosts](#cpu-and-gpu-hosts)). |
| `--key FILE` | your ssh agent's keys | The public keys that may log in. `up` copies them to the config directory. |
| `--listen ADDR` | `127.0.0.1` | The address ssh is published on, such as a tailnet address. |
| `--drm-master allow` | off | Lets the desktop take DRM master of a GPU that no display server holds (see [DRM master](#drm-master)). |

`--key` also works on a container that already exists. `up` rewrites its keys file, and the
new keys take effect at the container's next start. Without `--key`, the keys from the first
`up` stay.

### What `up` makes

`up` runs the container with [the run flags](#the-run-flags) and the options for each
container listed there, and nothing more.

On the first `up`, the config directory gets these files:

- `password`, mode 0600: a random password for the owner's sudo and lock screen. It's mounted
  read-only at `/run/secrets/password`, which only root in the container can read. It never
  appears in a command line or in the container's environment. Read it with
  `cat ~/.config/omanywhere/NAME/password`.
- `authorized_keys`, mounted read-only at `/run/secrets/authorized_keys`.
- `settings`: the listen address, the port, `--gpu` and `--drm-master`.

On the first `up`, Docker picks a free port for ssh, and `up` keeps it after that, so the
`ssh-config` block stays right. If another program has taken that port by a later `up`, `up`
fails and says so rather than move ssh to another port. Free the port, or delete the `port`
line in `settings` to take a new one, and then print the `ssh-config` block again.

If the owner account can't be made, or sshd isn't running after the boot, `up` fails and
prints that unit's journal. A key line that isn't a key causes this, for example. There would
be no way in, so `up` stops the container rather than leave it running. It does the same if
systemd doesn't finish booting in 3 minutes. Fix the input, such as with `up NAME --key FILE`,
and run `up` again.

`down --purge` stops if Docker can't remove a volume, such as one another container uses. It
names the volume and keeps the config directory, which holds that volume's password.

### No restart policy

Containers have no restart policy in this version, so they don't come back by themselves
after a reboot. Run `up NAME` to start one again. There are two reasons:

- The desktop's DRM-master guard decides at boot. On a host that is still booting, its
  display server may not hold the GPU yet. A container that restarts with the host could then
  find no master and refuse the GPU.
- A refused or skipped desktop stays down until the container restarts. A restart policy
  doesn't restart a container whose desktop was refused, because the container itself is
  still running.

## The run flags

Every container gets these flags, from `lib/run-flags.bash`. The tests use the same file.

| Flag | Why |
|---|---|
| `--cgroupns=private`, `--security-opt writable-cgroups=true` | systemd runs as PID 1 with no privilege, in a private cgroup namespace whose own subtree is writable. |
| `--tmpfs /run`, `--tmpfs /run/lock`, `--tmpfs /tmp` | systemd expects a tmpfs at each of these. |
| `--tmpfs /run/secrets:mode=0700` | The password and keys are bind-mounted inside this root-only directory. The files belong to your host user, whose uid is usually the owner's (1000), so the directory is what keeps the owner's programs from reading the sudo password. |
| `--tty` | It gives systemd a console. See [below](#--tty-and-docker-logs). |

`up` also passes these for each container:

- `--name omanywhere-NAME`, and `--hostname NAME`, so the shell prompt and the console show
  the name;
- `--pull never`, because the image is local (`make image`) and is never pulled;
- the two volumes, the two secret files (read-only) and the device;
- `-e OMANYWHERE_DRM_MASTER=allow`, with `--drm-master allow`;
- `-p ADDR:PORT:22`.

It never uses `--privileged`, `--cap-add`, a restart policy, or the host's network or cgroups.
To run the image without `bin/omanywhere`, as from Compose, see the README's
[interface](../README.md#the-containers-interface).

### `--tty` and `docker logs`

systemd is the container's PID 1. `--tty` gives it a console (`/dev/console`), as systemd's
container interface asks. Without a console, systemd writes its boot messages and the units'
console output to `/dev/null`. With one, `docker logs omanywhere-NAME` shows:

- the boot;
- the desktop session's lines, including why it was skipped or refused;
- the console's login prompt (`omanywhere-NAME login:`), from Omarchy's stock getty. Root's
  password is locked, and `docker attach` is already root-equivalent, so the prompt opens
  nothing. It's only noise in the logs.

## ssh

ssh is the only way in. It takes keys only and never logs in as root.

`up` publishes port 22 on `127.0.0.1:PORT`, so only this host can reach it.
`ssh-config` prints:

```
# omanywhere desk: add this to ~/.ssh/config, then: gliff --headless omanywhere-desk
Host omanywhere-desk
  HostName 127.0.0.1
  Port 32768
  User omarchy
  HostKeyAlias omanywhere-desk
```

`HostKeyAlias` stores each container's host key under its own name in `known_hosts`. Two
containers on one host then never clash, even when one of them reuses the other's port. The
host key lives in the state volume, so it survives `down` and `up`.

To connect from another machine, choose one of these:

- Add `ProxyJump you@this-host` to the block on that machine. ssh then goes through this host.
- Make the container with `--listen` on an address the other machine can reach, such as
  `up desk --listen 100.64.1.2` for a tailnet address. Prefer a private network to a public
  address: keys are the only lock on the door.

## gliff

`gliff --headless omanywhere-NAME` runs `ssh omanywhere-NAME gliff-server --stdio --headless`.
gliff-server finds the owner's Hyprland itself. Without `--headless`, gliff mirrors the
desktop's own monitor: the GPU's headless output, or the vkms card's connector.

gliff-server reads `GLIFF_VIDEO` and `GLIFF_CAPTURE`. The container sets them for every ssh
session to suit the desktop's card, so a plain client needs no flags:

| Desktop's card | `GLIFF_VIDEO` | `GLIFF_CAPTURE` | Encoding |
|---|---|---|---|
| A GPU with its render node (NVIDIA through CDI, AMD, Intel) | `gpu` | `auto` | On the GPU: Vulkan Video on NVIDIA, VA-API on AMD and Intel. Frames are captured as dmabufs. |
| vkms, or a GPU without a render node | `cpu` | `shm` | On the CPU (OpenH264). Hyprland copies each frame into shared memory. |

gliff 0.4.3's default, `gpu`, fails without a usable GPU instead of falling back to the CPU,
which is why the container sets these. The desktop session writes them each boot to
`/run/omanywhere/sshd/gliff.conf`, which sshd includes (`SetEnv`). Flags you pass to the server
still win, such as `gliff --server-bin 'gliff-server --low-bandwidth' omanywhere-NAME`.

Over ssh, `HYPRLAND_INSTANCE_SIGNATURE` isn't set. `hyprctl` then needs `--instance 0`, for
example `ssh omanywhere-NAME hyprctl --instance 0 monitors`. gliff-server doesn't need it.

## CPU and GPU hosts

The desktop needs a DRM card node. Hyprland's aquamarine allocates its buffers through one,
even when no screen is attached. `--gpu` chooses the card:

- `auto` (the default) picks the first match from this list:
  1. `nvidia` if Docker sees NVIDIA's CDI device `nvidia.com/gpu=all` (`docker info` lists
     it under discovered devices);
  2. `dri` if the host has a `/dev/dri/card*`;
  3. no device otherwise. The desktop is then skipped, and `up` says why.
- `nvidia` uses `--device nvidia.com/gpu=all`. `nvidia_drm` must be loaded with `modeset=1`, so
  the card has a `/dev/dri/card*` node. Docker 28.3 and newer reads CDI specs by default, so
  you don't need `--runtime=nvidia`. On Arch, set the host up once (other distributions are
  untested):

  ```sh
  sudo pacman -S --needed nvidia-container-toolkit
  sudo systemctl restart nvidia-cdi-refresh.service   # first time only
  nvidia-ctk cdi list                                  # expect nvidia.com/gpu=all
  ```

  `nvidia-cdi-refresh` writes the spec to `/var/run/cdi`. After the first time, its `.path`
  unit and boot run it again whenever the driver changes.
- `dri` uses `--device /dev/dri`, which covers AMD and Intel GPUs and a host vkms card.
- `none` uses no device. You get ssh and no desktop.

**GPU host.** The desktop runs on the GPU's card, but none of the GPU's connectors belong to
the container. They are the host's displays, so the session turns every one of them off and
draws on a headless output instead. Rendering and encoding run on the GPU.

**CPU-only host.** The host must provide a virtual card: `modprobe vkms`, kept across boots
with a file in `/etc/modules-load.d/`. Each container needs a card of its own, because a card
has only one DRM master. vkms's connector is the desktop's monitor. Hyprland renders with
llvmpipe and gliff encodes with OpenH264, which costs about 2.5 to 3.5 cores for an active
1080p session and almost nothing when the screen is still. Don't load vkms on a machine
whose own desktop you are using. It adds a monitor to that desktop.

## DRM master

Only one process can be DRM master of a card. On a desktop host, the host's display server
holds master, and the container's Hyprland runs without it. That's the safe case.

If nothing holds master, the first process to open the card takes it. Hyprland's first
modeset would then turn off the host's outputs. This happens on a host that booted before its
display manager started, on one where someone is at a text console, or on one whose user has
logged out. So the session refuses such a GPU and says why in `status`, in `docker logs` and
in the journal.

On a host with no display of its own, such as a server GPU, allow it with
`up NAME --drm-master allow` (the container gets `OMANYWHERE_DRM_MASTER=allow`). vkms cards
are exempt, because their connectors belong to the container.

## Troubleshooting

Start with `omanywhere status NAME`.

- **`desktop skipped: no DRM card ...`.** The container has no card. Use `--gpu nvidia` or
  `--gpu dri`, or load vkms on a CPU-only host, then `down` and `up`.
- **`desktop skipped: no display server holds DRM master ...`.** See [DRM master](#drm-master).
  On a desktop host, log in to the host's desktop, then `down` and `up`.
- **`owner failed`.** Run `docker exec omanywhere-NAME journalctl -b -u omanywhere-owner`.
  Usually a key line isn't a key.
- **The desktop restarts, or is `failed`.** Run `docker exec omanywhere-NAME journalctl -b -u
  omanywhere-session`. Hyprland's own log is in `/run/user/1000/hypr/*/hyprland.log`.
- **Is the desktop on the GPU?** The renderer in Hyprland's log names the GPU, not
  llvmpipe, and gliff's probe passes the Vulkan Video encode:

  ```sh
  ssh omanywhere-NAME 'grep -h "\]: Renderer:" /run/user/1000/hypr/*/hyprland.log'
  ssh omanywhere-NAME gliff-probe all | grep 'PASS Vulkan Video'
  ```

To check gliff inside the container, use `gliff-probe` over ssh:

```sh
ssh omanywhere-NAME gliff-probe all       # the compositor, the GPU and both video paths
ssh omanywhere-NAME gliff-probe outputs   # the outputs Hyprland and Wayland see
# Serve and decode in the container, with the same environment a client gets:
ssh omanywhere-NAME 'gliff-server --listen 127.0.0.1:7999 --headless & sleep 2;
  gliff-probe serve-test --connect 127.0.0.1:7999; kill %1'
```

If gliff connects but the window stays black, the capture may need `shm`. Try
`gliff --server-bin 'gliff-server --capture shm' omanywhere-NAME`. If that fixes it, the
container's choice for your card is wrong: please report it.

If gliff can't connect at all, try `ssh omanywhere-NAME true`. ssh asks for the host key the
first time. To rule out the local end, try `gliff --video cpu omanywhere-NAME`.
