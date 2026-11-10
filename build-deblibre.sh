#!/bin/bash
# build-deblibre.sh -- the libretech-keyring published on deb.libre.computer (the frozen repository) to move
# the boards that read it. Unlike the transitional libretech-keyring on packages.libre.computer (which only
# Depends on libre-computer-archive-keyring), this one is self-contained: the key, the source switch and the
# rename migration, and no new dependency. `apt-get upgrade` never installs a package the board does not have,
# so a libretech-keyring that needed one would be kept back there; this one upgrades under any upgrade, and its
# own postinst moves the board. Once the board reads packages.libre.computer, the migration replaces it with
# libre-computer-archive-keyring, which Breaks/Replaces libretech-keyring below its version: this one's version
# sorts just below the same day's (<date>~deb.libre.computer).
#
#   ./build-deblibre.sh [--version YYYY.MM.DD] [--out DIR]
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
version=$(date +%Y.%m.%d) out=$PWD
while [[ $# -gt 0 ]]; do
	case $1 in
		--version) version=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		*) echo "usage: $0 [--version YYYY.MM.DD] [--out DIR]" >&2; exit 2 ;;
	esac
done
[[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || { echo "version must be YYYY.MM.DD" >&2; exit 2; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
P=$T/pkg
install -D -m 0644 "$HERE/libre-computer-deb.gpg" "$P/usr/share/keyrings/libre-computer-deb.gpg"
install -D -m 0755 "$HERE/apt/libre-computer-move" "$P/usr/lib/libre-computer-archive-keyring/libre-computer-move"
install -D -m 0755 "$HERE/apt/libre-computer-migrate" "$P/usr/lib/libre-computer-archive-keyring/libre-computer-migrate"
install -D -m 0644 "$HERE/apt/libre-computer-migrate.service" "$P/usr/lib/systemd/system/libre-computer-migrate.service"
install -d "$P/DEBIAN"
cat > "$P/DEBIAN/control" <<EOF
Package: libretech-keyring
Version: ${version}~deb.libre.computer
Architecture: all
Maintainer: Da Xue <da@libre.computer>
Section: misc
Priority: optional
Description: Libre Computer GnuPG keys, and the move to packages.libre.computer
 The renewed key that signs the Libre Computer repositories. deb.libre.computer
 is frozen: on install this package moves the board's apt source to
 packages.libre.computer for its release and then installs the libre-computer
 name of every package the board has under an old libretech name (this one
 becomes libre-computer-archive-keyring). A release packages.libre.computer
 does not serve, or a kernel channel other than lc-lts, keeps the board on
 deb.libre.computer.
EOF
install -m 0755 "$HERE/debian/libre-computer-archive-keyring.postinst" "$P/DEBIAN/postinst"
install -m 0755 "$HERE/debian/libre-computer-archive-keyring.postrm" "$P/DEBIAN/postrm"
# the #DEBHELPER# marker debhelper fills in has nothing to add here
sed -i '/^#DEBHELPER#$/d' "$P/DEBIAN/postinst" "$P/DEBIAN/postrm"
deb=$out/libretech-keyring_${version}~deb.libre.computer_all.deb
dpkg-deb --root-owner-group -b "$P" "$deb" >/dev/null
echo "$deb"
