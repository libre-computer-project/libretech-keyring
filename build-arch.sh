#!/bin/bash
# build-arch.sh -- build libre-computer-keyring (pacman, arch=any) for Arch Linux and Arch Linux ARM.
#
#   build-arch.sh [--version YYYY.MM.DD] [--out DIR]
#
# Generates pacman's three keyring files from the committed libre-computer-deb.gpg:
#   libre-computer.gpg      the public key
#   libre-computer-trusted  "<primary fingerprint>:4:" (full trust, which `pacman-key --populate` grants)
#   libre-computer-revoked  revoked fingerprints, one per line (REVOKED below; empty today)
# Needs makepkg, bsdtar (libarchive-tools) and gpg. Unsigned here: packages and
# the database are signed before they are published. Output: the .pkg.tar.zst in DIR
# [out/<version> in this repository]; its path is the last line on stdout.

set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/packaging/lib.sh"

# Fingerprints of keys withdrawn from trust (key-lifecycle policy, rotation). Keep a revoked key here for good.
REVOKED=()

version="" out=""
while (($#)); do
	case $1 in
		--version) version=${2:?}; shift 2 ;;
		--out) out=${2:?}; shift 2 ;;
		*) die "usage: build-arch.sh [--version YYYY.MM.DD] [--out DIR]" ;;
	esac
done
version=${version:-$(default_version)}
[[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || die "version $version is not YYYY.MM.DD"
out=${out:-$PKG_ROOT/out/$version}
command -v makepkg >/dev/null || die "makepkg not found (the makepkg package)"
command -v bsdtar >/dev/null || die "bsdtar not found (libarchive-tools)"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
key_home "$T/gnupg"
mkdir -p "$T/build" "$out"
fpr=$(key_fpr "$T/gnupg")
key_binary "$T/gnupg" >"$T/build/libre-computer.gpg"
printf '%s:4:\n' "$fpr" >"$T/build/libre-computer-trusted"
: >"$T/build/libre-computer-revoked"
for r in "${REVOKED[@]}"; do printf '%s\n' "$r" >>"$T/build/libre-computer-revoked"; done
cp "$PKG_ROOT/packaging/arch/PKGBUILD" "$PKG_ROOT/packaging/arch/libre-computer-keyring.install" "$T/build/"

log "building libre-computer-keyring $version from $(source_commit), key $fpr"
(cd "$T/build" && LC_VERSION=$version PKGEXT=.pkg.tar.zst makepkg --nodeps --noconfirm --skipinteg) \
	>"$T/makepkg.log" 2>&1 || { tail -20 "$T/makepkg.log" >&2; die "makepkg failed"; }
cp "$T/build/libre-computer-keyring-$version-1-any.pkg.tar.zst" "$out/"
echo "$out/libre-computer-keyring-$version-1-any.pkg.tar.zst"
