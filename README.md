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
`/etc/pacman.conf`, above `[core]` (so our Mesa's `replaces=` takes over from Arch's), with `SigLevel = Required`
(pacman's default would take an unsigned database). The builds need `rpmbuild`, `makepkg`,
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
it reads apt's plan first and refuses a step that would remove any other package, and the same check runs again
inside apt's run (a `DPkg::Pre-Install-Pkgs` hook, before dpkg is called), in case another apt changed the board
in between. It never finishes part-done dpkg work, whoever left it: while dpkg holds a package unpacked or
half-configured, or a cut-short dpkg run left its journal, the renames wait and say so, for `dpkg --configure -a`
(or `apt-get -f install`); a rename a power loss cut short is then resumed. The keyring itself is swapped by dpkg
(`libre-computer-archive-keyring` unpacked over `libretech-keyring`), so its key and the migration's own scripts
are never absent. It installs no kernel: the
armhf meta-package's new name (`linux-image-lc-lts-arm` → `-armhf`) comes with the owner's own upgrade, through
the transitional package, and the timer's next run then removes the old name (each new name keeps its old name's
manual or automatic mark, so autoremove never takes it). Removing the keyring package stops and disables the timer;
its state in `/var/lib/libre-computer-archive-keyring` (the pending marks, the old source files kept) goes on purge,
as a package's configuration does. Another release, a kernel channel other than `lc-lts`, or packages.libre.computer not
answering keeps the board where it is (operator, 2026-11-10), as does an init other than systemd (nothing would
run the renames).

**Known limits** (each a case no change can close without breaking another property):
- A power loss that cuts a run renaming several packages short leaves records for the renames it had not begun;
  the next run that finds no apt or dpkg lock held drops them. Until then, an owner who finishes dpkg and removes
  one of those old names by hand will see the migration install its new name: no record written before an
  action can tell the action apart from an owner's.
- On a moved board whose keyring is not swapped yet (the time from the move to the migration's own swap: about
  30 s, or about 5 min after a boot), the owner's own `apt upgrade` unpacks the transitional `libretech-keyring`
  before `libre-computer-archive-keyring`, and a power loss between the two unpacks leaves the key missing until
  `apt -f install`. `Pre-Depends` on the transitional would order them, but it makes apt remove the old keyring
  first, which broke the rename when tried.
- An image built in a container (not a chroot, `/proc` present, PID 1 not systemd) that adds its init after this
  package stays on deb.libre.computer: it cannot be told from a running container without systemd, which must
  stay. `dpkg-reconfigure libre-computer-archive-keyring` moves it once its init is in.
- The suite the move writes into `libre-computer.sources` is the owner's to carry through a release upgrade, as
  every source of the board's is (the usual `sed` over `sources.list.d` does it): the move never rewrites a
  suite it has written. A board upgraded to another release between a move cut short after its new source went
  in and the next run keeps that old suite's stanza: with no deb.libre.computer entry left, the next run finishes
  the move and the renames read the old suite; with one left elsewhere, the next run adds the new release's
  stanza beside it (or, for a release packages.libre.computer does not serve, keeps both and says so). Telling
  the stanza the move wrote from one the owner added or edited since would take a record of its exact content,
  and replacing an owner's entry is the one thing the move must never do.

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
