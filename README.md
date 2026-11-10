# libretech-keyring (libre-computer-archive-keyring)

The OpenPGP key that signs the Libre Computer package repository (https://packages.libre.computer), packaged
for each distribution the repository serves. The key is one committed file, `libre-computer-deb.gpg`; every
package below is built from it.

| Distribution | Package | Installs | Build |
|---|---|---|---|
| Debian, Ubuntu | `libre-computer-archive-keyring` (and `libretech-keyring`, a transitional package for one release) | `/usr/share/keyrings/libre-computer-deb.gpg`; on a board still on deb.libre.computer, the move to packages.libre.computer (below) | `build.sh` (dpkg-buildpackage) |
| Fedora | `libre-computer-repos` | `/etc/pki/rpm-gpg/RPM-GPG-KEY-libre-computer`, `/etc/yum.repos.d/libre-computer.repo` | `build-rpm.sh` |
| Arch Linux, Arch Linux ARM | `libre-computer-keyring` | `/usr/share/pacman/keyrings/libre-computer{.gpg,-trusted,-revoked}` | `build-arch.sh` |

`test-packages.sh` builds the Fedora and Arch packages and checks their contents and how a renewed key reaches
a host (rpm keeps an imported key, so `libre-computer-repos` deletes the stored copy before importing; pacman
loads the keyring with `pacman-key --populate libre-computer`). The Fedora package installs the repo definition;
the pacman package cannot (pacman has no `conf.d`), so on install it prints the stanza to add to
`/etc/pacman.conf`, with `SigLevel = Required` (pacman's default would take an unsigned database). The builds need `rpmbuild`, `makepkg`,
`bsdtar` and `gpg`.

**Moving a board off deb.libre.computer.** `libre-computer-archive-keyring`'s postinst runs
`apt/libre-computer-move`: on a board whose apt sources name deb.libre.computer it writes
`/etc/apt/sources.list.d/libre-computer.sources` for the board's release (Debian 12 / 13, Ubuntu 24.04 / 26.04,
Raspbian 12 onto `bookworm`), sets the old source files aside in `/var/lib/libre-computer-archive-keyring/`, and
schedules `libre-computer-migrate.service`. Once apt is free that installs the `libre-computer` name of every
package the board has under its old one (`libretech-gpio` → `libre-computer-gpio`, …, armhf
`linux-image-lc-lts-arm` → `-armhf`; each new package Breaks and Replaces its old name), retrying at boot until
it succeeds. Another release, or a kernel channel other than `lc-lts`, keeps the board where it is
(operator, 2026-11-10). `test-deb-move.sh` (root) proves it in copies of a Debian image against a local
repository signed by a throwaway key.

When the key is renewed or rotated, replace `libre-computer-deb.gpg` with the signer's export of the public
key, then rebuild and publish all three packages together. A key withdrawn from trust goes into `REVOKED` in
`build-arch.sh`.
