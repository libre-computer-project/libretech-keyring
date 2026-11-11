#!/bin/bash
# test-image-move.sh -- the deb.libre.computer -> packages.libre.computer move in a copy of one PUBLISHED image
# (distro.libre.computer/ci: Debian, Raspbian, Ubuntu; arm64 or armhf, run under qemu-user binfmt on another
# arch). The owner's path, as on a board: the renewed libretech-keyring by hand, then deb.libre.computer serving
# the self-contained libretech-keyring (build-deblibre.sh) and an ordinary `apt-get update && apt-get upgrade`.
# A release packages.libre.computer serves moves, and the migration installs the new names; any other stays on
# deb.libre.computer, saying why. Both repositories are local stand-ins signed by a throwaway key put in place of
# the shipped one; the new names are stand-ins that Break, Replace and Provide their old names, as the real ones do.
# The migration installs no kernel: a renamed kernel meta-package (armhf -arm -> -armhf) follows the owner's own
# upgrade, run here as `apt-get upgrade --with-new-pkgs` (what `apt upgrade` does) when the transitional is served.
# Only Libre Computer's source is read (the image's own sources are set aside for the test).
#
#   sudo ./test-image-move.sh <image.img> <debs dir> <real-keyring.deb> [<real packages dir>]
#
# <debs dir>: the built libre-computer-archive-keyring, its transitional libretech-keyring and the
# ~deb.libre.computer libretech-keyring. <real-keyring.deb>: deb.libre.computer's libretech-keyring 2026.11.05.
# <real packages dir>: built packages served in place of the stand-ins of the same name, with what they depend
# on (e.g. linux-image-lc-lts-armhf, its transitional linux-image-lc-lts-arm and the kernel image).
# Prints PASS/FAIL per check and one RESULT line; exit 0 iff every check passes.
#
# Style: software/convention/bash.md
set -uo pipefail

img=${1:?usage: sudo ./test-image-move.sh <image.img> <debs dir> <real-keyring.deb>}
debs=$(realpath -e "${2:?usage}")
realkr=$(realpath -e "${3:?usage}")
realpkgs=${4:+$(realpath -e "$4")}
[[ $EUID -eq 0 ]] || { echo "needs root" >&2; exit 1; }
W=$(mktemp -d "${SUDO_HOME:-/root}/test-image-move-XXXXXX" 2>/dev/null || mktemp -d)
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
deblibre_keyring=$(find "$debs" -maxdepth 1 -name 'libretech-keyring_*~deb.libre.computer_all.deb' -print -quit)
[[ -n "$new_keyring" && -n "$deblibre_keyring" ]] || { echo "no keyring .debs in $debs" >&2; exit 1; }

# --- a copy of the image, its root partition mounted as a chroot ------------------------------------
cp --reflink=auto "$img" "$W/t.img"
loop=$(losetup -fP --show "$W/t.img")
udevadm settle
mnt=$(mktemp -d)
for p in "$loop"p*; do
	mount "$p" "$mnt" 2>/dev/null || continue
	[[ -e "$mnt/usr/lib/os-release" || -e "$mnt/etc/os-release" ]] && break
	umount "$mnt"
done
mountpoint -q "$mnt" || { echo "no root partition in $img" >&2; exit 1; }
for m in dev dev/pts proc sys; do mount --bind "/$m" "$mnt/$m"; done
mount -t tmpfs tmpfs "$mnt/run"
mount -t tmpfs tmpfs "$mnt/tmp"
in_root() { chroot "$mnt" "$@"; }
installed() { [[ "$(chroot "$mnt" dpkg-query -W -f '${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]; }
ver() { chroot "$mnt" dpkg-query -W -f '${Version}' "$1" 2>/dev/null; }

osr=$mnt/etc/os-release
[[ -e "$osr" ]] || osr=$mnt/usr/lib/os-release
ID=$(. "$osr"; echo "${ID:-}")
CODENAME=$(. "$osr"; echo "${VERSION_CODENAME:-}")
ARCH=$(in_root dpkg --print-architecture)
# the oracle, written independently of libre-computer-move: which releases packages.libre.computer serves
case "$ID:$CODENAME" in
	debian:bookworm | debian:trixie | ubuntu:noble | ubuntu:resolute) expect=$CODENAME ;;
	raspbian:bookworm) expect=bookworm ;;
	*) expect=stay ;;
esac
pairs="libretech-gpio:libre-computer-gpio libretech-dtoverlay:libre-computer-dtoverlay
libretech-alsa-ucm-conf:alsa-ucm-conf-libre-computer xserver-xorg-video-libretech:xserver-xorg-core-libre-computer
linux-image-lc-lts-arm:linux-image-lc-lts-armhf linux-headers-lc-lts-arm:linux-headers-lc-lts-armhf"
old=""
for p in $pairs; do installed "${p%%:*}" && old="$old ${p%%:*}"; done
kernels=$(in_root dpkg-query -W -f '${db:Status-Status} ${Package}\n' 'linux-image-lc-*' 2>/dev/null | awk '$1 == "installed" {print $2}' | tr '\n' ' ')
lclist=$(grep -l 'deb\.libre\.computer' "$mnt"/etc/apt/sources.list.d/* 2>/dev/null | head -n 1)
echo "== $(basename "$img"): $ID $CODENAME $ARCH; expect: $expect; old names:${old:- none}; kernels: ${kernels:-none}"
echo "   its deb.libre.computer source: ${lclist:-none}: $( [[ -n "$lclist" ]] && grep -h -v '^#' "$lclist")"

# --- the stand-in repositories --------------------------------------------------------------------
G=$W/gnupg
install -d -m 700 "$G"
gpg --batch --quiet --homedir "$G" --pinentry-mode loopback --passphrase '' \
	--quick-gen-key 'test-image-move <test@invalid>' ed25519 sign never 2>/dev/null
gpg --batch --homedir "$G" --export > "$W/test-key.gpg"
# suite <root> <suite> <components...>: index root/pool into every arch, sign
suite() {
	local root=$1 s=$2 c a
	shift 2
	for c in "$@"; do for a in arm64 armhf; do
		mkdir -p "$root/dists/$s/$c/binary-$a"
		: > "$root/dists/$s/$c/binary-$a/Packages"
	done; done
	# each arch's own packages and the Architecture: all ones (-a alone leaves the latter out)
	for a in arm64 armhf; do
		(cd "$root" && { apt-ftparchive -a "$a" packages pool; apt-ftparchive -a all packages pool; } > "dists/$s/main/binary-$a/Packages")
	done
	apt-ftparchive -o APT::FTPArchive::Release::Codename="$s" -o APT::FTPArchive::Release::Suite="$s" \
		-o APT::FTPArchive::Release::Components="$*" -o APT::FTPArchive::Release::Architectures="arm64 armhf" \
		release "$root/dists/$s" > "$W/Release"
	mv "$W/Release" "$root/dists/$s/Release"
	gpg --batch --homedir "$G" --clearsign -o "$root/dists/$s/InRelease" "$root/dists/$s/Release"
}
standin() { # NEW OLD
	local d=$W/pkg-$1
	mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1"
	printf 'Package: %s\nVersion: 2026.11.10\nArchitecture: all\nMaintainer: t <t@invalid>\nBreaks: %s (<< 2026.11.10)\nReplaces: %s (<< 2026.11.10)\nProvides: %s (= 2026.11.10)\nDescription: stand-in for %s\n' \
		"$1" "$2" "$2" "$2" "$1" > "$d/DEBIAN/control"
	echo stand-in > "$d/usr/share/doc/$1/README"
	# a Debian file name: apt-ftparchive -a picks a package's arch from it
	dpkg-deb --root-owner-group -b "$d" "$W/pkgs/${1}_2026.11.10_all.deb" >/dev/null
}
P=$W/packages/deb
mkdir -p "$W/pkgs" "$P/pool"
for p in $pairs; do standin "${p#*:}" "${p%%:*}"; done
if [[ -n "$realpkgs" ]]; then
	for d in "$realpkgs"/*.deb; do
		rm -f -- "$W/pkgs/$(dpkg-deb -f "$d" Package)_2026.11.10_all.deb"   # a real package replaces its stand-in
		cp "$d" "$W/pkgs/"
		echo "   real: $(dpkg-deb -f "$d" Package) $(dpkg-deb -f "$d" Version)"
	done
fi
cp "$W"/pkgs/*.deb "$new_keyring" "$P/pool/"
[[ $expect == stay ]] || suite "$P" "$expect" main non-free
D=$W/deb.libre.computer/repo
mkdir -p "$D/pool"
cp "$deblibre_keyring" "$D/pool/"
suite "$D" linux main non-free
mkdir -p "$mnt/srv/test-repo" "$mnt/srv/deb.libre.computer"
mount --bind "$P" "$mnt/srv/test-repo"
mount --bind "$W/deb.libre.computer" "$mnt/srv/deb.libre.computer"

# --- the owner's state: deb.libre.computer's source, only it read, the renewed keyring by hand -------
mkdir -p "$mnt/root/test-image-move-sources"
for f in "$mnt"/etc/apt/sources.list.d/*; do
	[[ -e "$f" && "$f" != "$lclist" ]] && mv "$f" "$mnt/root/test-image-move-sources/"
done
if [[ -n "$lclist" ]]; then
	sed -i 's|https\?://deb\.libre\.computer/repo|file:///srv/deb.libre.computer/repo|' "$lclist"
else
	lclist=$mnt/etc/apt/sources.list.d/libre-computer-deb.list
	echo 'deb [signed-by=/usr/share/keyrings/libre-computer-deb.gpg] file:///srv/deb.libre.computer/repo linux main' > "$lclist"
fi
printf 'Dir::Etc::SourceList "/dev/null";\n' > "$mnt/etc/apt/apt.conf.d/00test-image-move"
cp "$realkr" "$mnt/tmp/real-keyring.deb"
in_root env DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/real-keyring.deb > "$W/1-realkr.log" 2>&1
check "1: deb.libre.computer's libretech-keyring 2026.11.05 installs by hand" installed libretech-keyring
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
in_root apt-get -q update > "$W/2-update.log" 2>&1
check "2: apt reads the stand-in deb.libre.computer, signature checked" bash -c "! grep -qE '^(E|W): ' '$W/2-update.log'"
before=$(ver libretech-keyring)
cp "$W/test-key.gpg" "$P/test-key.gpg"   # /srv/test-repo in the chroot
in_root env LC_PACKAGES_URI=file:///srv/test-repo LC_PACKAGES_KEY=/srv/test-repo/test-key.gpg DEBIAN_FRONTEND=noninteractive apt-get -y -q upgrade > "$W/3-upgrade.log" 2>&1
check "3: apt-get upgrade takes the self-contained libretech-keyring ($before -> $(ver libretech-keyring))" bash -c "[[ '$(ver libretech-keyring)' == *~deb.libre.computer ]]"
grep -h 'libre-computer-archive-keyring:' "$W/3-upgrade.log" | sed 's/^/   /'
src=$mnt/etc/apt/sources.list.d/libre-computer.sources
state=$mnt/var/lib/libre-computer-archive-keyring

if [[ $expect == stay ]]; then
	check "4: stays on deb.libre.computer, and says why" bash -c "test -s '$lclist' && test ! -e '$src' && grep -qE 'not served by packages.libre.computer|kernel channel' '$W/3-upgrade.log'"
	check "4: nothing pending" test ! -e "$state/migrate-pending"
	result="stayed"
else
	check "4: moved to packages.libre.computer, suite $expect" bash -c "test ! -e '$lclist' && grep -qx 'URIs: file:///srv/test-repo' '$src' && grep -qx 'Suites: $expect' '$src'"
	check "4: the migration is pending" test -e "$state/migrate-pending"
	cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
	in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/5-migrate.log" 2>&1
	grep -h '^libre-computer-migrate:' "$W/5-migrate.log" | sed 's/^/   /'
	check "5: the migration finishes" grep -q 'done: the board reads packages.libre.computer' "$W/5-migrate.log"
	grep -q 'done: the board reads packages.libre.computer' "$W/5-migrate.log" ||
		{ echo "   -- the migration's last lines:"; tail -n 25 "$W/5-migrate.log" | sed 's/^/   | /'; }
	check "5: libre-computer-archive-keyring in, libretech-keyring gone" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-archive-keyring && ! installed libretech-keyring"
	for p in $pairs; do
		o=${p%%:*} n=${p#*:}
		[[ " $old " == *" $o "* ]] || continue
		case $o in
			linux-*) check "5: $o kept, $n not installed by the migration" bash -c "$(declare -f installed); mnt='$mnt'; installed $o && ! installed $n" ;;
			*) check "5: $o -> $n" bash -c "$(declare -f installed); mnt='$mnt'; installed $n && ! installed $o" ;;
		esac
	done
	check "5: nothing pending" test ! -e "$state/migrate-pending"
	if [[ " $old " == *" linux-image-lc-lts-arm "* ]] && compgen -G "$P/pool/linux-image-lc-lts-arm_*.deb" >/dev/null; then
		in_root env DEBIAN_FRONTEND=noninteractive apt-get -y -q --with-new-pkgs upgrade > "$W/6-upgrade.log" 2>&1
		check "6: the owner's upgrade brings linux-image-lc-lts-armhf through the transitional -arm" bash -c "$(declare -f installed); mnt='$mnt'; installed linux-image-lc-lts-armhf"
		in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/7-migrate.log" 2>&1
		check "7: the timer's next run removes linux-image-lc-lts-arm, nothing pending" bash -c "$(declare -f installed); mnt='$mnt'; ! installed linux-image-lc-lts-arm && test ! -e '$state/kernel-pending'"
		check "7: autoremove keeps linux-image-lc-lts-armhf" bash -c "! chroot '$mnt' apt-get -s autoremove 2>/dev/null | grep -q '^Remv linux-image-lc-lts-armhf '"
	fi
	check "5: dpkg --audit says nothing" bash -c "[[ -z \$(chroot '$mnt' dpkg --audit) ]]"
	result="moved:$expect"
fi
echo "RESULT $(basename "$img") $ID:$CODENAME:$ARCH $result old:${old// /,} $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
