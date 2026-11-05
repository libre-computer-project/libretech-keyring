#!/bin/bash
# packaging/lib.sh -- shared by build-rpm.sh and build-arch.sh: every per-format key file is derived from the one
# committed key, libre-computer-deb.gpg, so a renewal or rotation is one file change and one rebuild per format.

PKG_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKG_KEY=${PKG_KEY:-$PKG_ROOT/libre-computer-deb.gpg}

log() { printf '%s: %s\n' "$(basename "$0")" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# A private GnuPG home holding only the committed key; removed by the caller's cleanup.
key_home() {
	local h=$1
	install -d -m 700 "$h"
	gpg --batch --quiet --homedir "$h" --import "$PKG_KEY" 2>/dev/null || die "cannot read the key $PKG_KEY"
}

# The primary key's full fingerprint (exactly one primary key is expected).
key_fpr() {
	local n
	n=$(gpg --batch --homedir "$1" --with-colons --list-keys | awk -F: '$1 == "pub"' | wc -l)
	[[ $n == 1 ]] || die "$PKG_KEY holds $n primary keys; expected 1"
	gpg --batch --homedir "$1" --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}'
}

key_armored() { gpg --batch --homedir "$1" --armor --export "$(key_fpr "$1")"; }

key_binary() { gpg --batch --homedir "$1" --export "$(key_fpr "$1")"; }

# rpm names an imported key gpg-pubkey-<last 8 hex of the key id, lowercase>; `rpmkeys --delete` takes that.
key_rpm_id() { key_fpr "$1" | tail -c 9 | tr 'A-F' 'a-f'; }

# Today's UTC date, the version scheme every Libre Computer package uses.
default_version() { date -u +%Y.%m.%d; }

source_commit() { git -C "$PKG_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown; }
