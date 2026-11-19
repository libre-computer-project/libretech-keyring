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

version="" out="" suse="" release=1
while (($#)); do
	case $1 in
		--version) version=${2:?}; shift 2 ;;
		# a second build of one version (build-arch.sh --pkgrel likewise)
		--release) release=${2:?}; shift 2 ;;
		--out) out=${2:?}; shift 2 ;;
		# openSUSE (the infra multi-distro plan S5): the zypper repository of one release, tumbleweed or a Leap
		# release (16.0); the package carries that release's dist tag (.tw, .lp160), which places it in that
		# release's repo only
		--opensuse) suse=${2:?}; shift 2 ;;
		# Fedora: the release's dist tag (.fc44), which places the package in that release's repo only, as
		# Fedora's own packages carry %{?dist}
		--fedora) fedora=${2:?}; shift 2 ;;
		*) die "usage: build-rpm.sh [--version YYYY.MM.DD] [--release N] [--fedora N | --opensuse tumbleweed|16.0] [--out DIR]" ;;
	esac
done
[[ $release =~ ^[1-9][0-9]*$ ]] || die "release $release is not a positive number"
dist=""
case $suse in
	"") ;;
	tumbleweed) dist=.tw ;;
	1[6-9].[0-9]) dist=.lp${suse/./} ;;
	*) die "--opensuse $suse: tumbleweed or a Leap release (16.0)" ;;
esac
if [[ -n ${fedora:-} ]]; then
	[[ -z $suse ]] || die "--fedora and --opensuse name two distributions"
	[[ $fedora =~ ^[0-9]+$ ]] || die "--fedora $fedora: a release number (44)"
	dist=.fc$fedora
fi
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
	# Leap: $releasever (zypper's 16.0), so a `zypper dup` to the next Leap follows to that release's repo, as
	# openSUSE's own Leap repositories do. Tumbleweed keeps its name: its $releasever is the snapshot date
	srel=$suse
	[[ $suse == tumbleweed ]] || srel='$releasever'
	sed "s|/rpm/fedora/\$releasever/|/rpm/opensuse/$srel/|" "$PKG_ROOT/packaging/rpm/libre-computer.repo" \
		>"$T/rpm/SOURCES/libre-computer.repo"
	grep -qF "/rpm/opensuse/$srel/" "$T/rpm/SOURCES/libre-computer.repo" || die "the repo file's baseurl was not rewritten"
	printf 'autorefresh=1\ntype=rpm-md\n' >>"$T/rpm/SOURCES/libre-computer.repo"
else
	cp "$PKG_ROOT/packaging/rpm/libre-computer.repo" "$T/rpm/SOURCES/"
fi
cp "$PKG_ROOT/LICENSE" "$PKG_ROOT/packaging/rpm/libre-computer.vendors" "$T/rpm/SOURCES/"
cp "$PKG_ROOT/packaging/rpm/libre-computer-release.spec" "$T/rpm/SPECS/"

log "building libre-computer-release $version${suse:+ for openSUSE $suse} from $(source_commit), key $(key_fpr "$T/gnupg")"
# _buildhost: the header names the published host, never the machine that built it
suse_def=()
# (dist only when one is named: rpm refuses a macro with an empty body)
[[ -z $suse ]] || suse_def=(--define "lc_opensuse 1")
[[ -z $dist ]] || suse_def+=(--define "dist $dist")
rpmbuild --define "_topdir $T/rpm" --define "_buildhost deb.libre.computer" \
	--define "lc_version $version" --define "lc_release $release" --define "lc_keyid $(key_rpm_id "$T/gnupg")" \
	"${suse_def[@]}" \
	-bb "$T/rpm/SPECS/libre-computer-release.spec" >"$T/rpmbuild.log" 2>&1 ||
	{ tail -20 "$T/rpmbuild.log" >&2; die "rpmbuild failed"; }
cp "$T"/rpm/RPMS/noarch/libre-computer-release-"$version-$release$dist".noarch.rpm "$out/"
echo "$out/libre-computer-release-$version-$release$dist.noarch.rpm"
