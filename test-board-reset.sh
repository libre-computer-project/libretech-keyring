#!/bin/bash
# test-board-reset.sh -- undo test-board-move.sh on a board: back to a deb.libre.computer owner's state, so the
# move can be tested again. Run as root on the board.
#
#   bash test-board-reset.sh [--dry-run] <dir holding: libre-computer-deb.list.orig, real-key.gpg>
#
# (test-board-move.sh leaves both files in its dir: the board's original deb.libre.computer list and
# deb.libre.computer's key.) It purges the libre-computer names and both keyrings, drops packages.libre.computer's
# source and the migration state, puts the original list and the key back, and installs libretech-gpio and
# libretech-dtoverlay from deb.libre.computer -- whatever version it serves now (an owner's apt upgrade), since an
# older one may no longer be in its pool. Only the Libre Computer source is read; Debian's are untouched.
# --dry-run prints apt's plan (its Remv/Inst lines) and changes nothing.
#
# Style: software/convention/bash.md
set -euo pipefail

die() { echo "test-board-reset: $*" >&2; exit 1; }

DRY=0
[[ ${1:-} == --dry-run ]] && { DRY=1; shift; }
D=$(cd "${1:?usage: test-board-reset.sh [--dry-run] <dir>}" && pwd)
[[ $EUID -eq 0 ]] || die "needs root"
[[ -s "$D/libre-computer-deb.list.orig" && -s "$D/real-key.gpg" ]] || die "$D lacks libre-computer-deb.list.orig or real-key.gpg"
KEY=/usr/share/keyrings/libre-computer-deb.gpg
LIST=/etc/apt/sources.list.d/libre-computer-deb.list
SRC=/etc/apt/sources.list.d/libre-computer.sources
OURS=(-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts=/etc/apt/sources.list.d)
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin  # su -c keeps a user PATH
NEW=(libre-computer-gpio libre-computer-dtoverlay libre-computer-alsa-ucm-conf libre-computer-archive-keyring libretech-keyring)
OLD=(libretech-gpio libretech-dtoverlay)

present() { local p out=(); for p in "$@"; do dpkg-query -W -f '${db:Status-Status}\n' "$p" 2>/dev/null | grep -qx installed && out+=("$p"); done; echo "${out[@]}"; }

if (( DRY )); then
	echo "would purge: $(present "${NEW[@]}" "${OLD[@]}")"
	echo "would install from deb.libre.computer: ${OLD[*]}"
	exit 0
fi

systemctl stop libre-computer-migrate-now.timer libre-computer-migrate.service 2>/dev/null || true
systemctl disable libre-computer-migrate.service 2>/dev/null || true
read -r -a P <<< "$(present "${NEW[@]}" "${OLD[@]}")"
(( ${#P[@]} == 0 )) || dpkg --purge "${P[@]}"
rm -f -- "$SRC"
rm -rf -- /var/lib/libre-computer-archive-keyring
install -m 0644 "$D/real-key.gpg" "$KEY"
install -m 0644 "$D/libre-computer-deb.list.orig" "$LIST"
apt-get "${OURS[@]}" -q update
# apt safety: the install must remove nothing
plan=$(mktemp)
apt-get "${OURS[@]}" -s install "${OLD[@]}" > "$plan"
! grep -q '^Remv' "$plan" || { grep '^Remv' "$plan"; rm -f -- "$plan"; die "the install would remove packages; stopped"; }
rm -f -- "$plan"
apt-get "${OURS[@]}" -y -q install "${OLD[@]}"
echo "test-board-reset: done"
for p in libretech-keyring libretech-gpio libretech-dtoverlay libre-computer-archive-keyring libre-computer-gpio; do
	echo "$p: $(dpkg-query -W -f '${db:Status-Status} ${Version}' "$p" 2>/dev/null || echo not-installed)"
done
grep -h -v '^#' "$LIST"
