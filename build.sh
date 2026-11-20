#!/bin/bash
# build.sh -- build libre-computer-archive-keyring and the transitional libretech-keyring (.deb, Architecture: all)
# into the parent directory (dpkg-buildpackage's default).
#
#   ./build.sh [--version YYYYMMDD.HHMMSS.g<sha8> --commit <sha>]
#
# The version is the commit's date and the commit (packaging/lib.sh check_version), as every format of a Libre
# Computer project without a declared version takes it (claude infra/libre-computer/packages/package-parity-policy.md
# rule 6.8). The release process passes both (it builds an exported commit, which has no .git); without them the
# tree's HEAD gives them, and the build is the working tree as it stands.
set -euo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
log() { printf 'build.sh: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
. packaging/lib.sh

version="" commit=""
while (($#)); do
	case $1 in
		--version) version=${2:?}; shift 2 ;;
		--commit) commit=${2:?}; shift 2 ;;
		*) die "usage: build.sh [--version YYYYMMDD.HHMMSS.g<sha8> --commit <sha>]" ;;
	esac
done
if [[ -z $version ]]; then
	[[ -z $commit ]] || die "--commit needs --version"
	commit=$(git rev-parse HEAD) || die "no --version given and no git HEAD to take it from"
	version=$(default_version)
fi
[[ -n $commit ]] || die "--version needs --commit"
check_version "$version"
dateutc=$(date -Ru)
cat <<EOF > debian/changelog
libre-computer-archive-keyring ($version) linux; urgency=medium

  * $commit

 -- Da Xue <da@libre.computer>  $dateutc
EOF
dpkg-buildpackage -uc --no-sign --build=all
