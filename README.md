# libretech-keyring

The OpenPGP key that signs the Libre Computer package repository (https://packages.libre.computer), packaged
for each distribution the repository serves. The key is one committed file, `libre-computer-deb.gpg`; every
package below is built from it.

| Distribution | Package | Installs | Build |
|---|---|---|---|
| Debian, Ubuntu | `libretech-keyring` | `/usr/share/keyrings/libre-computer-deb.gpg` | `build.sh` (dpkg-buildpackage) |
| Fedora | `libre-computer-repos` | `/etc/pki/rpm-gpg/RPM-GPG-KEY-libre-computer`, `/etc/yum.repos.d/libre-computer.repo` | `build-rpm.sh` |
| Arch Linux, Arch Linux ARM | `libre-computer-keyring` | `/usr/share/pacman/keyrings/libre-computer{.gpg,-trusted,-revoked}` | `build-arch.sh` |

`test-packages.sh` builds the Fedora and Arch packages and checks their contents and how a renewed key reaches
a host (rpm keeps an imported key, so `libre-computer-repos` deletes the stored copy before importing; pacman
loads the keyring with `pacman-key --populate libre-computer`). The builds need `rpmbuild`, `makepkg`,
`bsdtar` and `gpg`.

When the key is renewed or rotated, replace `libre-computer-deb.gpg` with the signer's export of the public
key, then rebuild and publish all three packages together. A key withdrawn from trust goes into `REVOKED` in
`build-arch.sh`.
