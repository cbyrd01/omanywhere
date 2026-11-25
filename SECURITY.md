# Security

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the repository's
**Security** tab, then **Report a vulnerability**. Please don't open a public issue for it.

## Scope

- the image (`image/Containerfile` and the `omanywhere` package in `package/omanywhere/`);
- `bin/omanywhere`;
- `lib/seccomp.json` and the run flags (`lib/run-flags.bash`);
- the owner and session scripts (`package/omanywhere/owner`, `package/omanywhere/session`).

## Supported versions

Omanywhere is at version 0. There are no supported releases. Fixes land on `main`; rebuild the
image from it.

## Upstream

Report issues in these projects to them:

- Omarchy: [omacom/omarchy](https://github.com/omacom/omarchy)
- gliff: [omacom/gliff](https://github.com/omacom/gliff)
- Hyprland: [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland)
- Arch Linux packages: each package's repository under
  [archlinux/packaging/packages](https://gitlab.archlinux.org/archlinux/packaging/packages)
