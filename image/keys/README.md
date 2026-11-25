# Omarchy package signing keys

The image trusts Omarchy's repository through these three files. They are pacman keyring
files (`pacman-key --populate-from`), copied unchanged from `/usr/share/pacman/keyrings/` of
the signature-verified package `omarchy-keyring 20251027-1`, on an Omarchy host, on
2026-11-23. They match the sha256s that try-omarchy publishes for the same files.

License: GPL-3.0-or-later, as the `omarchy-keyring` package declares; see
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

| File              | sha256                                                             |
|-------------------|--------------------------------------------------------------------|
| `omarchy.gpg`     | `15d6aac44df688165b2ea35fe0b23af239bbc66a6909c10a5c219e8d94b707de` |
| `omarchy-trusted` | `ab0b688815444cffd48d15ca3597c77dbb364d59763c5784fca36691520f00fd` |
| `omarchy-revoked` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

`omarchy.gpg` holds one key, `Omarchy <pkgs@omarchy.org>`, fingerprint
`40DFB630FF42BCFFB047046CF0134EE680CAC571`. `omarchy-revoked` is empty.

The build checks the files against `SHA256SUMS` and checks the fingerprint, then adds the key
to pacman's keyring so the `omarchy` repository's signatures verify. Like any key in that
keyring, pacman trusts it for any package, not only Omarchy's. From then on the
`omarchy-keyring` package, which those signed packages install, carries the keys.

To update: install the new `omarchy-keyring` on a verified Omarchy host, copy the three
files from `/usr/share/pacman/keyrings/`, regenerate `SHA256SUMS`, and compare the sums
with the ones Omarchy or try-omarchy publish before committing.
