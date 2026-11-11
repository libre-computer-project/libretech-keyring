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
#   S5  a board reading a stand-in deb.libre.computer (its only source) that serves the self-contained
#       libretech-keyring (build-deblibre.sh): a plain `apt-get upgrade` takes it, it moves the board,
#       and the migration replaces it with libre-computer-archive-keyring
#   S6  the control for S5: the transitional libretech-keyring (Depends on a package the board lacks)
#       served the same way is kept back by `apt-get upgrade` -- why deb.libre.computer gets S5's
# Exit 0 iff every check passes. The debs dir also holds the build-deblibre.sh package.

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
trans_keyring=$(find "$debs" -maxdepth 1 -name 'libretech-keyring_*_all.deb' ! -name '*~deb.libre.computer_*' -print -quit)
deblibre_keyring=$(find "$debs" -maxdepth 1 -name 'libretech-keyring_*~deb.libre.computer_all.deb' -print -quit)
[[ -n "$new_keyring" && -n "$trans_keyring" && -n "$deblibre_keyring" ]] || { echo "no keyring .debs in $debs" >&2; exit 1; }

# the migration unit installs these packages; a maintainer script that starts or restarts it waits on itself
# (seen on a board: systemctl start libre-computer-migrate.service inside its own apt-get, never returning)
for k in "$new_keyring" "$deblibre_keyring"; do
	check "S0: $(basename "$k")'s maintainer scripts never start the migration unit" bash -c "! dpkg-deb --ctrl-tarfile '$k' | tar -xO 2>/dev/null | grep -E '(deb-systemd-invoke|systemctl).*(start|restart).*libre-computer-migrate|_dh_action=(re)?start'"
done

# --- the local repository: stand-ins for the new names, signed by a throwaway key -------------------
G=$W/gnupg
install -d -m 700 "$G"
gpg --batch --quiet --homedir "$G" --pinentry-mode loopback --passphrase '' \
	--quick-gen-key 'test-deb-move <test@invalid>' ed25519 sign never 2>/dev/null
gpg --batch --homedir "$G" --export > "$W/test-key.gpg"
R=$W/repo
mkdir -p "$R/pool"
standin() { # NEW OLD [EXTRA-CONTROL-LINE]
	local d=$W/pkg-$1
	mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1"
	printf 'Package: %s\nVersion: 2026.11.10\nArchitecture: all\nMaintainer: t <t@invalid>\nBreaks: %s (<< 2026.11.10)\nReplaces: %s (<< 2026.11.10)\nProvides: %s (= 2026.11.10)\n%bDescription: stand-in for %s\n' \
		"$1" "$2" "$2" "$2" "${3:+$3\n}" "$1" > "$d/DEBIAN/control"
	echo "stand-in" > "$d/usr/share/doc/$1/README"
	dpkg-deb --root-owner-group -b "$d" "$R/pool/$1.deb" >/dev/null
}
standin libre-computer-gpio libretech-gpio
# a Recommends, as the real dtoverlay's i2c-tools: a rename installs nothing the board did not have
standin libre-computer-dtoverlay libretech-dtoverlay 'Recommends: lc-test-recommended'
mkdir -p "$W/pkg-rec/DEBIAN"
printf 'Package: lc-test-recommended\nVersion: 1\nArchitecture: all\nMaintainer: t <t@invalid>\nDescription: a recommended package\n' > "$W/pkg-rec/DEBIAN/control"
dpkg-deb --root-owner-group -b "$W/pkg-rec" "$R/pool/lc-test-recommended.deb" >/dev/null
standin alsa-ucm-conf-libre-computer libretech-alsa-ucm-conf
standin xserver-xorg-core-libre-computer xserver-xorg-video-libretech
standin linux-image-lc-lts-armhf linux-image-lc-lts-arm
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
	chroot "$mnt" env LC_PACKAGES_URI="${LCURI:-file:///srv/test-repo}" DEBIAN_FRONTEND=noninteractive \
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
check "S1: the migration is pending, its retry timer enabled" bash -c "test -e '$mnt/var/lib/libre-computer-archive-keyring/migrate-pending' && test -L '$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer'"
check "S1: no boot target waits on the migration (the service has no [Install])" bash -c "! grep -q '^\[Install\]' '$mnt/usr/lib/systemd/system/libre-computer-migrate.service' && test ! -e '$mnt/etc/systemd/system/multi-user.target.wants/libre-computer-migrate.service'"
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
check "S1: a new package's Recommends is not installed" bash -c "$(declare -f installed); mnt='$mnt'; ! installed lc-test-recommended"
check "S1: the key file is still in place (it changed package, not path)" test -s "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
check "S1: nothing pending, the timer disabled" bash -c "test ! -e '$mnt/var/lib/libre-computer-archive-keyring/migrate-pending' && test ! -e '$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer'"
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

# --- S5 / S6: a stand-in deb.libre.computer serving one libretech-keyring, through `apt-get upgrade` ------
# deblibre_repo DEB: the frozen repo's `linux` suite with that one package, signed by the throwaway key
deblibre_repo() {
	local D=$W/deb.libre.computer/repo
	rm -rf "$W/deb.libre.computer"
	mkdir -p "$D/pool" "$D/dists/linux/main/binary-arm64"
	cp "$1" "$D/pool/"
	(cd "$D" && apt-ftparchive packages pool > dists/linux/main/binary-arm64/Packages)
	apt-ftparchive -o APT::FTPArchive::Release::Codename=linux -o APT::FTPArchive::Release::Suite=linux \
		-o APT::FTPArchive::Release::Components=main -o APT::FTPArchive::Release::Architectures=arm64 \
		release "$D/dists/linux" > "$W/Release.dl"
	mv "$W/Release.dl" "$D/dists/linux/Release"
	gpg --batch --homedir "$G" --clearsign -o "$D/dists/linux/InRelease" "$D/dists/linux/Release"
}
# setup_deblibre: an old board whose only source is the stand-in deb.libre.computer (its URI keeps that name,
# which is what libre-computer-move looks for), trusting the throwaway key at the shipped path
setup_deblibre() {
	setup
	mkdir -p "$mnt/srv/deb.libre.computer"
	mount --bind "$W/deb.libre.computer" "$mnt/srv/deb.libre.computer"
	rm -f "$mnt/etc/apt/sources.list.d/debian.sources"
	echo 'deb [signed-by=/usr/share/keyrings/libre-computer-deb.gpg] file:///srv/deb.libre.computer/repo linux main' \
		> "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
	cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
	chroot "$mnt" apt-get -q update > "$W/update.log" 2>&1
}
upgrade() { # a plain `apt-get upgrade`, as an owner runs it
	chroot "$mnt" env LC_PACKAGES_URI=file:///srv/test-repo DEBIAN_FRONTEND=noninteractive \
		apt-get -y -q upgrade > "$W/upgrade.log" 2>&1
}
ver() { chroot "$mnt" dpkg-query -W -f '${Version}' "$1" 2>/dev/null; }

echo "== S5: deb.libre.computer serves the self-contained libretech-keyring; the owner runs apt-get upgrade"
deblibre_repo "$deblibre_keyring"
setup_deblibre
before=$(ver libretech-keyring)
upgrade
check "S5: apt-get upgrade takes it (libretech-keyring $before -> $(ver libretech-keyring))" bash -c "[[ '$(ver libretech-keyring)' == *~deb.libre.computer ]]"
check "S5: its install moved the board: packages.libre.computer's source in, deb.libre.computer's set aside" bash -c "grep -qx 'URIs: file:///srv/test-repo' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list'"
check "S5: the migration is pending" test -e "$mnt/var/lib/libre-computer-archive-keyring/migrate-pending"
# the package put the real key back; the stand-in repositories are signed by the throwaway one
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/migrate5.log" 2>&1
check "S5: the migration succeeds" grep -q 'done: the board reads packages.libre.computer' "$W/migrate5.log"
check "S5: libre-computer-archive-keyring in, libretech-keyring gone" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-archive-keyring && ! installed libretech-keyring"
for p in libre-computer-gpio libre-computer-dtoverlay; do
	check "S5: $p installed in place of its old name" bash -c "$(declare -f installed); mnt='$mnt'; installed $p"
done
check "S5: the key file stays (it changed owner, not path)" test -s "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
cleanup

echo "== S6 (control): the transitional libretech-keyring served the same way"
deblibre_repo "$trans_keyring"
setup_deblibre
before=$(ver libretech-keyring)
upgrade
check "S6: apt-get upgrade keeps it back (it would need a package the board lacks)" bash -c "grep -q 'kept back' '$W/upgrade.log' && [[ '$(ver libretech-keyring)' == '$before' ]]"
check "S6: so nothing moves" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources'"
cleanup

# --- the robustness cases (review 2026-11-11) ---------------------------------------------------------
S=/var/lib/libre-computer-archive-keyring
migrate() { # LOG: the throwaway key in place, then the migration
	cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
	in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/$1" 2>&1
}
dummy() { # NAME [CONTROL-LINE]: a local package built into the chroot's /tmp
	local d=$W/pkg-$1
	rm -rf "$d"; mkdir -p "$d/DEBIAN"
	printf 'Package: %s\nVersion: 1\nArchitecture: all\nMaintainer: t <t@invalid>\n%bDescription: test package\n' "$1" "${2:+$2\n}" > "$d/DEBIAN/control"
	dpkg-deb --root-owner-group -b "$d" "$mnt/tmp/$1.deb" >/dev/null
}

echo "== S7: deb.libre.computer in a .list file that also names another repository"
setup
mv "$mnt/etc/apt/sources.list.d/libre-computer-deb.list" "$mnt/etc/apt/sources.list.d/mixed.list"
echo 'deb file:///srv/test-repo trixie main' >> "$mnt/etc/apt/sources.list.d/mixed.list"
install_keyring
check "S7: the file stays, the other line active, ours commented out" bash -c "grep -qx 'deb file:///srv/test-repo trixie main' '$mnt/etc/apt/sources.list.d/mixed.list' && grep -q '^# moved to packages.libre.computer: deb .*deb.libre.computer' '$mnt/etc/apt/sources.list.d/mixed.list'"
check "S7: the original is kept" grep -q '^deb .*deb.libre.computer' "$mnt$S/moved-sources/mixed.list"
check "S7: the new source is in" test -s "$mnt/etc/apt/sources.list.d/libre-computer.sources"
cleanup

echo "== S8: deb822: a stanza of ours beside another in one file; a disabled one alone in another"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
# ours names its URI on a continuation line, as deb822 allows
printf '# a comment\nTypes: deb\nURIs: file:///srv/unused\n https://deb.libre.computer/repo\nSuites: linux\nComponents: main\nSigned-By: /usr/share/keyrings/libre-computer-deb.gpg\n\nTypes: deb\nURIs: file:///srv/test-repo\nSuites: trixie\nComponents: main\n' > "$mnt/etc/apt/sources.list.d/mixed.sources"
install_keyring
check "S8: our stanza is disabled in place, the other stanza untouched" bash -c "awk 'BEGIN{RS=\"\"} /deb\\.libre\\.computer/ && /Enabled: no/ {a=1} /srv\\/test-repo/ && !/Enabled:/ {b=1} END{exit !(a&&b)}' '$mnt/etc/apt/sources.list.d/mixed.sources'"
check "S8: apt reads the edited file" in_root apt-get -q -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/etc/apt/sources.list.d indextargets
check "S8: the board moved" test -e "$mnt$S/migrate-pending"
cleanup
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo\nSuites: linux\nComponents: main\nEnabled: no\n' > "$mnt/etc/apt/sources.list.d/off.sources"
cp "$mnt/etc/apt/sources.list.d/off.sources" "$W/s8.before"
install_keyring
check "S8: a disabled deb.libre.computer source: nothing moves, nothing pending" bash -c "cmp -s '$W/s8.before' '$mnt/etc/apt/sources.list.d/off.sources' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt$S/migrate-pending'"
cleanup

echo "== S9: packages.libre.computer does not answer from the board"
setup
LCURI=file:///srv/nowhere install_keyring
check "S9: the keyring still installs" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-archive-keyring"
check "S9: stays on deb.libre.computer, and says how to retry" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -q 'did not answer' '$W/dpkg.log' && grep -q dpkg-reconfigure '$W/dpkg.log'"
check "S9: nothing pending" test ! -e "$mnt$S/migrate-pending"
cleanup

echo "== S10: the migration removes nothing but old names"
setup
dummy user-app 'Depends: libretech-gpio (<< 2026.11.10)'
in_root dpkg -i /tmp/user-app.deb >/dev/null 2>&1
install_keyring
migrate s10.log
check "S10: a step that would remove user-app is refused" grep -q 'would also remove user-app' "$W/s10.log"
check "S10: user-app and libretech-gpio still installed, the migration still pending" bash -c "$(declare -f installed); mnt='$mnt'; installed user-app && installed libretech-gpio && test -e '$mnt$S/migrate-pending'"
in_root dpkg -r user-app >/dev/null 2>&1
dummy user-app2 'Depends: libretech-gpio'
in_root dpkg -i /tmp/user-app2.deb >/dev/null 2>&1
migrate s10b.log
check "S10: a package depending on an old name keeps it through its Provides" bash -c "$(declare -f installed); mnt='$mnt'; grep -q 'done: the board reads' '$W/s10b.log' && installed user-app2 && installed libre-computer-gpio && ! installed libretech-gpio"
cleanup

echo "== S11: an interrupted dpkg, a dead third-party source, an apt lock held at the start"
setup
install_keyring
dummy half-done
in_root dpkg --unpack /tmp/half-done.deb >/dev/null 2>&1
echo 'deb [trusted=yes] file:///srv/gone ./' > "$mnt/etc/apt/sources.list.d/gone.list"
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
if [[ -x $mnt/usr/bin/python3 ]]; then
	in_root python3 -c 'import fcntl,time; f=open("/var/lib/dpkg/lock-frontend","w"); fcntl.lockf(f,fcntl.LOCK_EX); time.sleep(45)' &
	holder=$!
	sleep 2
fi
t0=$SECONDS
in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/s11.log" 2>&1
[[ -z ${holder:-} ]] || wait "$holder"
check "S11: the migration succeeds" grep -q 'done: the board reads' "$W/s11.log"
grep -q 'done: the board reads' "$W/s11.log" ||
	{ echo "   -- the migration's last lines:"; tail -n 20 "$W/s11.log" | sed 's/^/   | /'; }
check "S11: the interrupted package was configured" bash -c "$(declare -f installed); mnt='$mnt'; installed half-done"
check "S11: the dead source was reported, not fatal" grep -q 'apt-get update reported errors' "$W/s11.log"
if [[ -n ${holder:-} ]]; then
	check "S11: it waited for the dpkg lock ($((SECONDS - t0)) s)" test $((SECONDS - t0)) -ge 30
fi
unset holder
cleanup

echo "== S12: armhf's renamed kernel meta-package: never installed by the migration"
setup
dummy linux-image-lc-lts-arm
in_root dpkg -i /tmp/linux-image-lc-lts-arm.deb >/dev/null 2>&1
install_keyring
migrate s12.log
check "S12: the migration succeeds without installing linux-image-lc-lts-armhf" bash -c "$(declare -f installed); mnt='$mnt'; grep -q 'done: the board reads' '$W/s12.log' && ! installed linux-image-lc-lts-armhf && installed linux-image-lc-lts-arm"
cleanup

echo "== S13: packages.libre.computer's lists missing (no network, a clock behind): retried, nothing changed"
setup
install_keyring
sed -i 's|^URIs: .*|URIs: file:///srv/nowhere|' "$mnt/etc/apt/sources.list.d/libre-computer.sources"
migrate s13.log
check "S13: it says why and leaves the migration pending" bash -c "grep -q 'package lists are not here' '$W/s13.log' && test -e '$mnt$S/migrate-pending'"
check "S13: the old names still installed" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-gpio"
cleanup

echo "test-deb-move: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
