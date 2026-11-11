#!/bin/bash
# build-deblibre.sh -- the libretech-keyring published on deb.libre.computer (the frozen repository) to move
# the boards that read it. Unlike the transitional libretech-keyring on packages.libre.computer (which only
# Depends on libre-computer-archive-keyring), this one is self-contained: the key, the source switch and the
# rename migration, and no new dependency. `apt-get upgrade` never installs a package the board does not have,
# so a libretech-keyring that needed one would be kept back there; this one upgrades under any upgrade, and its
# own postinst moves the board. Once the board reads packages.libre.computer, the migration replaces it with
# libre-computer-archive-keyring, which Breaks/Replaces libretech-keyring below its version: this one's version
# sorts just below the same day's (<date>~deb.libre.computer), and must stay below the transitional
# libretech-keyring on packages.libre.computer: at or above it, libre-computer-archive-keyring's Breaks/Replaces
# no longer cover this one, dpkg refuses their shared files and the migration fails on every board. The
# script reads that version from packages.libre.computer (or --below) and refuses a version that is not lower.
#
#   ./build-deblibre.sh --version YYYY.MM.DD [--below VERSION] [--out DIR]
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
version="" below="" out=$PWD
usage() { echo "usage: $0 --version YYYY.MM.DD [--below VERSION] [--out DIR]" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
	case $1 in
		--version) version=$2; shift 2 ;;
		--below) below=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		*) usage ;;
	esac
done
[[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || usage
if [[ -z $below ]]; then
	# what binds is libre-computer-archive-keyring's Breaks/Replaces: libretech-keyring (<< its own version). The
	# lowest version of it that any suite and architecture serves; every index must be read and list it, or the
	# script refuses (an unread suite could serve a lower one)
	for s in bookworm trixie noble resolute; do
		for a in arm64 armhf amd64; do
			v=$(curl -fsSL "https://packages.libre.computer/deb/dists/$s/main/binary-$a/Packages.gz" | gzip -dc |
				awk '/^Package: / {p = $2} /^Version: / && p == "libre-computer-archive-keyring" {print $2}') ||
				{ echo "could not read packages.libre.computer $s $a; pass --below" >&2; exit 1; }
			[[ -n $v ]] || { echo "packages.libre.computer $s $a lists no libre-computer-archive-keyring; pass --below" >&2; exit 1; }
			for x in $v; do
				[[ -z $below ]] || dpkg --compare-versions "$x" lt "$below" && below=$x
			done
		done
	done
fi
dpkg --compare-versions "${version}~deb.libre.computer" lt "$below" ||
	{ echo "${version}~deb.libre.computer is not below $below (libre-computer-archive-keyring's lowest version): its Breaks/Replaces would not cover this one" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
P=$T/pkg
install -D -m 0644 "$HERE/libre-computer-deb.gpg" "$P/usr/share/keyrings/libre-computer-deb.gpg"
install -D -m 0755 "$HERE/apt/libre-computer-move" "$P/usr/lib/libre-computer-archive-keyring/libre-computer-move"
install -D -m 0755 "$HERE/apt/libre-computer-migrate" "$P/usr/lib/libre-computer-archive-keyring/libre-computer-migrate"
install -D -m 0644 "$HERE/apt/libre-computer-migrate.service" "$P/usr/lib/systemd/system/libre-computer-migrate.service"
install -D -m 0644 "$HERE/apt/libre-computer-migrate.timer" "$P/usr/lib/systemd/system/libre-computer-migrate.timer"
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
 becomes libre-computer-archive-keyring), removing nothing else. Kernel
 packages follow the owner's own upgrade. A release packages.libre.computer
 does not serve, a kernel channel other than lc-lts, or packages.libre.computer
 not answering keeps the board on deb.libre.computer.
EOF
install -m 0755 "$HERE/debian/libre-computer-archive-keyring.postinst" "$P/DEBIAN/postinst"
install -m 0755 "$HERE/debian/libre-computer-archive-keyring.postrm" "$P/DEBIAN/postrm"
# the #DEBHELPER# marker debhelper fills in has nothing to add here
sed -i '/^#DEBHELPER#$/d' "$P/DEBIAN/postinst" "$P/DEBIAN/postrm"
deb=$out/libretech-keyring_${version}~deb.libre.computer_all.deb
dpkg-deb --root-owner-group -b "$P" "$deb" >/dev/null
echo "$deb"
