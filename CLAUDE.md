# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

Omanywhere runs stock Omarchy as a headless container desktop, reached over gliff, on GPU and
CPU-only hosts. It's an unofficial community project owned by Chris. Read `README.md` for the
rules. They are binding: Omarchy stays stock, the images are official and verified, the
container follows best practice, the GPU is optional, and fixes go upstream first.

## Where we are

Not started (created 2026-11-21). Read `notes/research/` first.

## `notes/`

`notes/` is git-ignored and never committed. Research, specs, plans and reviews go there. It
overrides any skill's default of committing them under `docs/`. A git worktree won't contain
it, so read it from the main checkout.

## Working rules

- Each piece of work goes on its own branch and lands through a pull request.
- **Third-party code needs Chris's OK.** Before installing, adding or first building anything
  not from Arch Linux, Omarchy/Omacom, Hyprland, Apple or Anthropic, name it and ask. That
  includes container images, packages outside Omarchy's and Arch's repositories, and tools.
- Never turn off package signature checks (`SigLevel`) or skip image signature verification.
- Never use `privileged`, host cgroups or host networking as a shortcut. If something seems to
  need them, stop and ask.
- Ask before running anything on a remote host. The Glifftop test host (`odyssey`) is shared
  with other work.
