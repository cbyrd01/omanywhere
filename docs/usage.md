# Using Omanywhere

`bin/omanywhere` runs an Omanywhere container and tells you how to reach it. Each container
holds one stock Omarchy desktop for one owner. You reach it with ssh, and you see it with
[gliff](https://github.com/omacom/gliff).

## Quick start

On the host, you need Docker 29 or newer, `make`, and the image. On Arch,
`sudo bin/omanywhere-host setup` installs what the host needs (see
[Setting up a host](#setting-up-a-host)).

```sh
make image                     # builds omanywhere:dev
bin/omanywhere up desk         # the container omanywhere-desk
bin/omanywhere ssh-config desk >>~/.ssh/config
gliff --headless omanywhere-desk
```

`up` takes your ssh keys from your ssh agent (`ssh-add -L`), from `--key FILE`, or from GitHub
with `--github USER`. It picks the GPU, starts the container, waits for systemd, and then
reports what came up:

```
container  running
systemd    running
owner      active (omarchy)
desktop    running on /dev/dri/card1, gpu, nvidia; GLIFF_VIDEO=gpu GLIFF_CAPTURE=auto
health     healthy
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

Of the container, only the two volumes outlive `down`. Anything installed in its root, such as
packages, is gone, and the next `up` makes the container afresh from the image. That is how to
move to a new image: build it (or set `OMANYWHERE_IMAGE`), then run `down NAME` and `up NAME`.
A container that exists keeps the image it was made from, because `up` only starts it. The
one exception keeps the image too: a `--gpu vkms` container whose card has a new number is
made again from the same image (see [Setting up a host](#setting-up-a-host)).

### `up` options

These options apply when the container is made. `up` saves them in the config directory, so a
later `up` (after `down`) makes the container the same way. To change one on an existing
container, run `down NAME` and then `up NAME --option`.

| Option | Default | Meaning |
|---|---|---|
| `--gpu auto\|none\|nvidia\|dri\|dri:/dev/dri/cardN\|vkms` | `auto` | The DRM card the desktop runs on (see [CPU and GPU hosts](#cpu-and-gpu-hosts)). |
| `--key FILE` | your ssh agent's keys | The public keys that may log in. `up` copies them to the config directory. With no key and no `--password`, `up` refuses. |
| `--github USER` | | Instead of `--key`: the public keys GitHub publishes for USER at `https://github.com/USER.keys`. Whoever holds that account can log in, so `up` shows the keys' fingerprints and asks first. Without a terminal, add `--yes`. |
| `--listen ADDR` | `127.0.0.1` | The address ssh is published on, such as a tailnet address. |
| `--drm-master allow` | off | Lets the desktop take DRM master of a GPU that no display server holds (see [DRM master](#drm-master)). |
| `--password` | off | Gives the owner a password, so sudo and polkit ask for it, and the idle lock stays on. `up` makes a random one in `~/.config/omanywhere/NAME/password`, or keeps the one already there (write your own first, one non-blank line). Without a password, sudo and polkit ask the owner for none, as in Toolbox, and the idle lock is off. Any program running as the owner, a bad package or a browser exploit say, can then become root in the container. With rootful Docker, root in the container is uid 0 on the host, held back only by the container's limits. With no key either, the desktop is [password-only](#password-only-desktops). |
| `--no-password` | | Deletes `~/.config/omanywhere/NAME/password`, so the next container has none. |

`--key` and `--github` also work on a container that already exists. `up` rewrites its keys
file, and the new keys take effect at the container's next start. Without either, the keys
from the first `up` stay: `--github` copies the keys once, so run it again after you change
your keys on GitHub.

### What `up` makes

`up` runs the container with [the run flags](#the-run-flags) and the options for each
container listed there, and nothing more.

On the first `up`, the config directory gets these files:

- `password`, mode 0600, only with `--password`: a random password for the owner's sudo,
  polkit and lock screen. It's mounted read-only at `/run/secrets/password`, which only root in
  the container can read. It never appears in a command line or in the container's environment.
  Read it with `cat ~/.config/omanywhere/NAME/password`. A container has a password when this
  file holds a non-blank line, so an old config with a password file keeps it, and
  `--no-password` is what deletes it. `up` refuses a blank file.
- `authorized_keys`, mounted read-only at `/run/secrets/authorized_keys` (empty with no key). Each line is a public
  key, and may start with authorized_keys options such as `from="…"`, which sshd applies. A
  `command="…"` would run instead of gliff-server, so gliff can't use that key.
- `settings`: the listen address, the port, `--gpu` and `--drm-master`.

On the first `up`, Docker picks a free port for ssh, and `up` keeps it after that, so the
`ssh-config` block stays right. If another program has taken that port by a later `up`, `up`
fails and says so rather than move ssh to another port. Free the port, or delete the `port`
line in `settings` to take a new one, and then print the `ssh-config` block again.

If the owner account can't be made, or sshd isn't running after the boot, `up` fails and
prints that unit's journal. A key line that isn't a key causes this, for example. There would
be no way in, so `up` stops the container rather than leave it running. It does the same if
systemd doesn't finish booting in 3 minutes. Fix the input, such as with `up NAME --key FILE` or `--github USER`,
and run `up` again.

### Health

The image has a Docker `HEALTHCHECK` (`/usr/lib/omanywhere/health`), so `docker ps` shows
each container as `healthy`, `starting` or `unhealthy`, and `status` has a `health` line. A
container is healthy when:

- systemd is `running`, not `degraded` (a unit failed) or still starting;
- sshd is active;
- the desktop session is running. A container with no card (`--gpu none`) has no desktop and
  passes without one.

A desktop that was skipped although the container has a card, such as one whose DRM master
was refused, makes the container unhealthy. The `desktop` line in `status` says why. Docker
checks every 5 s while the container boots (for up to 4 minutes), then every 30 s, and a
container turns unhealthy after 3 failures in a row. `docker inspect omanywhere-NAME` keeps the
last checks' output under `State.Health`. Health is only reported: Docker doesn't restart an unhealthy container.

`down --purge` stops if Docker can't remove a volume, such as one another container uses. It
names the volume and keeps the config directory, which holds that volume's password, if it has one.

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
| `--tmpfs /run/secrets:mode=0700` | The keys and the password, if any, are bind-mounted inside this root-only directory. The files belong to your host user, whose uid is usually the owner's (1000), so the directory is what keeps the owner's programs from reading the sudo password. |
| `--security-opt seccomp=lib/seccomp.json` | Docker's default seccomp profile plus one rule: any process may call `clone` and `unshare` with namespace flags, as Podman's default profile allows. Docker's default allows that only with `CAP_SYS_ADMIN`, and Chromium's sandbox needs it: a user namespace, then a new PID namespace per renderer from inside it. Without the rule Chromium crashes at start. The kernel still decides the rest: a process outside a user namespace of its own gets no new mount, network or PID namespace. A rule allowing only calls that make a user namespace would block no more kernel code, since such a call can ask for every other namespace too, and it breaks Chromium's per-renderer PID namespaces. The cost is [below](#seccomp-and-namespaces). `scripts/seccomp-profile` makes the file from Docker's profile (moby, Apache License 2.0) for the tag the script names; rerun it when Docker's default changes. |
| `--tty` | It gives systemd a console. See [below](#--tty-and-docker-logs). |

`up` also passes these for each container:

- `--name omanywhere-NAME`, and `--hostname NAME`, so the shell prompt and the console show
  the name;
- `--pull never`, because the image is local (`make image`) and is never pulled;
- the two volumes, the keys file and, with a password, the password file (both read-only), and
  the device;
- `-e OMANYWHERE_DRM_MASTER=allow`, with `--drm-master allow`;
- `-p ADDR:PORT:22`.

It never uses `--privileged`, `--cap-add`, a restart policy, or the host's network or cgroups.
To run the image without `bin/omanywhere`, as from Compose, see
[below](#running-the-image-without-omanywhere).

### seccomp and namespaces

In a user namespace of its own, code in the container is root of a new network namespace and
can reach kernel networking code that Docker's default keeps from it, the source of several
container escapes. The profile closes the largest part of that, netfilter:

- no netlink socket for `NETLINK_NETFILTER`;
- no `socketcall`, the i386 call that hides a socket's arguments from seccomp. Arch's
  lib32-glibc makes the socket calls directly, so only old 32-bit binaries lose networking.

Traffic control (`tc`, over route netlink) stays reachable, and so does legacy iptables on a
host that loads `ip_tables`. Keep the host's kernel patched, above all where people or agents
you don't trust use the desktops.

### `--tty` and `docker logs`

systemd is the container's PID 1. `--tty` gives it a console (`/dev/console`), as systemd's
container interface asks. Without a console, systemd writes its boot messages and the units'
console output to `/dev/null`. With one, `docker logs omanywhere-NAME` shows:

- the boot;
- the desktop session's lines, including why it was skipped or refused;
- the console's login prompt (`omanywhere-NAME login:`), from Omarchy's stock getty. Root's
  password is locked, and `docker attach` is already root-equivalent, so the prompt opens
  nothing. It's only noise in the logs.

### Running the image without `omanywhere`

To run the image some other way, such as from Compose, use the same flags. `up` runs the
container much like this:

```sh
docker run -d --tty --cgroupns=private --security-opt writable-cgroups=true \
  --security-opt seccomp=lib/seccomp.json \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp --tmpfs /run/secrets:mode=0700 \
  -v NAME-home:/home -v NAME-state:/var/lib/omanywhere \
  -v ./authorized_keys:/run/secrets/authorized_keys:ro [-v ./password:/run/secrets/password:ro] \
  -p 127.0.0.1:2222:22 [--device nvidia.com/gpu=all | --device /dev/dri] omanywhere:dev
```

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
  comes).

The keys given to the container are authoritative, and are set again on every boot. sshd
reads them from `/run/omanywhere/authorized_keys/`. Keys that the owner adds to
`~/.ssh/authorized_keys` themselves are kept, and log in too, except on a password-only
desktop, where ssh takes only the password.

Use named volumes for `/home` and `/var/lib/omanywhere`, which Docker fills from the image. A
bind-mounted state directory starts empty, so its first boot can't keep a machine-id and is
degraded. From the second boot on it behaves like a named volume.

## ssh

ssh is the only way in. It takes keys only, except for a [password-only desktop](#password-only-desktops), and never logs in as root.

### Password-only desktops

`up NAME --password` with no `--key`, `--github` or keys kept from an earlier `up` makes a
desktop with no ssh key: ssh then takes the owner's password, for the owner only, and nothing
else. `up` doesn't take your agent's keys for it. To pick the password yourself, write it to
`~/.config/omanywhere/NAME/password` (mode 0600, one line) before the first `up --password`;
`up` keeps a password that is there, and otherwise makes a random one. With neither a key nor
a password, `up` refuses.

Any key given to the container makes ssh keys-only again, even with a password. A key the owner
adds to their own `~/.ssh/authorized_keys` doesn't: while the container has no key of its own,
ssh takes only the password. `up NAME --key FILE` adds one to an existing container, and
applies it when the container next starts. The password then only serves sudo, polkit and the
lock screen. Keys stay across `up`s: to go back to password-only,
delete `~/.config/omanywhere/NAME/authorized_keys`, then `down NAME` and `up NAME`.

With a `--listen` address other than `127.0.0.1`, `up` warns that ssh takes only the password
there.

The cost: anyone who can reach the ssh port can guess the password, as often as sshd allows.
The random password is long enough to stand up to that. One you pick must be too, above all
with `--listen` on an address other than `127.0.0.1`. Keys are still the safer way in.

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
  address: keys are the only lock on the door (the password, on a password-only desktop).

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

## Setting up a host

On an Arch Linux host, `bin/omanywhere-host` does the root steps this page describes. Other
distributions aren't supported. Run it from the checkout:

```sh
sudo bin/omanywhere-host setup
```

It lists what it will change and asks first (`--yes` skips the question), and run again it
changes nothing that is already in place. It installs Docker and `make` from Arch's repositories
and enables `docker.socket`. Installing a package means `pacman -Syu`, a full upgrade, because
Arch doesn't support partial ones. Then it sets up the host's GPU:

- **NVIDIA:** `nvidia-container-toolkit` and its CDI spec. It doesn't install the driver: install
  [Arch's NVIDIA driver](https://wiki.archlinux.org/title/NVIDIA) and reboot first, or setup
  stops and says so.
- **AMD or Intel:** nothing more. `up NAME` uses the card.
- **No GPU** (a CPU-only host or VM, whose virtual display adapter doesn't count), or with
  `--vkms`: the vkms module, loaded at every boot, the udev rule that keeps vkms cards off the
  host's seat, and `omanywhere-vkms@.service`, which makes each container's vkms card.

It adds no one to the `docker` group. Membership is root-equivalent, so it's your decision:
`sudo usermod -aG docker USER`, then log in again. Or run `omanywhere` with sudo, which keeps
root's own config in `/root/.config/omanywhere`.

On a vkms host, give each container its own card, then make the container on it:

```sh
sudo bin/omanywhere-host vkms add desk   # the card omanywhere-desk, made again at every boot
bin/omanywhere up desk --gpu vkms
```

`--gpu vkms` finds the container's card by its name. Card numbers can change from one boot to
the next, and a container's devices are fixed when it's made, so when the card's number has
moved, `up` makes the container again from the same image, on the new card, keeping its
volumes, keys, password and settings. As with `down` and `up`, anything installed in the
container's root, outside the volumes, is gone. After `down desk`, remove the card with
`sudo bin/omanywhere-host vkms remove desk`.

setup installs only its own files: `/usr/local/bin/omanywhere-host` (the copy the boot unit
runs), `/etc/systemd/system/omanywhere-vkms@.service`,
`/etc/udev/rules.d/72-omanywhere-vkms.rules` and `/etc/modules-load.d/omanywhere-vkms.conf`.

### A new cloud host

[`host/cloud-init.yaml`](../host/cloud-init.yaml) is user data for a host made from
[Arch Linux's official cloud image](https://gitlab.archlinux.org/archlinux/arch-boxes). Set
`GITHUB_USER` in it, and if you like `NAME` and `OMANYWHERE_REF` (a commit pins exactly what
runs as root on the host). On its first boot, `omanywhere-firstboot.service` clones omanywhere,
runs `omanywhere-host setup --yes`, adds the image's user `arch` to the `docker` group (`arch`
already has passwordless sudo there, so this gives it nothing new), makes a vkms card if the
host has no GPU, builds the image, and runs `up NAME --github GITHUB_USER --yes` as `arch`.
If installing git upgraded the kernel, it reboots into the new one first and goes on from
there. The build takes about 30 GB of disk and half an hour or more. Follow it with
`journalctl -u omanywhere-firstboot -f`.

The desktop listens on the host's `127.0.0.1`, so connect through the host's own sshd. Print the
container's block from your machine:

```sh
ssh arch@HOST /opt/omanywhere/bin/omanywhere ssh-config desk
```

Add it to `~/.ssh/config` on your machine with a `ProxyJump arch@HOST` line, then run
`gliff --headless omanywhere-desk`. A host with an NVIDIA GPU needs its driver first, which the
file doesn't install.

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
  you don't need `--runtime=nvidia`. On Arch, `omanywhere-host setup` sets the host up, or by
  hand (other distributions are untested):

  ```sh
  sudo pacman -S --needed nvidia-container-toolkit
  sudo systemctl restart nvidia-cdi-refresh.service   # first time only
  nvidia-ctk cdi list                                  # expect nvidia.com/gpu=all
  ```

  `nvidia-cdi-refresh` writes the spec to `/var/run/cdi`. The package's `.path` unit and boot
  re-run it when the driver changes.
- `dri` uses `--device /dev/dri`, which covers AMD and Intel GPUs and a host vkms card. It
  doesn't cover NVIDIA: Hyprland allocates through GBM, and NVIDIA's GBM backend comes only with
  its CDI spec, so the session skips an NVIDIA card given this way, and `up` warns. A Debian or
  Ubuntu host's CDI spec puts the backend where Arch's Mesa doesn't look, so it isn't supported
  yet.
- `dri:/dev/dri/cardN` passes that one card, and its own render node if it has one (`up` finds
  it in the host's `/sys/class/drm/cardN/device/drm/`). `up` checks that the card exists when
  it makes the container.
- `vkms` passes the vkms card `omanywhere-NAME` that `omanywhere-host vkms add NAME` made,
  found by name ([Setting up a host](#setting-up-a-host)).
- `none` uses no device. You get ssh and no desktop.

**GPU host.** The desktop runs on the GPU's card, but none of the GPU's connectors belong to
the container. They are the host's displays, so the session turns every one of them off and
draws on a headless output instead. Rendering and encoding run on the GPU.

**CPU-only host.** The host must provide a virtual card, from the vkms module. vkms's
connector is the desktop's monitor. Each container needs a vkms card of its own, because the
desktop must be the card's DRM master and a card has only one. Hyprland renders with llvmpipe
and gliff encodes with OpenH264, which costs about 2.5 to 3.5 cores for an active 1080p session
and almost nothing when the screen is still.

`omanywhere-host` sets this up ([Setting up a host](#setting-up-a-host)): it loads vkms at
boot, and `vkms add NAME` makes a card per container through vkms's configfs
(`/sys/kernel/config/vkms/omanywhere-NAME`), which `--gpu vkms` then finds by name. A kernel
whose vkms has no configfs gives only the one card `modprobe vkms` makes, for one container:
`--gpu dri:/dev/dri/cardN`, since `--gpu dri` passes every card.

On a host with a desktop of its own, that desktop takes every new card on its seat as a
monitor and becomes its DRM master, and the container's session then refuses the card. So
setup installs a udev rule, `/etc/udev/rules.d/72-omanywhere-vkms.rules`, that keeps vkms cards
off the host's seat, before it loads vkms. A card made before the rule stays on the seat until
vkms is unloaded or the host reboots.

## DRM master

Only one process can be DRM master of a card. On a desktop host, the host's display server
holds master, and the container's Hyprland runs without it. That's the safe case.

If nothing holds master, the first process to open the card takes it. Hyprland's first
modeset would then turn off the host's outputs. This happens on a host that booted before its
display manager started, on one where someone is at a text console, or on one whose user has
logged out. So the session refuses such a GPU and says why in `status`, in `docker logs` and
in the journal.

On a host with no display of its own, such as a server GPU, allow it with
`up NAME --drm-master allow` (the container gets `OMANYWHERE_DRM_MASTER=allow`).

A vkms card is the other way round. Its connector belongs to the container, and the desktop
must be its master to draw on it. When another process holds it, Hyprland starts but every
modeset fails and its monitor stays at 0x0, so the session passes over such a card, takes the
next free one, and says why when none is left. On a host with a desktop of its own, that process
is the host's desktop: see the udev rule under [CPU and GPU hosts](#cpu-and-gpu-hosts).

The session checks master again just before it starts Hyprland, but master can still change
hands in the moment before Hyprland opens the card, and that gap can't be closed while Hyprland
opens the card itself. The guard also covers only Hyprland's start. The owner is in the card's group, so any process in
the container can open the card. While no host display server holds master (at a text
console, logged out, or before the display manager starts), that process becomes master and
locks the host's display out until it exits. Don't run untrusted code in a container on a GPU
that a host display shares. The real fix is upstream: a compositor that needs no card
(aquamarine's headless backend without KMS).

## Troubleshooting

Start with `omanywhere status NAME`.

- **`desktop skipped: no DRM card ...`** or **`no usable DRM card ...`.** The container has no
  card the desktop can use, and its devices are fixed when it's made. Load vkms on a CPU-only
  host if it needs one, then `down NAME` and `up NAME --gpu ...` (see
  [CPU and GPU hosts](#cpu-and-gpu-hosts)).
- **`desktop skipped: no display server holds DRM master ...`.** See [DRM master](#drm-master).
  On a desktop host, log in to the host's desktop, then `docker restart omanywhere-NAME`.
- **`no usable DRM card: ... (vkms: held by another process ...)`.** See
  [DRM master](#drm-master), then give the container a card of its own: `down NAME`,
  `sudo bin/omanywhere-host vkms add NAME`, then `up NAME --gpu vkms`.
- **A manual lock (the keybinding or the menu) can't be unlocked.** With no password there is
  nothing to unlock it with. The owner script turns the idle lock off (`idle.lock` is `0` in the
  owner's `~/.config/omarchy/shell.json`), but a manual lock still works. Run
  `docker exec omanywhere-NAME systemctl restart omanywhere-session`: it starts the desktop again
  and drops the lock. Then connect again with gliff. Or make the container with `--password`
  (`down NAME`, then `up NAME --password`), and the lock takes it. A boot with a password over
  the same home removes the `idle.lock` line that the owner script set (Omarchy's default of
  300 applies again), unless you changed it yourself.
- **`health unhealthy: ...`.** The check's message names what is down: systemd degraded (run
  `docker exec omanywhere-NAME systemctl --failed`), sshd, or the desktop, which the
  `desktop` line explains. See [Health](#health).
- **`owner failed`.** Run `docker exec omanywhere-NAME journalctl -b -u omanywhere-owner`.
  Usually a key line isn't a key.
- **The desktop restarts, or is `failed`.** Run `docker exec omanywhere-NAME journalctl -b -u
  omanywhere-session`. Hyprland's own log is in `/run/user/1000/hypr/*/hyprland.log`.
- **Is the desktop on the GPU?** The renderer in Hyprland's log names the GPU, not
  llvmpipe, and gliff's probe passes the Vulkan Video encode:

  ```sh
  ssh omanywhere-NAME 'grep -h "\]: Renderer:" /run/user/1000/hypr/*/hyprland.log | sort -u'
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

### Reporting a problem

Use the [bug form](https://github.com/cbyrd01/omanywhere/issues/new?template=bug.yml). It
asks for `omanywhere status NAME` and the relevant part of `docker logs omanywhere-NAME`, which
carries the boot and the desktop session's messages. Check what you paste for keys and
passwords first. Report a security problem privately, as [SECURITY.md](../SECURITY.md) says.
