#!/bin/bash
# test-deb-move.sh -- libre-computer-archive-keyring moving a board off deb.libre.computer, in copies
# of a Debian image (an os-factory uefi image, which already has the libretech-* packages installed).
# The repository the board moves to is a local one, signed by a throwaway key that the test puts in
# place of the shipped key, so nothing here turns a signature check off. Its new-name packages are
# stand-ins: each Breaks and Replaces its old name, as the real ones do.
#
#   sudo ./test-deb-move.sh <image.img> <dir with the built libre-computer-archive-keyring and libretech-keyring .debs>
#
#   S1  a board on deb.libre.computer, Debian 13: the source moves, the old one is set aside, the
#       migration is pending; the migration then installs every new name and leaves no old one
#   S2  a release packages.libre.computer does not serve: nothing moves
#   S3  a board following another kernel channel (lc-lts-testing): nothing moves
#   S4  a board already on packages.libre.computer: nothing moves, nothing pending
# Exit 0 iff every check passes.

set -uo pipefail
img=${1:?usage: sudo ./test-deb-move.sh <image.img> <debs-dir>}
debs=$(realpath -e "${2:?usage: sudo ./test-deb-move.sh <image.img> <debs-dir>}")
[[ $EUID -eq 0 ]] || { echo "needs root" >&2; exit 1; }
W=$(mktemp -d "${SUDO_HOME:-/root}/test-deb-move-XXXXXX" 2>/dev/null || mktemp -d)
PASS=0 FAIL=0
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "PASS  $what"; else FAIL=$((FAIL + 1)); echo "FAIL  $what"; fi; }
mnt="" loop=""
cleanup() {
	[[ -z "$mnt" ]] || { umount -R "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
	[[ -z "$loop" ]] || losetup -d "$loop" 2>/dev/null || true
	mnt="" loop=""
}
trap 'cleanup; rm -rf "$W"' EXIT
new_keyring=$(find "$debs" -maxdepth 1 -name 'libre-computer-archive-keyring_*_all.deb' -print -quit)
trans_keyring=$(find "$debs" -maxdepth 1 -name 'libretech-keyring_*_all.deb' -print -quit)
[[ -n "$new_keyring" && -n "$trans_keyring" ]] || { echo "no keyring .debs in $debs" >&2; exit 1; }

# --- the local repository: stand-ins for the new names, signed by a throwaway key -------------------
G=$W/gnupg
install -d -m 700 "$G"
gpg --batch --quiet --homedir "$G" --pinentry-mode loopback --passphrase '' \
	--quick-gen-key 'test-deb-move <test@invalid>' ed25519 sign never 2>/dev/null
gpg --batch --homedir "$G" --export > "$W/test-key.gpg"
R=$W/repo
mkdir -p "$R/pool"
standin() { # NEW OLD
	local d=$W/pkg-$1
	mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1"
	printf 'Package: %s\nVersion: 2026.11.10\nArchitecture: all\nMaintainer: t <t@invalid>\nBreaks: %s (<< 2026.11.10)\nReplaces: %s (<< 2026.11.10)\nDescription: stand-in for %s\n' \
		"$1" "$2" "$2" "$1" > "$d/DEBIAN/control"
	echo "stand-in" > "$d/usr/share/doc/$1/README"
	dpkg-deb --root-owner-group -b "$d" "$R/pool/$1.deb" >/dev/null
}
standin libre-computer-gpio libretech-gpio
standin libre-computer-dtoverlay libretech-dtoverlay
standin alsa-ucm-conf-libre-computer libretech-alsa-ucm-conf
standin xserver-xorg-core-libre-computer xserver-xorg-video-libretech
cp "$new_keyring" "$trans_keyring" "$R/pool/"
for s in trixie; do
	mkdir -p "$R/dists/$s/main/binary-arm64" "$R/dists/$s/main/binary-all" "$R/dists/$s/non-free/binary-arm64"
	(cd "$R" && apt-ftparchive packages pool > "dists/$s/main/binary-arm64/Packages")
	: > "$R/dists/$s/non-free/binary-arm64/Packages"
	cp "$R/dists/$s/main/binary-arm64/Packages" "$R/dists/$s/main/binary-all/Packages"
	apt-ftparchive -o APT::FTPArchive::Release::Codename="$s" -o APT::FTPArchive::Release::Suite="$s" \
		-o APT::FTPArchive::Release::Components="main non-free" -o APT::FTPArchive::Release::Architectures="arm64 all" \
		release "$R/dists/$s" > "$W/Release"
	mv "$W/Release" "$R/dists/$s/Release"
	gpg --batch --homedir "$G" --clearsign -o "$R/dists/$s/InRelease" "$R/dists/$s/Release"
done

# --- a copy of the image as a chroot, with the repository at /srv/test-repo ------------------------
setup() {
	cp --reflink=auto "$img" "$W/t.img"
	loop=$(losetup -fP --show "$W/t.img")
	udevadm settle
	mnt=$(mktemp -d)
	mount "${loop}p2" "$mnt"
	local m
	for m in dev dev/pts proc sys; do mount --bind "/$m" "$mnt/$m"; done
	mount -t tmpfs tmpfs "$mnt/run"
	mount -t tmpfs tmpfs "$mnt/tmp"
	mkdir -p "$mnt/srv/test-repo"
	mount --bind "$R" "$mnt/srv/test-repo"
	cp "$new_keyring" "$trans_keyring" "$mnt/tmp/"
	# an old board: deb.libre.computer's source, and no packages.libre.computer one
	rm -f "$mnt/etc/apt/sources.list.d/libre-computer.sources"
	echo 'deb [signed-by=/usr/share/keyrings/libre-computer-deb.gpg] https://deb.libre.computer/repo linux main' \
		> "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
}
in_root() { chroot "$mnt" "$@"; }
installed() { [[ "$(chroot "$mnt" dpkg-query -W -f '${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]; }
install_keyring() { # the two keyring packages, through apt as a board takes them (plain dpkg -i cannot
	# order the swap: it refuses to unpack the new keyring while the old one is configured)
	chroot "$mnt" env LC_PACKAGES_URI=file:///srv/test-repo DEBIAN_FRONTEND=noninteractive \
		apt-get -y -q install "/tmp/${new_keyring##*/}" "/tmp/${trans_keyring##*/}" > "$W/dpkg.log" 2>&1 ||
		{ echo "-- installing the keyring failed:"; tail -n 15 "$W/dpkg.log"; }
}

echo "== S1: a Debian 13 board on deb.libre.computer"
setup
check "S1: the image has the old names installed (the test's precondition)" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-gpio && installed libretech-dtoverlay && installed libretech-alsa-ucm-conf && installed xserver-xorg-video-libretech"
install_keyring
check "S1: the keyring packages install" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-archive-keyring && installed libretech-keyring"
check "S1: the source now names the repository, trixie, main non-free, signed by the shipped key path" bash -c "grep -qx 'URIs: file:///srv/test-repo' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -qx 'Suites: trixie' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -qx 'Components: main non-free' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -qx 'Signed-By: /usr/share/keyrings/libre-computer-deb.gpg' '$mnt/etc/apt/sources.list.d/libre-computer.sources'"
check "S1: deb.libre.computer's source is set aside, read by apt no more" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -s '$mnt/var/lib/libre-computer-archive-keyring/moved-sources/libre-computer-deb.list'"
check "S1: the migration is pending and enabled for the next boot" bash -c "test -e '$mnt/var/lib/libre-computer-archive-keyring/migrate-pending' && test -L '$mnt/etc/systemd/system/multi-user.target.wants/libre-computer-migrate.service'"
# the throwaway key in place of the shipped one, for this repository only
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/migrate.log" 2>&1
check "S1: the migration succeeds" grep -q 'done: the board reads packages.libre.computer' "$W/migrate.log"
for p in libre-computer-gpio libre-computer-dtoverlay alsa-ucm-conf-libre-computer xserver-xorg-core-libre-computer libre-computer-archive-keyring; do
	check "S1: $p installed" bash -c "$(declare -f installed); mnt='$mnt'; installed $p"
done
for p in libretech-gpio libretech-dtoverlay libretech-alsa-ucm-conf xserver-xorg-video-libretech libretech-keyring; do
	check "S1: $p gone" bash -c "$(declare -f installed); mnt='$mnt'; ! installed $p"
done
check "S1: the key file is still in place (it changed package, not path)" test -s "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
check "S1: nothing pending, the unit disabled" bash -c "test ! -e '$mnt/var/lib/libre-computer-archive-keyring/migrate-pending' && test ! -e '$mnt/etc/systemd/system/multi-user.target.wants/libre-computer-migrate.service'"
in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/migrate2.log" 2>&1
check "S1: a second run does nothing" bash -c "[[ ! -s '$W/migrate2.log' ]]"
cleanup

echo "== S2: a release packages.libre.computer does not serve"
setup
# /etc/os-release is Debian's link to /usr/lib/os-release
sed -i -E 's/^VERSION_CODENAME=.*/VERSION_CODENAME=bullseye/' "$mnt/usr/lib/os-release"
install_keyring
check "S2: stays on deb.libre.computer, and says so" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -q 'not served by packages.libre.computer' '$W/dpkg.log'"
check "S2: nothing pending" test ! -e "$mnt/var/lib/libre-computer-archive-keyring/migrate-pending"
cleanup

echo "== S3: a board following lc-lts-testing"
setup
d=$W/pkg-chan
mkdir -p "$d/DEBIAN"
printf 'Package: linux-image-lc-lts-testing-arm64\nVersion: 1\nArchitecture: all\nMaintainer: t <t@invalid>\nDescription: stand-in channel meta\n' > "$d/DEBIAN/control"
dpkg-deb --root-owner-group -b "$d" "$mnt/tmp/chan.deb" >/dev/null
in_root dpkg -i /tmp/chan.deb >/dev/null 2>&1
install_keyring
check "S3: stays on deb.libre.computer, naming the channel" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -q 'linux-image-lc-lts-testing-arm64' '$W/dpkg.log'"
check "S3: nothing pending" test ! -e "$mnt/var/lib/libre-computer-archive-keyring/migrate-pending"
cleanup

echo "== S4: a board already on packages.libre.computer"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://packages.libre.computer/deb\nSuites: trixie\nComponents: main non-free\nSigned-By: /usr/share/keyrings/libre-computer-deb.gpg\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
cp "$mnt/etc/apt/sources.list.d/libre-computer.sources" "$W/s4.before"
install_keyring
check "S4: its source is untouched" cmp -s "$W/s4.before" "$mnt/etc/apt/sources.list.d/libre-computer.sources"
check "S4: nothing pending" test ! -e "$mnt/var/lib/libre-computer-archive-keyring/migrate-pending"
cleanup

echo "test-deb-move: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
