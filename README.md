# libretech-keyring (libre-computer-archive-keyring)

The OpenPGP key that signs the Libre Computer package repository (https://packages.libre.computer), packaged
for each distribution the repository serves. The key is one committed file, `libre-computer-deb.gpg`; every
package below is built from it.

| Distribution | Package | Installs | Build |
|---|---|---|---|
| Debian, Ubuntu | `libre-computer-archive-keyring` (and `libretech-keyring`, a transitional package for one release) | `/usr/share/keyrings/libre-computer-deb.gpg`; on a board still on deb.libre.computer, the move to packages.libre.computer (below) | `build.sh` (dpkg-buildpackage) |
| Fedora | `libre-computer-release` (obsoletes `libre-computer-repos`, its name until 2026-11-11) | `/etc/pki/rpm-gpg/RPM-GPG-KEY-libre-computer`, `/etc/yum.repos.d/libre-computer.repo` | `build-rpm.sh` |
| Arch Linux, Arch Linux ARM | `libre-computer-keyring` | `/usr/share/pacman/keyrings/libre-computer{.gpg,-trusted,-revoked}` | `build-arch.sh` |

`test-packages.sh` builds the Fedora and Arch packages and checks their contents and how a renewed key reaches
a host (rpm keeps an imported key, so `libre-computer-release` deletes the stored copy before importing; pacman
loads the keyring with `pacman-key --populate libre-computer`). The Fedora package installs the repo definition;
the pacman package cannot (pacman has no `conf.d`), so on install it prints the stanza to add to
`/etc/pacman.conf`, with `SigLevel = Required` (pacman's default would take an unsigned database). The builds need `rpmbuild`, `makepkg`,
`bsdtar` and `gpg`.

**Moving a board off deb.libre.computer.** `libre-computer-archive-keyring`'s postinst runs
`apt/libre-computer-move`: on a board with an enabled apt entry for deb.libre.computer, once apt
accepts packages.libre.computer from the board (an `apt-get update` of it alone into scratch lists: reachable,
signature, the board's clock), it writes `/etc/apt/sources.list.d/libre-computer.sources` for the board's release
(none if the board already reads packages.libre.computer; entries of its own in that file are kept) (Debian 12 / 13, Ubuntu 24.04 / 26.04, Raspbian 12 onto `bookworm`) and then takes the old
entries out: a file holding only them goes to `/var/lib/libre-computer-archive-keyring/moved-sources/`, an entry
in a file with others is disabled in place (the original kept there too). It enables
`libre-computer-migrate.timer`, which runs `libre-computer-migrate.service` 30 s later, a few minutes after each
boot and every 6 hours until it succeeds (a timer, so no boot target waits on apt). That installs the
`libre-computer` name of every package the board has under its old one (`libretech-gpio` →
`libre-computer-gpio`, …; each new package Breaks, Replaces and Provides its old name) and removes nothing else:
it reads apt's plan first and refuses a step that would remove any other package. It installs no kernel: the
armhf meta-package's new name (`linux-image-lc-lts-arm` → `-armhf`) comes with the owner's own upgrade, through
the transitional package. Another release, a kernel channel other than `lc-lts`, or packages.libre.computer not
answering keeps the board where it is (operator, 2026-11-10).

**What deb.libre.computer gets**: `build-deblibre.sh` builds a self-contained `libretech-keyring`
(`<date>~deb.libre.computer`: the key, the move and the migration, no new dependency). `apt-get upgrade` never
installs a package the board lacks, so a `libretech-keyring` that Depended on `libre-computer-archive-keyring`
would be kept back there; this one is taken by any upgrade, and its own install moves the board. Its version
must sort below the transitional `libretech-keyring` on packages.libre.computer, below which
`libre-computer-archive-keyring` Breaks/Replaces it; `build-deblibre.sh --version` reads that version and refuses
one that is not lower. The transitional `libretech-keyring` from `build.sh` is for packages.libre.computer only. `test-deb-move.sh` (root) proves it in copies of a Debian image against a local
repository signed by a throwaway key.

When the key is renewed or rotated, replace `libre-computer-deb.gpg` with the signer's export of the public
key, then rebuild and publish all three packages together. A key withdrawn from trust goes into `REVOKED` in
`build-arch.sh`.
