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

version="" out="" suse=""
while (($#)); do
	case $1 in
		--version) version=${2:?}; shift 2 ;;
		--out) out=${2:?}; shift 2 ;;
		# openSUSE (the infra multi-distro plan S5): the zypper repository of one release, tumbleweed or a Leap
		# release (16.0); the package carries that release's dist tag (.tw, .lp160), which places it in that
		# release's repo only
		--opensuse) suse=${2:?}; shift 2 ;;
		*) die "usage: build-rpm.sh [--version YYYY.MM.DD] [--opensuse tumbleweed|16.0] [--out DIR]" ;;
	esac
done
dist=""
case $suse in
	"") ;;
	tumbleweed) dist=.tw ;;
	1[6-9].[0-9]) dist=.lp${suse/./} ;;
	*) die "--opensuse $suse: tumbleweed or a Leap release (16.0)" ;;
esac
version=${version:-$(default_version)}
[[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || die "version $version is not YYYY.MM.DD"
out=${out:-$PKG_ROOT/out/$version}
command -v rpmbuild >/dev/null || die "rpmbuild not found (the rpm package)"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
key_home "$T/gnupg"
mkdir -p "$T/rpm/SOURCES" "$T/rpm/SPECS" "$out"
key_armored "$T/gnupg" >"$T/rpm/SOURCES/RPM-GPG-KEY-libre-computer"
if [[ -n $suse ]]; then
	sed "s|/rpm/fedora/\$releasever/|/rpm/opensuse/$suse/|" "$PKG_ROOT/packaging/rpm/libre-computer.repo" \
		>"$T/rpm/SOURCES/libre-computer.repo"
	grep -q "/rpm/opensuse/$suse/" "$T/rpm/SOURCES/libre-computer.repo" || die "the repo file's baseurl was not rewritten"
	printf 'autorefresh=1\ntype=rpm-md\n' >>"$T/rpm/SOURCES/libre-computer.repo"
else
	cp "$PKG_ROOT/packaging/rpm/libre-computer.repo" "$T/rpm/SOURCES/"
fi
cp "$PKG_ROOT/LICENSE" "$T/rpm/SOURCES/"
cp "$PKG_ROOT/packaging/rpm/libre-computer-release.spec" "$T/rpm/SPECS/"

log "building libre-computer-release $version${suse:+ for openSUSE $suse} from $(source_commit), key $(key_fpr "$T/gnupg")"
# _buildhost: the header names the published host, never the machine that built it
suse_def=()
# (dist only for openSUSE: rpm refuses a macro with an empty body)
[[ -z $suse ]] || suse_def=(--define "lc_opensuse 1" --define "dist $dist")
rpmbuild --define "_topdir $T/rpm" --define "_buildhost deb.libre.computer" \
	--define "lc_version $version" --define "lc_keyid $(key_rpm_id "$T/gnupg")" \
	"${suse_def[@]}" \
	-bb "$T/rpm/SPECS/libre-computer-release.spec" >"$T/rpmbuild.log" 2>&1 ||
	{ tail -20 "$T/rpmbuild.log" >&2; die "rpmbuild failed"; }
cp "$T"/rpm/RPMS/noarch/libre-computer-release-"$version"-1"$dist".noarch.rpm "$out/"
echo "$out/libre-computer-release-$version-1$dist.noarch.rpm"
