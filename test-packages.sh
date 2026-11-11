#!/bin/bash
# test-packages.sh -- build the Fedora and Arch keyring packages and check what they install and how a key
# renewal reaches a host. Run on a host with rpmbuild, makepkg, bsdtar and gpg. Writes only to a
# temporary directory it removes. Exit 0 iff every check passes.
#
#   RPM   the package holds the key file and the .repo; its key is the committed key; its %posttrans, run
#         against a scratch rpm database holding an OLDER copy of a key, leaves the NEWER copy stored -- and the
#         same import without the delete leaves the old one (why the delete is there).
#   ARCH  the package holds the three keyring files and the install hook; -trusted names the primary
#         fingerprint with full trust; `pacman-key --populate-from` loads the key into a scratch keyring.
#   BOTH  a key file holding two primary keys is refused.

set -uo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
V=2099.01.02
G=$T/gnupg
install -d -m 700 "$G"
gpg --batch --quiet --homedir "$G" --import "$HERE/libre-computer-deb.gpg" 2>/dev/null
FPR=$(gpg --batch --homedir "$G" --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}')

# --- RPM ------------------------------------------------------------------
rpm=$(bash "$HERE/build-rpm.sh" --version "$V" --out "$T/out" 2>"$T/rpm.err" | tail -1)
if [[ -f $rpm ]]; then ok "rpm builds: $(basename "$rpm")"; else bad "rpm builds"; cat "$T/rpm.err"; fi
if [[ -f $rpm ]]; then
	files=$(rpm -qlp "$rpm" 2>/dev/null)
	check "rpm installs the key under /etc/pki/rpm-gpg" grep -qx /etc/pki/rpm-gpg/RPM-GPG-KEY-libre-computer <<<"$files"
	check "rpm installs /etc/yum.repos.d/libre-computer.repo" grep -qx /etc/yum.repos.d/libre-computer.repo <<<"$files"
	check "rpm is noarch" test "$(rpm -qp --qf '%{ARCH}' "$rpm" 2>/dev/null)" = noarch
	check "rpm is libre-computer-release, obsoleting and providing libre-computer-repos (its name until 2026-11-11)" \
		bash -c "[[ \$(rpm -qp --qf '%{NAME}' '$rpm' 2>/dev/null) == libre-computer-release ]] &&
			rpm -qp --obsoletes '$rpm' 2>/dev/null | grep -q '^libre-computer-repos < ' &&
			rpm -qp --provides '$rpm' 2>/dev/null | grep -q '^libre-computer-repos = '"
	check "rpm header names the published host, not the builder" test "$(rpm -qp --qf '%{BUILDHOST}' "$rpm" 2>/dev/null)" = deb.libre.computer
	mkdir -p "$T/x" && (cd "$T/x" && rpm2archive -n - <"$rpm" 2>/dev/null | bsdtar -xf - 2>/dev/null)
	ifpr=$(gpg --batch --with-colons --show-keys "$T/x/etc/pki/rpm-gpg/RPM-GPG-KEY-libre-computer" 2>/dev/null |
		awk -F: '$1 == "fpr" {print $10; exit}')
	check "rpm's key is the committed key ($FPR)" test "$ifpr" = "$FPR"
	check "rpm's repo file points at packages.libre.computer with gpgcheck and repo_gpgcheck" \
		bash -c "grep -q '^baseurl=https://packages.libre.computer/rpm/fedora/\$releasever/\$basearch/' '$T/x/etc/yum.repos.d/libre-computer.repo' &&
			grep -qx 'gpgcheck=1' '$T/x/etc/yum.repos.d/libre-computer.repo' && grep -qx 'repo_gpgcheck=1' '$T/x/etc/yum.repos.d/libre-computer.repo'"
	scripts=$(rpm -qp --scripts "$rpm" 2>/dev/null)
	check "rpm's %posttrans deletes the stored key by its rpm id, then imports" \
		bash -c "grep -q 'rpmkeys --delete $(printf '%s' "$FPR" | tail -c 8 | tr 'A-F' 'a-f')' <<<'$scripts' && grep -q 'rpmkeys --import' <<<'$scripts'"

	# A renewal, in miniature: a throwaway key exported before and after a new expiry.
	R=$T/renew
	install -d -m 700 "$R"
	gpg --batch --quiet --homedir "$R" --passphrase '' --quick-gen-key 'renewal test <renew@example.invalid>' rsa2048 sign 1y 2>/dev/null
	rfpr=$(gpg --batch --homedir "$R" --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}')
	gpg --batch --homedir "$R" --armor --export "$rfpr" >"$T/old.asc"
	gpg --batch --quiet --homedir "$R" --passphrase '' --pinentry-mode loopback --quick-set-expire "$rfpr" 5y 2>/dev/null
	gpg --batch --homedir "$R" --armor --export "$rfpr" >"$T/new.asc"
	rid=$(printf '%s' "$rfpr" | tail -c 8 | tr 'A-F' 'a-f')
	stored() { rpm --dbpath "$1" -q gpg-pubkey --qf '%{DESCRIPTION}' 2>/dev/null | sha256sum | cut -c1-16; }
	newsum=$(sha256sum <"$T/new.asc" | cut -c1-16)
	# the package's own %posttrans lines, aimed at a scratch database and the throwaway key
	post=$(sed -n '/^posttrans scriptlet/,$p' <<<"$scripts" | grep '^rpmkeys' |
		sed -e "s#rpmkeys #rpmkeys --dbpath $T/db #" -e "s#--delete [0-9a-f]*#--delete $rid#" \
			-e "s#/etc/pki/rpm-gpg/RPM-GPG-KEY-libre-computer#$T/new.asc#")
	mkdir -p "$T/db" "$T/db2"
	rpmkeys --dbpath "$T/db" --import "$T/old.asc" 2>/dev/null
	bash -c "$post" 2>/dev/null
	check "%posttrans replaces an older stored copy of the key with the renewed one" test "$(stored "$T/db")" = "$newsum"
	rpmkeys --dbpath "$T/db2" --import "$T/old.asc" 2>/dev/null
	rpmkeys --dbpath "$T/db2" --import "$T/new.asc" 2>/dev/null
	check "must-differ: import alone keeps the older copy (so the delete is needed)" test "$(stored "$T/db2")" != "$newsum"
fi

# --- ARCH -----------------------------------------------------------------
pkg=$(bash "$HERE/build-arch.sh" --version "$V" --out "$T/out" 2>"$T/arch.err" | tail -1)
if [[ -f $pkg ]]; then ok "pacman package builds: $(basename "$pkg")"; else bad "pacman package builds"; cat "$T/arch.err"; fi
if [[ -f $pkg ]]; then
	list=$(bsdtar -tf "$pkg" 2>/dev/null)
	for f in libre-computer.gpg libre-computer-trusted libre-computer-revoked; do
		check "pacman package installs usr/share/pacman/keyrings/$f" grep -qx "usr/share/pacman/keyrings/$f" <<<"$list"
	done
	check "pacman package carries the install hook" grep -qx .INSTALL <<<"$list"
	check "the install hook's stanza requires signatures (SigLevel = Required, not pacman's DatabaseOptional default)" \
		grep -q '^    SigLevel = Required$' <(bsdtar -xOf "$pkg" .INSTALL 2>/dev/null)
	check "pacman package is arch=any" grep -qx 'arch = any' <(bsdtar -xOf "$pkg" .PKGINFO 2>/dev/null)
	mkdir -p "$T/k" && bsdtar -xf "$pkg" -C "$T/k" usr/share/pacman/keyrings 2>/dev/null
	check "-trusted is the primary fingerprint with full trust" test "$(cat "$T/k/usr/share/pacman/keyrings/libre-computer-trusted")" = "$FPR:4:"
	check "-revoked is empty" test ! -s "$T/k/usr/share/pacman/keyrings/libre-computer-revoked"
	afpr=$(gpg --batch --with-colons --show-keys "$T/k/usr/share/pacman/keyrings/libre-computer.gpg" 2>/dev/null |
		awk -F: '$1 == "fpr" {print $10; exit}')
	check "the packaged key is the committed key" test "$afpr" = "$FPR"
	if unshare -r true 2>/dev/null; then
		unshare -r bash -c "pacman-key --gpgdir '$T/pk' --init >/dev/null 2>&1 &&
			pacman-key --gpgdir '$T/pk' --populate-from '$T/k/usr/share/pacman/keyrings' --populate libre-computer >/dev/null 2>&1 &&
			gpg --homedir '$T/pk' --with-colons --list-keys '$FPR' | grep -q '^pub:[fu]:'" >/dev/null 2>&1
		if (($? == 0)); then ok "pacman-key --populate loads the key with full validity"; else bad "pacman-key --populate loads the key with full validity"; fi
	else
		printf 'SKIP  pacman-key --populate (no user namespaces here)\n'
	fi
fi

# --- BOTH: a key file with two primaries is refused --------------------------
D=$T/two
install -d -m 700 "$D"
gpg --batch --quiet --homedir "$D" --passphrase '' --quick-gen-key 'two <two@example.invalid>' ed25519 sign never 2>/dev/null
gpg --batch --homedir "$D" --export >"$T/two.gpg"
cat "$HERE/libre-computer-deb.gpg" >>"$T/two.gpg"
if PKG_KEY=$T/two.gpg bash "$HERE/build-rpm.sh" --version "$V" --out "$T/two-out" >/dev/null 2>"$T/two.err"; then
	bad "must-fail: a key file with two primary keys is refused (rpm)"
else
	check "must-fail: a key file with two primary keys is refused (rpm)" grep -q 'primary keys' "$T/two.err"
fi
if PKG_KEY=$T/two.gpg bash "$HERE/build-arch.sh" --version "$V" --out "$T/two-out" >/dev/null 2>"$T/two.err"; then
	bad "must-fail: a key file with two primary keys is refused (arch)"
else
	check "must-fail: a key file with two primary keys is refused (arch)" grep -q 'primary keys' "$T/two.err"
fi

printf 'test-packages: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
((FAIL == 0))
