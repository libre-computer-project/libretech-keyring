#!/bin/bash
# stage-board-move.sh -- build the two STAGING repositories test-board-move.sh reads, signed by a throwaway key.
#
#   stage-board-move.sh <out dir> <gnupg homedir holding one secret key> <deb>...
#
# A .deb whose version ends in ~deb.libre.computer goes to <out>/deb.libre.computer/repo (suite linux, main), as
# deb.libre.computer would serve it; every other .deb goes to <out>/packages/deb (suite bookworm, main, with an
# empty non-free), as packages.libre.computer would. The key's public half is written to <out>/test-key.gpg.
# Serve <out> over HTTP and hand its URL to test-board-move.sh. Nothing here is published.
#
# Style: software/convention/bash.md
set -euo pipefail

die() { echo "stage-board-move: $*" >&2; exit 1; }

# repo <root> <suite> <components...>: index the pool, write and sign the suite's Release
repo() {
	local root=$1 suite=$2 c
	shift 2
	for c in "$@"; do
		install -d "$root/dists/$suite/$c/binary-arm64"
		: > "$root/dists/$suite/$c/binary-arm64/Packages"
	done
	(cd "$root" && apt-ftparchive packages pool > "dists/$suite/main/binary-arm64/Packages")
	apt-ftparchive -o APT::FTPArchive::Release::Suite="$suite" -o APT::FTPArchive::Release::Codename="$suite" \
		-o APT::FTPArchive::Release::Components="$*" -o APT::FTPArchive::Release::Architectures=arm64 \
		release "$root/dists/$suite" > "$root/Release.tmp"
	mv "$root/Release.tmp" "$root/dists/$suite/Release"
	gpg --batch --yes --homedir "$G" --clearsign -o "$root/dists/$suite/InRelease" "$root/dists/$suite/Release"
}

main() {
	(( $# >= 3 )) || { sed -n '2,10p' "$0"; exit 2; }
	local out=$1 d v
	G=$2
	shift 2
	[[ -d "$G" ]] || die "no gnupg homedir $G"
	rm -rf -- "$out/deb.libre.computer" "$out/packages"
	install -d "$out/deb.libre.computer/repo/pool" "$out/packages/deb/pool"
	for d in "$@"; do
		v=$(dpkg-deb -f "$d" Version) || die "not a .deb: $d"
		if [[ $v == *~deb.libre.computer ]]; then
			cp -p "$d" "$out/deb.libre.computer/repo/pool/"
		else
			cp -p "$d" "$out/packages/deb/pool/"
		fi
	done
	repo "$out/deb.libre.computer/repo" linux main
	repo "$out/packages/deb" bookworm main non-free
	gpg --batch --homedir "$G" --export > "$out/test-key.gpg"
	echo "stage-board-move: deb.libre.computer: $(ls "$out/deb.libre.computer/repo/pool" | tr '\n' ' ')"
	echo "stage-board-move: packages: $(ls "$out/packages/deb/pool" | tr '\n' ' ')"
}

main "$@"
