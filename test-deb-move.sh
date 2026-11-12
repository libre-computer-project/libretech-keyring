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
	# (the service: a start from inside apt waits on the running unit for ever; the timer may be started, never
	# waiting on it)
	check "S0: $(basename "$k")'s maintainer scripts never start the migration service" bash -c "! dpkg-deb --ctrl-tarfile '$k' | tar -xO 2>/dev/null | grep -E '(deb-systemd-invoke|systemctl).*(start|restart).*libre-computer-migrate(\\.service)?([^.a-z]|\$)|_dh_action=(re)?start'"
	check "S0: $(basename "$k")'s maintainer scripts start nothing without --no-block" bash -c "! dpkg-deb --ctrl-tarfile '$k' | tar -xO 2>/dev/null | grep -E 'systemctl[^|;]* (start|restart) ' | grep -v -- '--no-block'"
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
# the key libre-computer-move verifies the repository with (LC_PACKAGES_KEY), inside the chroot at /srv/test-repo
cp "$W/test-key.gpg" "$R/test-key.gpg"
reindex() { # the repository's index and signature, after its pool changed
local s
for s in trixie; do
	mkdir -p "$R/dists/$s/main/binary-arm64" "$R/dists/$s/main/binary-all" "$R/dists/$s/non-free/binary-arm64"
	(cd "$R" && apt-ftparchive packages pool > "dists/$s/main/binary-arm64/Packages")
	: > "$R/dists/$s/non-free/binary-arm64/Packages"
	cp "$R/dists/$s/main/binary-arm64/Packages" "$R/dists/$s/main/binary-all/Packages"
	apt-ftparchive -o APT::FTPArchive::Release::Codename="$s" -o APT::FTPArchive::Release::Suite="$s" \
		-o APT::FTPArchive::Release::Components="main non-free" -o APT::FTPArchive::Release::Architectures="arm64 all" \
		release "$R/dists/$s" > "$W/Release"
	mv "$W/Release" "$R/dists/$s/Release"
	rm -f "$R/dists/$s/InRelease"
	gpg --batch --homedir "$G" --clearsign -o "$R/dists/$s/InRelease" "$R/dists/$s/Release"
done
}
reindex

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
	chroot "$mnt" env LC_PACKAGES_URI="${LCURI:-file:///srv/test-repo}" LC_PACKAGES_KEY="${LCKEY-/srv/test-repo/test-key.gpg}" DEBIAN_FRONTEND=noninteractive \
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
	chroot "$mnt" env LC_PACKAGES_URI=file:///srv/test-repo LC_PACKAGES_KEY=/srv/test-repo/test-key.gpg DEBIAN_FRONTEND=noninteractive \
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
grep -q 'done: the board reads packages.libre.computer' "$W/migrate5.log" ||
	{ echo "   -- the migration's last lines:"; tail -n 25 "$W/migrate5.log" | sed 's/^/   | /'; }
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
	# bounded: a migration that loops fails its checks instead of hanging the test
	timeout --kill-after=30 900 chroot "$mnt" /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/$1" 2>&1
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
echo 'deb file:///srv/other trixie main' >> "$mnt/etc/apt/sources.list.d/mixed.list"
install_keyring
check "S7: the file stays, the other line active, ours commented out" bash -c "grep -qx 'deb file:///srv/other trixie main' '$mnt/etc/apt/sources.list.d/mixed.list' && grep -q '^# moved to packages.libre.computer: deb .*deb.libre.computer' '$mnt/etc/apt/sources.list.d/mixed.list'"
check "S7: the original is kept" grep -q '^deb .*deb.libre.computer' "$mnt$S/moved-sources/mixed.list"
check "S7: the new source is in" test -s "$mnt/etc/apt/sources.list.d/libre-computer.sources"
cleanup

echo "== S8: deb822: a stanza of ours beside another in one file; a disabled one alone in another"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
# ours names its URI on a continuation line, as deb822 allows
printf '# a comment\nTypes: deb\nURIs: file:///srv/unused\n https://deb.libre.computer/repo\nSuites: linux\nComponents: main\nSigned-By: /usr/share/keyrings/libre-computer-deb.gpg\n\nTypes: deb\nURIs: file:///srv/other\nSuites: trixie\nComponents: main\n' > "$mnt/etc/apt/sources.list.d/mixed.sources"
install_keyring
# the stanza names a second repository too (on its first line): only deb.libre.computer leaves it
check "S8: deb.libre.computer taken out of its stanza (the other URI kept), the other stanza untouched" bash -c "awk 'BEGIN{RS=\"\"} /srv\\/unused/ && !/deb\\.libre\\.computer/ && !/Enabled:/ {a=1} /srv\\/other/ && !/Enabled:/ {b=1} END{exit !(a&&b)}' '$mnt/etc/apt/sources.list.d/mixed.sources'"
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
check "S9: stays on deb.libre.computer, and says how to retry" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -q 'is not usable' '$W/dpkg.log' && grep -q dpkg-reconfigure '$W/dpkg.log'"
check "S9: nothing pending" test ! -e "$mnt$S/migrate-pending"
cleanup

echo "== S9b: packages.libre.computer answers, but apt rejects its signature (another key)"
setup
LCKEY= install_keyring
check "S9b: stays on deb.libre.computer, nothing pending" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt$S/migrate-pending' && grep -q 'is not usable' '$W/dpkg.log'"
cleanup

echo "== S10: the migration removes nothing but old names (apt set to purge, too)"
setup
echo 'APT::Get::Purge "true";' > "$mnt/etc/apt/apt.conf.d/99purge"
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

echo "== S11: a package left part-done, a dead third-party source, an apt lock held at the start"
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
if [[ -n ${holder:-} ]]; then
	check "S11: it waited for the dpkg lock ($((SECONDS - t0)) s)" test $((SECONDS - t0)) -ge 30
fi
unset holder
# part-done dpkg work is never the migration's to finish: it waits, saying what to run
check "S11: half-done left as it is, the renames waiting, saying why" bash -c "$(declare -f installed); mnt='$mnt'; ! installed half-done && grep -q \"part-done: *half-done.*dpkg --configure -a\" '$W/s11.log' && test -e '$mnt$S/migrate-pending'"
# once the owner has finished it, the next run does the renames
in_root dpkg --configure -a > "$W/s11b.log" 2>&1
in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/s11.log" 2>&1
check "S11: then the migration succeeds" grep -q 'done: the board reads' "$W/s11.log"
grep -q 'done: the board reads' "$W/s11.log" ||
	{ echo "   -- the migration's last lines:"; tail -n 20 "$W/s11.log" | sed 's/^/   | /'; }
check "S11: the dead source was reported, not fatal" grep -q 'apt-get update reported errors' "$W/s11.log"
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

echo "== S14: a board that already reads packages.libre.computer elsewhere, under another key path"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb [signed-by=/usr/share/keyrings/own-copy.gpg] file:///srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/mine.list"
install_keyring
check "S14: no second source written, the owner's entry kept, deb.libre.computer's set aside" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -s '$mnt/etc/apt/sources.list.d/mine.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/migrate-pending'"
check "S14: apt reads the sources (no conflicting Signed-By)" in_root apt-get -q -o Dir::Etc::sourcelist=/dev/null indextargets
migrate s14.log
check "S14: the migration succeeds" grep -q 'done: the board reads' "$W/s14.log"
cleanup

echo "== S15: libre-computer.sources itself names deb.libre.computer beside another stanza"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo\nSuites: linux\nComponents: main\n\nTypes: deb\nURIs: file:///srv/other\nSuites: trixie\nComponents: main\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
install_keyring
f=$mnt/etc/apt/sources.list.d/libre-computer.sources
check "S15: the other stanza kept, ours disabled, the new one added" bash -c "awk 'BEGIN{RS=\"\"} /deb\\.libre\\.computer/ && /Enabled: no/ {a=1} /srv\\/other/ && !/Enabled:/ {b=1} /srv\\/test-repo/ && /Signed-By: \\/usr\\/share\\/keyrings\\/libre-computer-deb.gpg/ {c=1} END{exit !(a&&b&&c)}' '$f'"
check "S15: the original kept" grep -q 'deb.libre.computer' "$mnt$S/moved-sources/libre-computer.sources"
check "S15: apt reads it" in_root apt-get -q -o Dir::Etc::sourcelist=/dev/null indextargets
cleanup

echo "== S16: a deb822 stanza disabled as Enabled: false (apt's boolean)"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo\nSuites: linux\nComponents: main\nEnabled: false\n' > "$mnt/etc/apt/sources.list.d/off.sources"
install_keyring
check "S16: nothing moves, nothing pending" bash -c "test -s '$mnt/etc/apt/sources.list.d/off.sources' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt$S/migrate-pending'"
cleanup

echo "== S17: ours beside a disabled third-party stanza: the file stays, the disabled stanza with it"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo\nSuites: linux\nComponents: main\n\nTypes: deb\nURIs: file:///srv/other\nSuites: trixie\nComponents: main\nEnabled: no\n' > "$mnt/etc/apt/sources.list.d/two.sources"
install_keyring
check "S17: the file stays in place, the third-party stanza in it, ours disabled" bash -c "grep -q 'srv/other' '$mnt/etc/apt/sources.list.d/two.sources' && awk 'BEGIN{RS=\"\"} /deb\\.libre\\.computer/ && /Enabled: no/ {a=1} END{exit !a}' '$mnt/etc/apt/sources.list.d/two.sources'"
check "S17: the board moved" test -s "$mnt/etc/apt/sources.list.d/libre-computer.sources"
cleanup

echo "== S18: a line of white space inside our stanza (apt 3 reads it as one stanza), beside another"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo\nSuites: linux\n \nComponents: main\n\nTypes: deb\nURIs: file:///srv/other\nSuites: trixie\nComponents: main\n' > "$mnt/etc/apt/sources.list.d/ws.sources"
install_keyring
check "S18: the board moved" test -e "$mnt$S/migrate-pending"
check "S18: apt reads every source after the edit" in_root apt-get -q -o Dir::Etc::sourcelist=/dev/null indextargets
check "S18: our stanza disabled, the other kept" bash -c "awk 'BEGIN{RS=\"\"} /deb\\.libre\\.computer/ && /Enabled: no/ {a=1} /srv\\/other/ && !/Enabled:/ {b=1} END{exit !(a&&b)}' '$mnt/etc/apt/sources.list.d/ws.sources'"
cleanup

echo "== S19: one stanza naming deb.libre.computer and another repository"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo file:///srv/other\nSuites: trixie\nComponents: main\n' > "$mnt/etc/apt/sources.list.d/both.sources"
install_keyring
check "S19: the other repository stays in the stanza, deb.libre.computer leaves it" bash -c "grep -q 'srv/other' '$mnt/etc/apt/sources.list.d/both.sources' && ! grep -v '^#' '$mnt/etc/apt/sources.list.d/both.sources' | grep -q 'deb.libre.computer' && ! grep -q 'Enabled: no' '$mnt/etc/apt/sources.list.d/both.sources'"
check "S19: the new source is written, apt reads everything" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer.sources' && chroot '$mnt' apt-get -q -o Dir::Etc::sourcelist=/dev/null indextargets"
cleanup

echo "== S20: a deb822 stanza disabled as Enabled: without"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo\nSuites: linux\nComponents: main\nEnabled: without\n' > "$mnt/etc/apt/sources.list.d/off.sources"
install_keyring
check "S20: nothing moves, nothing pending" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt$S/migrate-pending'"
cleanup

echo "== S21: one rename blocked (its old package held): the others still go through"
setup
# a package no other old name depends on (holding libretech-dtoverlay would also pin the libretech-gpio it needs)
in_root apt-mark hold libretech-alsa-ucm-conf >/dev/null 2>&1
install_keyring
migrate s21.log
check "S21: the others renamed (gpio, dtoverlay)" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-gpio && ! installed libretech-gpio && installed libre-computer-dtoverlay && ! installed libretech-dtoverlay"
check "S21: the held libretech-alsa-ucm-conf stays, the migration pending (retried)" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-alsa-ucm-conf && ! installed alsa-ucm-conf-libre-computer && test -e '$mnt$S/migrate-pending'"
grep -q 'still installed under an old name: libretech-alsa-ucm-conf' "$W/s21.log" ||
	{ echo "   -- the migration's last lines:"; tail -n 20 "$W/s21.log" | sed 's/^/   | /'; }
cleanup

echo "== S22: a new name apt marked automatic (pulled in by its transitional old name): autoremove keeps it"
setup
install_keyring
in_root apt-mark auto libre-computer-archive-keyring >/dev/null 2>&1
migrate s22.log
check "S22: the migration succeeds" grep -q 'done: the board reads' "$W/s22.log"
check "S22: autoremove would not remove libre-computer-archive-keyring (it took libretech-keyring's manual mark)" bash -c "! chroot '$mnt' apt-get -s autoremove 2>/dev/null | grep -q '^Remv libre-computer-archive-keyring'"
cleanup

echo "== S23: a CRLF .sources file: another repository's stanza, then ours"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
printf 'Types: deb\r\nURIs: file:///srv/other\r\nSuites: trixie\r\nComponents: main\r\n\r\nTypes: deb\r\nURIs: https://deb.libre.computer/repo\r\nSuites: linux\r\nComponents: main\r\n' > "$mnt/etc/apt/sources.list.d/crlf.sources"
install_keyring
check "S23: the file stays, the other stanza in it, ours disabled" bash -c "grep -q 'srv/other' '$mnt/etc/apt/sources.list.d/crlf.sources' && awk 'BEGIN{RS=\"\"} /deb\\.libre\\.computer/ && /Enabled: no/ {a=1} END{exit !a}' '$mnt/etc/apt/sources.list.d/crlf.sources'"
check "S23: apt reads every source" in_root apt-get -q -o Dir::Etc::sourcelist=/dev/null indextargets
cleanup

echo "== S24: one stanza naming deb.libre.computer and packages.libre.computer for the board's suite, its own key"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo file:///srv/test-repo\nSuites: trixie\nComponents: main\nSigned-By: /usr/share/keyrings/own-copy.gpg\n' > "$mnt/etc/apt/sources.list.d/both.sources"
install_keyring
check "S24: no second source (it would conflict on Signed-By), the stanza keeps packages.libre.computer" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -q 'srv/test-repo' '$mnt/etc/apt/sources.list.d/both.sources' && test -e '$mnt$S/migrate-pending'"
check "S24: apt reads every source" in_root apt-get -q -o Dir::Etc::sourcelist=/dev/null indextargets
cleanup

echo "== S25: a suite with no transitional libretech-keyring, apt set to purge: the migration's state survives"
# the repository without the transitional libretech-keyring: apt removes (purges) the self-contained one first
deblibre_repo "$deblibre_keyring"
setup_deblibre
echo 'APT::Get::Purge "true";' > "$mnt/etc/apt/apt.conf.d/99purge"
rm -f "$R/pool/${trans_keyring##*/}"
reindex
upgrade
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
in_root apt-mark hold libretech-alsa-ucm-conf >/dev/null 2>&1
in_root /usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/s25.log" 2>&1
check "S25: libretech-keyring purged, libre-computer-archive-keyring in" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-archive-keyring && ! chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' libretech-keyring 2>/dev/null | grep -qxE 'installed|config-files'"
check "S25: the pending mark and the moved sources survive (a rename is left: retried)" bash -c "test -e '$mnt$S/migrate-pending' && test -s '$mnt$S/moved-sources/libre-computer-deb.list'"
check "S25: and the timer that retries it stays enabled" test -L "$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer"
cleanup
cp "$trans_keyring" "$R/pool/"
reindex

echo "== S26: a file apt does not read (a name with a space) names packages.libre.computer: it does not count"
setup
echo 'deb [signed-by=/usr/share/keyrings/libre-computer-deb.gpg] file:///srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/not read.list"
install_keyring
check "S26: the new source is written (the unread file is ignored), the board moved" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -e '$mnt$S/migrate-pending' && test -s '$mnt/etc/apt/sources.list.d/not read.list'"
cleanup

echo "== S27: a .list with a commented-out deb.libre.computer line beside the active one: the file stays"
setup
echo '# deb https://deb.libre.computer/repo linux-testing main' >> "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
install_keyring
check "S27: the file stays in place, both lines commented" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && ! grep -qE '^[[:space:]]*deb ' '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && grep -q 'linux-testing' '$mnt/etc/apt/sources.list.d/libre-computer-deb.list'"
cleanup

echo "== S28: a deb-src-only packages.libre.computer entry does not count as the board's new source"
setup
echo 'deb-src [signed-by=/usr/share/keyrings/libre-computer-deb.gpg] file:///srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/src.list"
install_keyring
check "S28: the binary source is written" bash -c "grep -qx 'Types: deb' '$mnt/etc/apt/sources.list.d/libre-computer.sources'"
cleanup

echo "== S12b: the owner's upgrade later brings linux-image-lc-lts-armhf: the next run renames the kernel meta"
setup
dummy linux-image-lc-lts-arm
in_root dpkg -i /tmp/linux-image-lc-lts-arm.deb >/dev/null 2>&1
install_keyring
migrate s12b.log
check "S12b: the userspace renames finish, the kernel waits (kernel-pending)" bash -c "grep -q 'done: the board reads' '$W/s12b.log' && test ! -e '$mnt$S/migrate-pending' && test -e '$mnt$S/kernel-pending'"
dummy linux-image-lc-lts-armhf
in_root dpkg -i /tmp/linux-image-lc-lts-armhf.deb >/dev/null 2>&1
in_root apt-mark auto linux-image-lc-lts-armhf >/dev/null 2>&1
migrate s12b2.log
check "S12b: the next run removes linux-image-lc-lts-arm, the new name manual like the old, nothing pending" bash -c "$(declare -f installed); mnt='$mnt'; ! installed linux-image-lc-lts-arm && installed linux-image-lc-lts-armhf && chroot '$mnt' apt-mark showmanual | grep -qx linux-image-lc-lts-armhf && test ! -e '$mnt$S/kernel-pending' && test ! -e '$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer'"
cleanup

echo "== S29: the board's own packages.libre.computer entry written another way (file:/ for file:///)"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb [signed-by=/usr/share/keyrings/own-copy.gpg] file:/srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/mine.list"
install_keyring
check "S29: it counts as the new source: none written, apt reads everything, the board moved" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && chroot '$mnt' apt-get -q indextargets >/dev/null && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S30: a deb-src-only entry for packages.libre.computer under another key: apt would refuse both, so nothing moves"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb-src [signed-by=/usr/share/keyrings/own-copy.gpg] file:///srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/src.list"
install_keyring
if chroot "$mnt" apt-get -q indextargets >/dev/null 2>&1 && grep -q 'apt cannot read the sources' "$W/dpkg.log"; then
	check "S30: the new source undone, deb.libre.computer kept, nothing pending, apt reads its sources" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt$S/migrate-pending'"
else
	# this apt accepts the two side by side: then the move must leave apt reading its sources
	check "S30: apt reads its sources after the move" in_root apt-get -q indextargets
fi
cleanup

echo "== S31: deb.libre.computer in a file whose name has a colon (apt reads it)"
setup
mv "$mnt/etc/apt/sources.list.d/libre-computer-deb.list" "$mnt/etc/apt/sources.list.d/lc:old.list"
install_keyring
check "S31: the file is set aside, the board moved" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/lc:old.list' && test -e '$mnt$S/migrate-pending' && test -s '$mnt/etc/apt/sources.list.d/libre-computer.sources'"
cleanup

echo "== S9c: packages.libre.computer not usable at install time: the timer tries the move again later"
setup
LCURI=file:///srv/nowhere install_keyring
check "S9c: stays for now, the retry armed (move-pending, timer enabled)" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/move-pending' && test -L '$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer'"
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
chroot "$mnt" env LC_PACKAGES_URI=file:///srv/test-repo LC_PACKAGES_KEY=/srv/test-repo/test-key.gpg \
	/usr/lib/libre-computer-archive-keyring/libre-computer-migrate > "$W/s9c.log" 2>&1
check "S9c: once it answers, the timer's run moves the board and migrates it" bash -c "$(declare -f installed); mnt='$mnt'; grep -q 'done: the board reads' '$W/s9c.log' && test ! -e '$mnt$S/move-pending' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && installed libre-computer-gpio"
cleanup

echo "== S32: a .list line for packages.libre.computer whose trailing comment names deb.libre.computer"
setup
# its own key copy: the shipped path holds the real key, and the local repository is signed by the throwaway one
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb [signed-by=/usr/share/keyrings/own-copy.gpg] file:///srv/test-repo trixie main # was deb.libre.computer' > "$mnt/etc/apt/sources.list.d/mine.list"
install_keyring
check "S32: that line is not ours: it stays, active, and the board moves" bash -c "grep -qE '^deb .*srv/test-repo trixie main' '$mnt/etc/apt/sources.list.d/mine.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/migrate-pending' && chroot '$mnt' apt-get -q indextargets >/dev/null"
cleanup

echo "== S33: a symlinked .list holding ours and another repository: edited through the link, still a link"
setup
mkdir -p "$mnt/etc/apt/lists-real"
mv "$mnt/etc/apt/sources.list.d/libre-computer-deb.list" "$mnt/etc/apt/lists-real/lc.list"
echo 'deb file:///srv/other trixie main' >> "$mnt/etc/apt/lists-real/lc.list"
ln -s /etc/apt/lists-real/lc.list "$mnt/etc/apt/sources.list.d/lc.list"
install_keyring
check "S33: still a symlink; its target has ours commented out, the other line active" bash -c "test -L '$mnt/etc/apt/sources.list.d/lc.list' && grep -q '^# moved to packages.libre.computer: deb .*deb.libre.computer' '$mnt/etc/apt/lists-real/lc.list' && grep -qx 'deb file:///srv/other trixie main' '$mnt/etc/apt/lists-real/lc.list'"
cleanup

echo "== S34: a blocked userspace rename does not hold back the kernel step"
setup
dummy linux-image-lc-lts-arm
in_root dpkg -i /tmp/linux-image-lc-lts-arm.deb >/dev/null 2>&1
dummy linux-image-lc-lts-armhf
in_root dpkg -i /tmp/linux-image-lc-lts-armhf.deb >/dev/null 2>&1
in_root apt-mark hold libretech-alsa-ucm-conf >/dev/null 2>&1
install_keyring
migrate s34.log
check "S34: the kernel's old name goes while the held rename waits" bash -c "$(declare -f installed); mnt='$mnt'; ! installed linux-image-lc-lts-arm && installed linux-image-lc-lts-armhf && installed libretech-alsa-ucm-conf && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S35: libre-computer.sources is a symlink (naming deb.libre.computer): written through the link"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
mkdir -p "$mnt/etc/apt/lists-real"
printf 'Types: deb\nURIs: https://deb.libre.computer/repo\nSuites: linux\nComponents: main\n' > "$mnt/etc/apt/lists-real/lc.sources"
ln -s /etc/apt/lists-real/lc.sources "$mnt/etc/apt/sources.list.d/libre-computer.sources"
install_keyring
check "S35: still a symlink, its target the new source" bash -c "test -L '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -qx 'URIs: file:///srv/test-repo' '$mnt/etc/apt/lists-real/lc.sources' && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S36: the board's own packages.libre.computer entry names a key it lacks: nothing moves, retried"
setup
echo 'deb [signed-by=/usr/share/keyrings/gone.gpg] file:///srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/mine.list"
install_keyring
check "S36: stays on deb.libre.computer, the move retried by the timer" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/move-pending' && test ! -e '$mnt$S/migrate-pending' && grep -q 'own entry for packages.libre.computer is not usable' '$W/dpkg.log'"
cleanup

echo "== S38: the board's own entry works while the shipped stanza would not (here: its key does not sign the repo)"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb [signed-by=/usr/share/keyrings/own-copy.gpg] file:///srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/mine.list"
LCKEY= install_keyring
check "S38: the board moves on its own entry: no source written, deb.libre.computer's set aside, migration pending" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/migrate-pending' && test ! -e '$mnt$S/move-pending'"
cleanup

echo "== S39: apt's and dpkg's messages are read untranslated (the service inherits the system locale)"
for f in libre-computer-move libre-computer-migrate; do
	check "S39: $f exports LC_ALL=C" bash -c "dpkg-deb --fsys-tarfile '$new_keyring' | tar -xO ./usr/lib/libre-computer-archive-keyring/$f | grep -qx 'export LC_ALL=C'"
done

echo "== S40: a new name the owner already installed by hand stays manual, though its old name was automatic"
setup
install_keyring
in_root apt-mark manual libre-computer-archive-keyring >/dev/null 2>&1
in_root apt-mark auto libretech-keyring >/dev/null 2>&1
migrate s40.log
check "S40: libre-computer-archive-keyring still manual after the rename" bash -c "grep -q 'done: the board reads' '$W/s40.log' && chroot '$mnt' apt-mark showmanual | grep -qx libre-computer-archive-keyring"
cleanup

echo "== S41: the board's own packages.libre.computer entry carries only non-free: it does not count as a working source"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb [signed-by=/usr/share/keyrings/own-copy.gpg] file:///srv/test-repo trixie non-free' > "$mnt/etc/apt/sources.list.d/mine.list"
install_keyring
check "S41: stays on deb.libre.computer, the move retried" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/move-pending' && test ! -e '$mnt$S/migrate-pending'"
cleanup

echo "== S42: the board's own packages.libre.computer entry through a caching proxy path counts as its new source"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
# a proxy's shape: one leading path component, then the repository's own path
mkdir -p "$mnt/cache/srv"
ln -s /srv/test-repo "$mnt/cache/srv/test-repo"
echo 'deb [signed-by=/usr/share/keyrings/own-copy.gpg] file:///cache/srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/mine.list"
install_keyring
check "S42: no shipped source added beside it, the board moved" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -e '$mnt$S/migrate-pending' && test ! -e '$mnt$S/move-pending'"
cleanup

echo "== S43: a board whose apt config sets AutomaticRemove, with a package nothing needs: the renames still go in"
setup
install_keyring
# set after the keyring's install: the test's own apt run there would autoremove the orphan itself
echo 'APT::Get::AutomaticRemove "true";' > "$mnt/etc/apt/apt.conf.d/99autoremove"
dummy orphan-pkg
in_root dpkg -i /tmp/orphan-pkg.deb >/dev/null 2>&1
in_root apt-mark auto orphan-pkg >/dev/null 2>&1
migrate s43.log
check "S43: the migration succeeds and leaves the orphan alone" bash -c "$(declare -f installed); mnt='$mnt'; grep -q 'done: the board reads' '$W/s43.log' && installed libre-computer-gpio && installed orphan-pkg"
grep -q 'done: the board reads' "$W/s43.log" || { echo "   -- the migration's last lines:"; tail -n 20 "$W/s43.log" | sed 's/^/   | /'; }
cleanup

echo "== S44: libre-computer.sources is a symlink to a device (as to /dev/null, switched off), deb.libre.computer enabled elsewhere"
setup
# a device of the chroot's own (its /tmp is a private tmpfs), not the host's /dev/null the chroot binds
mknod "$mnt/tmp/null-dev" c 1 3
ln -s /tmp/null-dev "$mnt/etc/apt/sources.list.d/libre-computer.sources"
install_keyring
check "S44: the device stays a device; the link replaced by the new source; the board moved" bash -c "test -c '$mnt/tmp/null-dev' && test -f '$mnt/etc/apt/sources.list.d/libre-computer.sources' && ! test -L '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -e '$mnt$S/migrate-pending'"
check "S44: the link itself kept in moved-sources" test -L "$mnt$S/moved-sources/libre-computer.sources"
cleanup

echo "== S45: a deb.libre.computer line whose options hold a # (apt keeps it): still ours"
setup
echo 'deb [signed-by=/usr/share/keyrings/lc#copy.gpg] https://deb.libre.computer/repo linux main' > "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
install_keyring
check "S45: the file is set aside and the board moved" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S46: libre-computer.sources is a directory: nothing moves into it, the board stays"
setup
mkdir -p "$mnt/etc/apt/sources.list.d/libre-computer.sources"
install_keyring
check "S46: stays on deb.libre.computer, says why, nothing written into the directory" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -z \"\$(ls -A '$mnt/etc/apt/sources.list.d/libre-computer.sources')\" && test ! -e '$mnt$S/migrate-pending' && grep -q 'is a directory' '$W/dpkg.log'"
cleanup

echo "== S47: the owner removes the self-contained libretech-keyring by hand mid-migration: its timer goes with it"
deblibre_repo "$deblibre_keyring"
setup_deblibre
upgrade
in_root env DEBIAN_FRONTEND=noninteractive dpkg -r libretech-keyring > "$W/s47.log" 2>&1
check "S47: the timer's link is gone (no rename under way, nothing ships the unit)" bash -c "test ! -e '$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer' && test ! -e '$mnt/usr/lib/systemd/system/libre-computer-migrate.timer'"
cleanup

echo "== S48: one new name apt cannot install (no candidate): the others go in, the migration ends and retries"
setup
mkdir -p "$mnt/etc/apt/preferences.d"
printf 'Package: libre-computer-gpio\nPin: release *\nPin-Priority: -1\n' > "$mnt/etc/apt/preferences.d/no-gpio"
install_keyring
migrate s48.log
s48rc=$?
check "S48: the migration ended on its own (not the test's time limit)" test "$s48rc" -lt 124
check "S48: the others renamed, gpio kept under its old name, the migration pending" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-dtoverlay && ! installed libretech-dtoverlay && installed libretech-gpio && ! installed libre-computer-gpio && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S49: a move stopped between writing the new source and its readability check: the next run checks"
check_record() { # KIND: the record step 1 leaves before the new file goes in (nothing was there before it)
	mkdir -p "$mnt$S/sources-check"
	: > "$mnt$S/sources-check/before.log"
	: > "$mnt$S/sources-check/backup"
	printf '%s' /etc/apt/sources.list.d/libre-computer.sources > "$mnt$S/sources-check/path"
	echo "$1" > "$mnt$S/sources-check/kind"
	touch "$mnt$S/move-pending"
}
setup
check_record none
# a new file apt refuses (no Suites), as the interrupted run left it
printf 'Types: deb\nURIs: file:///srv/test-repo\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
# the move run as the timer's retry runs it (apt-get install would refuse these sources)
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
in_root sh /tmp/lc-move > "$W/s49.log" 2>&1
check "S49: the unreadable file undone, deb.libre.computer kept, the record gone, the retry armed" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt$S/sources-check' && test -e '$mnt$S/move-pending' && grep -q 'apt cannot read the sources' '$W/s49.log' && chroot '$mnt' apt-get -q indextargets >/dev/null"
cleanup
setup
check_record none
install_keyring
check "S49: a readable state passes the check: the record gone, the board moved" bash -c "test ! -e '$mnt$S/sources-check' && test -s '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -e '$mnt$S/migrate-pending' && test ! -e '$mnt$S/move-pending'"
cleanup

echo "== S50: old names left beside their new ones, one depending on another and one held: the free ones go in passes"
setup
install_keyring
migrate s50a.log
# transitional old names, as an owner's upgrade could leave them: dtoverlay's depends on gpio's
dummy libretech-gpio "Depends: libre-computer-gpio"
dummy libretech-dtoverlay "Depends: libretech-gpio, libre-computer-dtoverlay"
dummy libretech-alsa-ucm-conf "Depends: alsa-ucm-conf-libre-computer"
# at the new names' version: their Breaks (<< it) do not cover these
for p in libretech-gpio libretech-dtoverlay libretech-alsa-ucm-conf; do
	sed -i 's/^Version: 1$/Version: 2026.11.10/' "$W/pkg-$p/DEBIAN/control"
	dpkg-deb --root-owner-group -b "$W/pkg-$p" "$mnt/tmp/$p.deb" >/dev/null
done
in_root dpkg -i /tmp/libretech-gpio.deb /tmp/libretech-dtoverlay.deb /tmp/libretech-alsa-ucm-conf.deb > "$W/s50b.log" 2>&1
in_root apt-mark hold libretech-alsa-ucm-conf >/dev/null 2>&1
touch "$mnt$S/migrate-pending"
migrate s50.log
s50rc=$?
check "S50: the precondition: the three old names were in beside their new ones" grep -q 'removing libretech-gpio libretech-dtoverlay libretech-alsa-ucm-conf' "$W/s50.log"
check "S50: ended on its own; gpio and dtoverlay gone, the held one kept, the migration pending" bash -c "$(declare -f installed); mnt='$mnt'; test $s50rc -lt 124 && ! installed libretech-gpio && ! installed libretech-dtoverlay && installed libretech-alsa-ucm-conf && installed libre-computer-gpio && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S51: apt would refuse the sources with the new stanza, libre-computer.sources already there: nothing written, no copy kept"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb-src [signed-by=/usr/share/keyrings/own-copy.gpg] file:///srv/test-repo trixie main' > "$mnt/etc/apt/sources.list.d/src.list"
printf 'Types: deb\nURIs: file:///srv/other\nSuites: trixie\nComponents: main\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
cp "$mnt/etc/apt/sources.list.d/libre-computer.sources" "$W/s51.before"
install_keyring
if grep -q 'apt cannot read the sources' "$W/dpkg.log"; then
	check "S51: the file unchanged, no copy of it kept, deb.libre.computer kept, the retry armed, apt reads its sources" bash -c "cmp -s '$W/s51.before' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -z \"\$(ls -A '$mnt$S/moved-sources' 2>/dev/null)\" && test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/move-pending' && chroot '$mnt' apt-get -q indextargets >/dev/null"
else
	# this apt accepts the two side by side: then the move must leave apt reading its sources
	check "S51: apt reads its sources after the move" in_root apt-get -q indextargets
fi
cleanup

echo "== S52: a renaming mark left by a killed migration does not keep the timer; one of a live migration does"
for s52 in stale reused live; do
	deblibre_repo "$deblibre_keyring"
	setup_deblibre
	upgrade
	# the mark as the migration writes it: boot id, pid, the pid's start time (stat field 22)
	pid=$$ start=$(awk '{print $22}' /proc/$$/stat)
	case $s52 in
		stale) pid=999999; while kill -0 "$pid" 2>/dev/null; do pid=$((pid + 1)); done ;;
		reused) start=$((start + 1)) ;;   # a live pid, but not the process that wrote the mark
	esac
	echo "$(cat /proc/sys/kernel/random/boot_id) $pid $start" > "$mnt$S/renaming"
	in_root env DEBIAN_FRONTEND=noninteractive dpkg -r libretech-keyring > "$W/s52-$s52.log" 2>&1
	if [[ $s52 == live ]]; then
		check "S52: live mark: the timer's link stays for the rename" test -L "$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer"
	else
		check "S52: $s52 mark: the timer's link goes with the package" test ! -e "$mnt/etc/systemd/system/timers.target.wants/libre-computer-migrate.timer"
	fi
	cleanup
done

echo "== S53: a migration stopped between a rename's install and its mark: the next run gives the new name the old one's"
setup
install_keyring
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
in_root apt-mark auto libretech-gpio >/dev/null 2>&1
# what the stopped run left: its record, then apt's install (the old name gone, the new one manual)
echo auto > "$mnt$S/pending-libre-computer-gpio"
in_root apt-get -q update > "$W/s53a.log" 2>&1
in_root env DEBIAN_FRONTEND=noninteractive apt-get -q -y --no-install-recommends install libre-computer-gpio >> "$W/s53a.log" 2>&1
check "S53: the precondition: libretech-gpio gone, libre-computer-gpio in and manual" bash -c "$(declare -f installed); mnt='$mnt'; ! installed libretech-gpio && installed libre-computer-gpio && chroot '$mnt' apt-mark showmanual | grep -qx libre-computer-gpio"
migrate s53.log
check "S53: libre-computer-gpio automatic, as libretech-gpio was; the record gone" bash -c "chroot '$mnt' apt-mark showauto | grep -qx libre-computer-gpio && test ! -e '$mnt$S/pending-libre-computer-gpio'"
cleanup

echo "== S54: the guard inside apt's run refuses a removal not allowed (install and removal runs), and lets an allowed one through"
setup
install_keyring
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
in_root apt-get -q update > "$W/s54.log" 2>&1
# (its own name: G is the throwaway key's gpg home, which later repositories are signed with)
RG=/usr/lib/libre-computer-archive-keyring/libre-computer-rename-guard
guarded() { # ALLOW APT-ARGS...
	local allow=$1; shift
	chroot "$mnt" env LC_RENAME_ALLOW="$allow" DEBIAN_FRONTEND=noninteractive apt-get -q -y --no-install-recommends \
		-o "DPkg::Pre-Install-Pkgs::=$RG" -o "DPkg::Tools::Options::$RG::Version=2" "$@" >> "$W/s54.log" 2>&1
}
# (installing libre-computer-gpio takes libretech-gpio and libretech-dtoverlay, which depends on it)
guarded " " install libre-computer-gpio
check "S54: an install that removes libretech-gpio, not allowed: refused, nothing changed" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-gpio && ! installed libre-computer-gpio && grep -q 'rename-guard: this run would also remove .*libretech-gpio' '$W/s54.log'"
guarded " libretech-gpio " install libre-computer-gpio
check "S54: allowed libretech-gpio alone: refused for libretech-dtoverlay" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-dtoverlay && ! installed libre-computer-gpio && grep -q 'rename-guard: this run would also remove libretech-dtoverlay;' '$W/s54.log'"
guarded " libretech-gpio libretech-dtoverlay " install libre-computer-gpio
check "S54: the same install with both allowed: done" bash -c "$(declare -f installed); mnt='$mnt'; ! installed libretech-gpio && installed libre-computer-gpio"
guarded " " remove libretech-alsa-ucm-conf
check "S54: a removal run, not allowed: refused" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-alsa-ucm-conf"
guarded " libretech-alsa-ucm-conf " remove libretech-alsa-ucm-conf
check "S54: the same removal allowed: done" bash -c "$(declare -f installed); mnt='$mnt'; ! installed libretech-alsa-ucm-conf"
cleanup

echo "== S55: a package the owner left half-configured is not the migration's to configure"
setup
install_keyring
d=$W/pkg-owner-broken
rm -rf "$d"; mkdir -p "$d/DEBIAN"
printf 'Package: owner-broken\nVersion: 1\nArchitecture: all\nMaintainer: t <t@invalid>\nDescription: a postinst that fails\n' > "$d/DEBIAN/control"
printf '#!/bin/sh\necho run >> /var/tmp/owner-broken.count\nexit 1\n' > "$d/DEBIAN/postinst"
chmod 755 "$d/DEBIAN/postinst"
dpkg-deb --root-owner-group -b "$d" "$mnt/tmp/owner-broken.deb" >/dev/null
in_root dpkg -i /tmp/owner-broken.deb > "$W/s55a.log" 2>&1
check "S55: the precondition: owner-broken half-configured, its postinst run once" bash -c "chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' owner-broken | grep -qx half-configured && [ \"\$(wc -l < '$mnt/var/tmp/owner-broken.count')\" = 1 ]"
migrate s55.log
check "S55: the migration did not configure it (its postinst not run again); the renames wait, saying why" bash -c "[ \"\$(wc -l < '$mnt/var/tmp/owner-broken.count')\" = 1 ] && grep -q 'part-done: *owner-broken' '$W/s55.log' && test -e '$mnt$S/migrate-pending'"
migrate s55b.log
check "S55: a second run neither" bash -c "[ \"\$(wc -l < '$mnt/var/tmp/owner-broken.count')\" = 1 ]"
cleanup

echo "== S56: a rename a power loss cut short in dpkg (the old name removed, the new one unpacked): waits for dpkg's owner, then resumes"
setup
install_keyring
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
in_root apt-mark auto libretech-gpio >/dev/null 2>&1
in_root apt-get -q update > "$W/s56a.log" 2>&1
(cd "$mnt/tmp" && chroot "$mnt" sh -c 'cd /tmp && apt-get -q download libre-computer-gpio') >> "$W/s56a.log" 2>&1
# what the cut-short run left: its record, the old names removed, the new one unpacked and never configured
echo auto > "$mnt$S/pending-libre-computer-gpio"
in_root env DEBIAN_FRONTEND=noninteractive dpkg -r libretech-dtoverlay libretech-gpio >> "$W/s56a.log" 2>&1
in_root sh -c 'dpkg --unpack /tmp/libre-computer-gpio_*.deb' >> "$W/s56a.log" 2>&1
check "S56: the precondition: libre-computer-gpio unpacked, libretech-gpio gone" bash -c "chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' libre-computer-gpio | grep -qx unpacked"
migrate s56.log
check "S56: not configured by the migration, which waits saying what to run" bash -c "chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' libre-computer-gpio | grep -qx unpacked && grep -q 'dpkg --configure -a' '$W/s56.log' && test -e '$mnt$S/migrate-pending'"
in_root dpkg --configure -a > "$W/s56b.log" 2>&1
migrate s56c.log
check "S56: once dpkg is whole, the rename finishes: libre-computer-gpio in and automatic, the record gone" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-gpio && chroot '$mnt' apt-mark showauto | grep -qx libre-computer-gpio && test ! -e '$mnt$S/pending-libre-computer-gpio'"
cleanup

echo "== S57: the board's own entry written with a doubled slash in its path is its own entry"
setup
cp "$W/test-key.gpg" "$mnt/usr/share/keyrings/own-copy.gpg"
echo 'deb [signed-by=/usr/share/keyrings/own-copy.gpg] file:///srv//test-repo trixie main' > "$mnt/etc/apt/sources.list.d/mine.list"
LCKEY= install_keyring
check "S57: the board moves on its own entry: no second source written" bash -c "test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S58: the migration's wait for other apt and dpkg runs (apt-get check) really waits on dpkg's lock"
setup
# a lock on the chroot's lock-frontend, as a running dpkg or apt holds it (fcntl, from outside: the same file)
python3 -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(20)' "$mnt/var/lib/dpkg/lock-frontend" &
lockpid=$!
sleep 2
in_root apt-get -q check > "$W/s58.log" 2>&1
wait "$lockpid"
check "S58: apt-get check reports the held lock (the message is_locked reads)" grep -qiE 'could not get lock|lock (was|is) locked by' "$W/s58.log"
cleanup

echo "== S59: a rename a stop cut short after apt took the old name: the next run installs the new one, with the old mark"
setup
install_keyring
in_root apt-mark auto libretech-gpio >/dev/null 2>&1
# what the stopped run left: its record, the old name gone, the new one never unpacked
echo auto > "$mnt$S/pending-libre-computer-gpio"
in_root env DEBIAN_FRONTEND=noninteractive dpkg -r libretech-dtoverlay libretech-gpio > "$W/s59a.log" 2>&1
migrate s59.log
check "S59: libre-computer-gpio installed and automatic, the record gone" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-gpio && chroot '$mnt' apt-mark showauto | grep -qx libre-computer-gpio && test ! -e '$mnt$S/pending-libre-computer-gpio'"
cleanup

echo "== S60: a dpkg run cut short (its journal has entries): the migration leaves it, waits, and says what to run"
setup
install_keyring
# an interrupted dpkg: an entry in its journal
mkdir -p "$mnt/var/lib/dpkg/updates"
: > "$mnt/var/lib/dpkg/updates/0000"
migrate s60.log
check "S60: the journal left as it was, the renames waiting, saying why" bash -c "test -e '$mnt/var/lib/dpkg/updates/0000' && grep -q 'journal has entries.*dpkg --configure -a' '$W/s60.log' && test -e '$mnt$S/migrate-pending'"
rm -f "$mnt/var/lib/dpkg/updates/0000"
cleanup

echo "== S61: a rename that never began (its old name held) leaves no record behind"
setup
in_root apt-mark hold libretech-alsa-ucm-conf >/dev/null 2>&1
install_keyring
migrate s61.log
check "S61: alsa kept, no pending record for its new name" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-alsa-ucm-conf && test ! -e '$mnt$S/pending-alsa-ucm-conf-libre-computer'"
cleanup

echo "== S62: an entry whose path differs from packages.libre.computer's only in case is another repository"
setup
echo 'deb [signed-by=/usr/share/keyrings/libre-computer-deb.gpg] file:///srv/TEST-REPO trixie main' > "$mnt/etc/apt/sources.list.d/other-case.list"
install_keyring
check "S62: the shipped stanza written (the other-case entry not taken for the board's own)" bash -c "grep -qx 'URIs: file:///srv/test-repo' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -e '$mnt$S/migrate-pending'"
cleanup

echo "== S63: a package only awaiting triggers (as a power loss before apt's closing configure leaves one) holds nothing back"
setup
install_keyring
# trig-int is interested in /usr/share/trig-test; trig-act ships a file there, installed without trigger
# processing: trig-int is left triggers-pending
for t in int act; do
	d=$W/pkg-trig-$t
	rm -rf "$d"; mkdir -p "$d/DEBIAN"
	printf 'Package: trig-%s\nVersion: 1\nArchitecture: all\nMaintainer: t <t@invalid>\nDescription: trigger test\n' "$t" > "$d/DEBIAN/control"
done
echo 'interest /usr/share/trig-test' > "$W/pkg-trig-int/DEBIAN/triggers"
mkdir -p "$W/pkg-trig-act/usr/share/trig-test"
echo x > "$W/pkg-trig-act/usr/share/trig-test/x"
for t in int act; do dpkg-deb --root-owner-group -b "$W/pkg-trig-$t" "$mnt/tmp/trig-$t.deb" >/dev/null; done
in_root dpkg -i /tmp/trig-int.deb > "$W/s63a.log" 2>&1
in_root dpkg --no-triggers -i /tmp/trig-act.deb >> "$W/s63a.log" 2>&1
check "S63: the precondition: trig-int triggers-pending" bash -c "chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' trig-int | grep -qx triggers-pending"
migrate s63.log
check "S63: the migration finishes (trig-int not taken for a part-done package of someone else's)" grep -q 'done: the board reads' "$W/s63.log"
cleanup

echo "== S64: a power loss while dpkg removed an old name: the migration waits for the journal, then takes the old name out itself"
setup
install_keyring
# what the cut-short removal left: apt removes the dependent first (libretech-dtoverlay depends on
# libretech-gpio), then the old name, which the power loss left half-installed in dpkg's journal
in_root env DEBIAN_FRONTEND=noninteractive dpkg -r libretech-dtoverlay > "$W/s64a.log" 2>&1
mkdir -p "$mnt/var/lib/dpkg/updates"
chroot "$mnt" dpkg-query -s libretech-gpio | sed 's/^Status: .*/Status: install ok half-installed/' > "$mnt/var/lib/dpkg/updates/0000"
migrate s64.log
check "S64: the journal left, the renames waiting, saying what to run" bash -c "test -n \"\$(ls -A '$mnt/var/lib/dpkg/updates')\" && grep -q 'dpkg --configure -a' '$W/s64.log' && test -e '$mnt$S/migrate-pending'"
# the owner's dpkg --configure -a folds the journal (it cannot finish the half-installed old name)
in_root dpkg --configure -a > "$W/s64b.log" 2>&1
migrate s64c.log
check "S64: then libre-computer-gpio in, libretech-gpio gone (the rename's run removing it), done" bash -c "$(declare -f installed); mnt='$mnt'; installed libre-computer-gpio && ! chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' libretech-gpio 2>/dev/null | grep -qvx 'not-installed\|config-files' && grep -q 'done: the board reads' '$W/s64c.log'"
cleanup

echo "== S66: the owner's transitional libretech-keyring left part-done is not excepted: never configured, only removed (its rename's removal configures nothing)"
setup
install_keyring
# the transitional unpacked again, never configured (as a cut-short run of the owner's leaves it)
in_root dpkg --unpack "/tmp/${trans_keyring##*/}" > "$W/s66a.log" 2>&1
check "S66: the precondition: libretech-keyring unpacked beside libre-computer-archive-keyring" bash -c "chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' libretech-keyring | grep -qx unpacked"
migrate s66.log
# the renames' installs wait on it (part-done, not theirs to configure); the same run's removal takes it out
check "S66: removed by the rename's removal run, never configured; the installs waited" bash -c "! chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' libretech-keyring 2>/dev/null | grep -qvx 'not-installed\|config-files' && ! grep -q 'Setting up libretech-keyring' '$W/s66.log' && grep -q 'part-done: *libretech-keyring' '$W/s66.log'"
migrate s66b.log
check "S66: the next run does the renames" grep -q 'done: the board reads' "$W/s66b.log"
cleanup

echo "== S67: the old kernel meta-package left unpacked (its postinst failed) beside the new one still goes"
setup
dummy linux-image-lc-lts-arm
in_root dpkg -i /tmp/linux-image-lc-lts-arm.deb >/dev/null 2>&1
dummy linux-image-lc-lts-armhf
in_root dpkg -i /tmp/linux-image-lc-lts-armhf.deb >/dev/null 2>&1
install_keyring
# as the owner's upgrade leaves them: the old meta manual, the new one pulled in automatic
in_root apt-mark manual linux-image-lc-lts-arm >/dev/null 2>&1
in_root apt-mark auto linux-image-lc-lts-armhf >/dev/null 2>&1
in_root dpkg --unpack /tmp/linux-image-lc-lts-arm.deb > "$W/s67a.log" 2>&1
check "S67: the precondition: linux-image-lc-lts-arm unpacked" bash -c "chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' linux-image-lc-lts-arm | grep -qx unpacked"
migrate s67.log
check "S67: the old meta gone, the new one in and manual (as the old one was), nothing pending for the kernel" bash -c "$(declare -f installed); mnt='$mnt'; ! chroot '$mnt' dpkg-query -W -f '\${db:Status-Status}' linux-image-lc-lts-arm 2>/dev/null | grep -qvx 'not-installed\|config-files' && installed linux-image-lc-lts-armhf && chroot '$mnt' apt-mark showmanual | grep -qx linux-image-lc-lts-armhf && test ! -e '$mnt$S/kernel-pending'"
cleanup

echo "== S68: a move stopped after step 1 rewrote libre-computer.sources (it held every old entry), before step 2's marks"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
# what the stopped run left: the new stanza in place, its moving mark and retry mark, no migration marks
printf 'Types: deb\nURIs: file:///srv/test-repo\nSuites: trixie\nComponents: main non-free\nSigned-By: /usr/share/keyrings/libre-computer-deb.gpg\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
mkdir -p "$mnt$S"
touch "$mnt$S/moving" "$mnt$S/move-pending"
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
in_root env LC_PACKAGES_URI=file:///srv/test-repo sh /tmp/lc-move > "$W/s68.log" 2>&1
check "S68: the next run finishes step 2: the migration pending and the board moved, the marks cleared" bash -c "test -e '$mnt$S/migrate-pending' && test -e '$mnt$S/moved' && test ! -e '$mnt$S/moving' && test ! -e '$mnt$S/move-pending' && grep -q 'cut short after its new source went in' '$W/s68.log'"
cleanup

echo "== S69: a moving mark from a run stopped before its rename, the old entries since removed by hand: no move claimed"
setup
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
mkdir -p "$mnt$S"
touch "$mnt$S/moving" "$mnt$S/move-pending"
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
in_root env LC_PACKAGES_URI=file:///srv/test-repo sh /tmp/lc-move > "$W/s69.log" 2>&1
check "S69: no migration scheduled, the board not marked moved, the stale mark gone" bash -c "test ! -e '$mnt$S/migrate-pending' && test ! -e '$mnt$S/moved' && test ! -e '$mnt$S/moving' && ! grep -q 'cut short' '$W/s69.log'"
cleanup

echo "== S70: a board whose init is not systemd (nothing would run the renames) stays on deb.libre.computer"
setup
ln -sfn /bin/true "$mnt/sbin/init"
install_keyring
check "S70: stays, says why, nothing pending" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt$S/migrate-pending' && test ! -e '$mnt$S/move-pending' && grep -q 'is not systemd' '$W/dpkg.log'"
cleanup

echo "== S71: an image build with no /sbin/init yet (its init added later) and systemd itself installed: it moves"
setup
rm -f "$mnt/sbin/init"
install_keyring
check "S71: moved, the migration pending" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -e '$mnt$S/migrate-pending' && ! grep -q 'is not systemd' '$W/dpkg.log'"
cleanup

echo "== S72: the owner holds the self-contained libretech-keyring: the migration leaves it (and its name) in place"
deblibre_repo "$deblibre_keyring"
setup_deblibre
upgrade
in_root apt-mark hold libretech-keyring > "$W/s72-hold.log" 2>&1
migrate s72.log
check "S72: libretech-keyring kept, libre-computer-archive-keyring not swapped in, and said why" bash -c "$(declare -f installed); mnt='$mnt'; installed libretech-keyring && ! installed libre-computer-archive-keyring && grep -q 'libretech-keyring is held' '$W/s72.log'"
check "S72: the migration stays pending" test -e "$mnt$S/migrate-pending"
cleanup

echo "== S73: the guard refuses an unpack whose Replaces covers a package on the board that the run does not remove"
setup
install_keyring
dummy owner-thing
in_root dpkg -i /tmp/owner-thing.deb > "$W/s73.log" 2>&1
dummy zz-replacer "Replaces: owner-thing"
guarded " " install /tmp/zz-replacer.deb
check "S73: refused, nothing changed" bash -c "$(declare -f installed); mnt='$mnt'; installed owner-thing && ! installed zz-replacer && grep -q 'rename-guard: zz-replacer would replace owner-thing' '$W/s54.log'"
dummy zz-replacer "Replaces: owner-thing (<< 0.5)"
guarded " " install /tmp/zz-replacer.deb
check "S73: a Replaces whose version does not cover the one on the board: let through" bash -c "$(declare -f installed); mnt='$mnt'; installed owner-thing && installed zz-replacer"
cleanup

echo "== S74: the keyring purged while the migration's move probes packages.libre.computer: the move stops, re-creating nothing"
setup
install_keyring
rm -rf "$mnt$S"
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
# (the state gone before the move's first write, as a purge during its probe leaves it)
in_root env LC_MOVE_FROM_MIGRATE=1 LC_PACKAGES_URI=file:///srv/unreachable sh /tmp/lc-move > "$W/s74.log" 2>&1
check "S74: no state directory re-created, and said why" bash -c "test ! -e '$mnt$S' && grep -q 'removed meanwhile' '$W/s74.log'"
cleanup

echo "== S75: a dpkg-reconfigure's move (no dpkg lock) after the keyring was removed: it stops, writing nothing"
setup
in_root apt-get -q update > "$W/s75.log" 2>&1 || true
rm -f "$mnt/usr/share/keyrings/libre-computer-deb.gpg"
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
in_root env DEBCONF_RECONFIGURE=1 DPKG_MAINTSCRIPT_PACKAGE=libre-computer-archive-keyring LC_PACKAGES_URI=file:///srv/test-repo \
	sh /tmp/lc-move >> "$W/s75.log" 2>&1
check "S75: no state, no new source, deb.libre.computer kept, and said why" bash -c "test ! -e '$mnt$S' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && grep -q 'removed meanwhile' '$W/s75.log'"
cleanup

echo "== S76: another kernel channel's meta-package left unpacked by a failed upgrade: the board stays"
setup
dummy linux-image-lc-edge-arm64
in_root dpkg --unpack /tmp/linux-image-lc-edge-arm64.deb > "$W/s76.log" 2>&1
install_keyring
check "S76: stays on deb.libre.computer, says why, nothing pending" bash -c "test -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list' && test ! -e '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test ! -e '$mnt$S/migrate-pending' && grep -q 'kernel channel packages.libre.computer does not carry' '$W/dpkg.log'"
cleanup

echo "== S77: a move stopped after step 1 on bookworm, the board upgraded to trixie before the next run: step 2 still finishes"
setup
printf 'Types: deb\nURIs: file:///srv/test-repo\nSuites: bookworm\nComponents: main non-free\nSigned-By: /usr/share/keyrings/libre-computer-deb.gpg\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
mkdir -p "$mnt$S"
echo bookworm > "$mnt$S/moving"
touch "$mnt$S/move-pending"
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
in_root env LC_PACKAGES_URI=file:///srv/test-repo sh /tmp/lc-move > "$W/s77.log" 2>&1
check "S77: the migration pending, the marks cleared" bash -c "test -e '$mnt$S/migrate-pending' && test ! -e '$mnt$S/moving' && test ! -e '$mnt$S/move-pending' && grep -q 'cut short after its new source went in' '$W/s77.log'"
cleanup

echo "== S78: the same stop and upgrade, the owner's release upgrade having edited the stanza: step 2 still finishes"
setup
printf 'Types: deb\nURIs: file:///srv/test-repo\nSuites: trixie\nComponents: main non-free\nSigned-By: /usr/share/keyrings/libre-computer-deb.gpg\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
rm -f "$mnt/etc/apt/sources.list.d/libre-computer-deb.list"
mkdir -p "$mnt$S"
echo bookworm > "$mnt$S/moving"
touch "$mnt$S/move-pending"
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
in_root env LC_PACKAGES_URI=file:///srv/test-repo sh /tmp/lc-move > "$W/s78.log" 2>&1
check "S78: the migration pending, the marks cleared" bash -c "test -e '$mnt$S/migrate-pending' && test ! -e '$mnt$S/moving' && test ! -e '$mnt$S/move-pending'"
cleanup

echo "== S79: the stop on bookworm, the upgrade to trixie, a deb.libre.computer entry left elsewhere: it moves, the bookworm stanza kept (README Known limits)"
setup
printf 'Types: deb\nURIs: file:///srv/test-repo\nSuites: bookworm\nComponents: main non-free\nSigned-By: /usr/share/keyrings/libre-computer-deb.gpg\n' > "$mnt/etc/apt/sources.list.d/libre-computer.sources"
mkdir -p "$mnt$S"
echo bookworm > "$mnt$S/moving"
touch "$mnt$S/move-pending"
dpkg-deb --fsys-tarfile "$new_keyring" | tar -xO ./usr/lib/libre-computer-archive-keyring/libre-computer-move > "$mnt/tmp/lc-move"
in_root env LC_PACKAGES_URI=file:///srv/test-repo LC_PACKAGES_KEY=/srv/test-repo/test-key.gpg sh /tmp/lc-move > "$W/s79.log" 2>&1
check "S79: moved, trixie's stanza added, bookworm's kept, the migration pending" bash -c "grep -qx 'Suites: trixie' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && grep -qx 'Suites: bookworm' '$mnt/etc/apt/sources.list.d/libre-computer.sources' && test -e '$mnt$S/migrate-pending' && test ! -s '$mnt/etc/apt/sources.list.d/libre-computer-deb.list'"
cleanup

echo "test-deb-move: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
