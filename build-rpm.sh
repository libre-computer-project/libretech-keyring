#!/bin/bash
# build-rpm.sh -- build libre-computer-release (noarch RPM for Fedora; it obsoletes libre-computer-repos): the dnf
# repository definition and the key.
#
#   build-rpm.sh [--version YYYY.MM.DD] [--out DIR]
#
# The key comes from the committed libre-computer-deb.gpg. Needs rpmbuild and gpg.
# The package is unsigned here: RPMs are signed with the repository key before they are published. Output: the .rpm in
# DIR [out/<version> in this repository]; its path is the last line on stdout.

set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/packaging/lib.sh"

version="" out=""
while (($#)); do
	case $1 in
		--version) version=${2:?}; shift 2 ;;
		--out) out=${2:?}; shift 2 ;;
		*) die "usage: build-rpm.sh [--version YYYY.MM.DD] [--out DIR]" ;;
	esac
done
version=${version:-$(default_version)}
[[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || die "version $version is not YYYY.MM.DD"
out=${out:-$PKG_ROOT/out/$version}
command -v rpmbuild >/dev/null || die "rpmbuild not found (the rpm package)"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
key_home "$T/gnupg"
mkdir -p "$T/rpm/SOURCES" "$T/rpm/SPECS" "$out"
key_armored "$T/gnupg" >"$T/rpm/SOURCES/RPM-GPG-KEY-libre-computer"
cp "$PKG_ROOT/packaging/rpm/libre-computer.repo" "$T/rpm/SOURCES/"
cp "$PKG_ROOT/packaging/rpm/libre-computer-release.spec" "$T/rpm/SPECS/"

log "building libre-computer-release $version from $(source_commit), key $(key_fpr "$T/gnupg")"
# _buildhost: the header names the published host, never the machine that built it
rpmbuild --define "_topdir $T/rpm" --define "_buildhost deb.libre.computer" \
	--define "lc_version $version" --define "lc_keyid $(key_rpm_id "$T/gnupg")" \
	-bb "$T/rpm/SPECS/libre-computer-release.spec" >"$T/rpmbuild.log" 2>&1 ||
	{ tail -20 "$T/rpmbuild.log" >&2; die "rpmbuild failed"; }
cp "$T"/rpm/RPMS/noarch/libre-computer-release-"$version"-1.noarch.rpm "$out/"
echo "$out/libre-computer-release-$version-1.noarch.rpm"
