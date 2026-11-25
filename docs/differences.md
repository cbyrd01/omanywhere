# How Omanywhere differs from Arch and Omarchy

This is every place the image or a running container differs from its two baselines:

- **Arch:** Arch Linux's official `archlinux:base` image, at the digest the Containerfile pins.
- **Omarchy:** a stock Omarchy install, the `omarchy` packages plus `omarchy-apply-system`.

Read with `pacman -Qkk`, `pacman -Qo`, `systemctl list-unit-files` and `diff` in the built image,
on 2026-11-24.

## The short version

- **One package of our own.** `omanywhere` adds only new files and drop-ins, and
  `pacman -Qkk omanywhere` finds none altered. None replaces a file another package owns.
- **One file edited in place:** `/etc/pacman.conf` gets `DisableSandboxFilesystem`
  ([Packages](#packages)). pacman has no drop-in directory.
- **Everything else** that `pacman -Qkk` reports as changed (PAM, cups, ufw, plymouth, sddm,
  faillock, skel `.bashrc`, `/etc/passwd`) is changed by Omarchy's own `omarchy-apply-system`
  or first login, as on any Omarchy install.
- **Units Omarchy enables but a container can't run** are skipped by a drop-in
  (`ConditionVirtualization=!container`), so the same package runs unchanged on a real machine.
- **Workarounds** for upstream bugs, each meant to go once upstream fixes the cause (README
  rule 5):
  - pacman: `DisableSandboxFilesystem` ([Packages](#packages))
  - Omarchy: the empty snapper config and the deferred provisioning manifest ([Packages](#packages))
  - systemd: polkit's `SystemCallFilter` ([systemd](#systemd))
  - gliff: `GLIFF_VIDEO` and `GLIFF_CAPTURE` for sshd ([ssh](#ssh))
  - logind with no udev: `LIBSEAT_BACKEND=noop` ([Desktop session](#desktop-session-and-hyprland))

## Base image

| Change | From | Why |
|---|---|---|
| Arch's base image, pinned by digest and cosign-verified (`make verify-base`) | Arch | Official images only. Its date must not be after Omarchy's stable snapshot. |
| The final image is `FROM scratch` plus a copy of the built root, with `container=docker`, `STOPSIGNAL SIGRTMIN+3` and systemd as the command | Arch | systemd as PID 1, as systemd's container interface documents. No build layers ship. |
| Arch's second `[options]` block (the `NoExtract` of docs, locales and man pages) removed, and every package reinstalled | Arch | The desktop gets the files Arch's image strips. |
| `/etc/pacman.d/gnupg` removed | Arch and Omarchy | No pacman master key shared by every container. Omarchy's first boot makes a new keyring. |
| `/etc/ssh/ssh_host_*` removed | Arch | No host keys baked in. Each state volume gets its own on first boot. |
| `/etc/machine-id` links to `/var/lib/omanywhere/machine-id` | Arch | The machine-id lives in the state volume and survives a recreate. |
| `/tmp` and `/var/tmp` emptied, `.pacnew` files for pacman.conf and the mirrorlist removed | Arch | Nothing machine-specific in the image. |

## Packages

| Change | From | Why |
|---|---|---|
| `omarchy` and every package in Omarchy's x86 defaults | Arch | The stock desktop. `pacman -Qm` lists only `omanywhere`. |
| Arch packages come from Omarchy's stable mirror, as on Omarchy, and the build fails if any package is newer than its repository | Arch | The base image must match Omarchy's snapshot, which can lag Arch (Hyprland, for one). |
| Omarchy's signing key imported from `image/keys/`, checked by sha256 and fingerprint | Arch | `SigLevel` stays `Required DatabaseOptional`. |
| `DisableSandboxFilesystem` added to `/etc/pacman.conf`, and put back by a hook in the owner's `~/.config/omarchy/hooks/pre-refresh-pacman.d/` when `omarchy-refresh-pacman` or `omarchy-channel-set` rewrite the file | Omarchy | **Workaround.** pacman's download sandbox applies Landlock before it sets `no_new_privs`, which the kernel refuses to root without `CAP_SYS_ADMIN`. Arch's official image sets the same line. Signature checks are unaffected. The owner may remove the hook. |
| `mesa`, `vulkan-radeon`, `vulkan-intel`, `intel-media-driver`, `libva-mesa-driver`, `libva-nvidia-driver`, `vulkan-icd-loader` | Omarchy | Omarchy picks these per detected GPU. The image doesn't know the host's GPU, so it has all of them. |
| No `nvidia-utils` or NVIDIA kernel modules | Omarchy | The NVIDIA userspace comes from the host through CDI, matching the host's kernel module. |
| No kernel. Omarchy's boot stack (`limine`, `snapper`) is installed but its units are skipped | Omarchy | The container runs on the host's kernel. |
| An empty `/etc/snapper/configs/root` during the build | Omarchy | **Workaround.** Omarchy's `snapper.sh` aborts `omarchy-apply-system` on a root that isn't btrfs. Omarchy then installs its own file over it, so the shipped file is stock. |
| Omarchy's image manifest set to defer provisioning, with an empty hardware queue | Omarchy | **Workaround.** A container has no hardware to set up. First boot only makes the pacman keyring. A container image target in Omarchy would replace this. |

## systemd

Every drop-in below comes from the `omanywhere` package.

Skipped in a container (`ConditionVirtualization=!container`), unchanged elsewhere:

| Unit | Why |
|---|---|
| `bluetooth` | The host owns the radios. |
| `docker.service`, `docker.socket` | Docker can't run in an unprivileged container. |
| `limine-snapper-sync`, `snapper-cleanup` (service and timer) | No boot menu, and the root is overlayfs. |
| `linux-modules-cleanup` | No kernel in the image. |
| `power-profiles-daemon`, `upower` | The host manages power. upower's sandbox also needs a user namespace. |
| `sddm` | `omanywhere-session` starts the desktop instead. sddm would wait for a seat it can't see. |
| `systemd-oomd` (service and socket) | The host's OOM killer covers the container. |
| `systemd-resolved` (service and sockets) | Docker supplies `/etc/resolv.conf`. |
| `ufw` | The host's firewall governs, and netfilter needs `NET_ADMIN`. |
| `xdg-document-portal` (user unit) | Its FUSE mount needs `/dev/fuse` and `CAP_SYS_ADMIN`. |

Changed or added:

| Change | From | Why |
|---|---|---|
| polkit gets `SystemCallFilter=~capset` | Arch | **Workaround** for systemd#34565: a unit with `User=` and a syscall filter fails without `CAP_SYS_ADMIN`, so polkit wouldn't start. The line only tightens polkit's filter. |
| sshd requires and starts after `omanywhere-owner` | Arch | ssh starts once the owner exists. |
| `sshdgenkeys` makes one ed25519 key in `/var/lib/omanywhere/ssh` | Arch | The host key lives in the state volume. |
| `omanywhere-owner.service` | new | Makes the owner account each boot (see [Accounts](#accounts-sudo-and-polkit)). |
| `omanywhere-session.service` | new, in sddm's place | The desktop: Hyprland under uwsm, in a logind session on seat0. `Restart=always`, at most 5 starts a minute. Each start restarts a running sshd so new logins get the card's gliff settings. |
| A preset enables those two units and sshd | Arch | Arch packages don't enable their units. |
| tmpfiles makes `/var/lib/omanywhere` and an empty machine-id | Arch | A state volume can start empty. |

## Accounts, sudo and polkit

| Change | From | Why |
|---|---|---|
| The owner account (`omarchy`, uid 1000 by default) is made each boot from the container's inputs, with its home in a volume | Omarchy | There's no installer in an image. |
| `omarchy-provision-user --first-install` runs as the owner the first time a home volume is used | Omarchy | It's Omarchy's own user setup, which its installer runs. |
| The owner's groups: `wheel`, the groups Omarchy records, less `docker`, and `input` only when a package needs it | Omarchy | No Docker socket in the container. |
| Each DRM node runc made in the container's `/dev` moves to the image's `video` (card) or `render` (renderD) group, and the owner joins those | Omarchy | Hyprland opens the card through the owner's groups, with no logind device handoff. The node's host gid could be any group here, such as `empower`. |
| `/etc/sudoers.d/00-omanywhere-wheel`: `%wheel ALL=(ALL:ALL) ALL` | Omarchy | Omarchy's installer writes its own copy. Sorting first keeps Omarchy's narrower `NOPASSWD` rules in force. |
| The password is optional, and comes only from a secret file, `/run/secrets/OMANYWHERE_PASSWORD` or `/run/secrets/password`. With none, the account is locked | Omarchy | A password in the environment shows in `docker inspect`. `omanywhere up` makes none unless asked (`--password`). |
| With no password, `/etc/sudoers.d/90-omanywhere-nopasswd` (`USER ALL=(ALL:ALL) NOPASSWD: ALL`) and `/etc/polkit-1/rules.d/49-omanywhere-nopasswd.rules` (the owner is always authorized). With a password, each boot removes both | Omarchy | A prompt for a password that doesn't exist is a dead end, for sudo and for the pkexec that Omarchy uses for DNS, locale and more. |
| `TZ` sets the timezone through `systemd-firstboot` | Arch | Opt-in. |

## ssh

| Change | From | Why |
|---|---|---|
| `/etc/ssh/sshd_config.d/10-omanywhere.conf`: keys only, never root. It includes `/run/omanywhere/sshd/password.conf` before its own lines | Arch | ssh is the only way in. sshd allows passwords by default, and keeps the first value it reads, so this file sorts first. |
| `/run/omanywhere/sshd/password.conf` (`AllowUsers` the owner, `PasswordAuthentication yes`, `AuthenticationMethods password`), written each boot only when there is a password and no key, and removed otherwise | Arch | A password-only desktop (`up --password` with no key). It sits first because sshd keeps the first value it reads. With any key, ssh stays keys only, and root never logs in. |
| `AuthorizedKeysFile` adds `/run/omanywhere/authorized_keys/%u`, rewritten each boot from the container's keys | Arch | The container's keys sit beside the owner's own file. |
| `HostKey /var/lib/omanywhere/ssh/ssh_host_ed25519_key` | Arch | The host key survives a recreate. |
| `Include /run/omanywhere/sshd/*.conf`, which sets `GLIFF_VIDEO` and `GLIFF_CAPTURE` for the card in use | Arch | **Workaround.** gliff-server's default `--video gpu` errors on a card with no render node instead of falling back to the CPU. |

## Desktop session and Hyprland

| Change | From | Why |
|---|---|---|
| `omanywhere-session` picks a DRM card: a real GPU first, else a vkms card no other process holds | Omarchy | Hyprland needs a DRM card even with no monitor. |
| It refuses a GPU no display server is DRM master of, unless `OMANYWHERE_DRM_MASTER=allow` | Omarchy | Taking master would blank the host's outputs ([DRM master](usage.md#drm-master)). |
| `AQ_DRM_DEVICES` names that card. `LIBGL_ALWAYS_SOFTWARE=1` when no render node is usable | Omarchy | Hyprland would open every card. Mesa needs a render node for GPU GL. |
| `LIBSEAT_BACKEND=noop` | Omarchy | **Workaround.** With no udev in the container, logind's `TakeDevice` answers `ENODEV`. |
| `HYPRLAND_CONFIG` points at `/usr/share/omanywhere/hypr/hyprland.lua`, which loads the owner's `~/.config/hypr/hyprland.lua` and then the container's rules | Omarchy | The owner's and Omarchy's files stay unedited. |
| On a GPU, the container's rules turn off every connector of the card and draw on a headless output | Omarchy | Those connectors are the host's monitors. |
| With no password, `.idle.lock` is set to `0` in the owner's `~/.config/omarchy/shell.json` at each boot, and logged when it changes. A marker, `~/.local/state/omanywhere/idle-lock-off`, records it, so a later boot with a password deletes the line again (unless the owner changed it) | Omarchy | Omarchy's shell locks the screen after `idle.lock` seconds (300 by default), and with no password nothing can unlock it. The owner may change the value back. The screensaver and the file's other settings are unchanged, and the file is left alone when there is a password. |
| No udev, input devices or `uinput`, which a container doesn't get | Omarchy | gliff sends input through Wayland. |

## Run flags

[The run flags](usage.md#the-run-flags) explains each flag. Compared with a plain `docker run`:

- systemd gets a console (`--tty`), a private cgroup namespace whose subtree it can write, and
  tmpfs at `/run`, `/run/lock`, `/tmp` and a root-only `/run/secrets`.
- The seccomp profile is Docker's default plus namespaces for Chromium's sandbox, less
  netfilter netlink sockets and the i386 `socketcall` ([seccomp and namespaces](usage.md#seccomp-and-namespaces)).
- `up` adds the volumes, the secrets, one GPU, the ssh port and the opt-ins.
- Never used: `--privileged`, `--cap-add`, host networking or cgroups, or a restart policy.
