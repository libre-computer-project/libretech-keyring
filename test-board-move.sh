#!/bin/bash
# test-board-move.sh -- the deb.libre.computer -> packages.libre.computer move on a real board, run as root on the
# board, against STAGING copies of both repositories (nothing published): a board whose owner has the
# libretech-keyring deb.libre.computer serves, then takes the self-contained libretech-keyring (build-deblibre.sh)
# through an ordinary apt-get update && apt-get upgrade, as it would from deb.libre.computer.
#
#   bash test-board-move.sh <staging base URL> <dir holding: test-key.gpg, real-keyring.deb, real-keyring.sha256>
#
# <staging base URL>/deb.libre.computer/repo serves the self-contained libretech-keyring (suite linux), and
# <staging base URL>/packages/deb serves the renamed packages (suite bookworm), both signed by test-key.gpg, a
# throwaway key the test puts at /usr/share/keyrings/libre-computer-deb.gpg while it reads them.
# real-keyring.deb is deb.libre.computer's libretech-keyring, checked against real-keyring.sha256.
#
#   1  the owner's state: deb.libre.computer's libretech-keyring installed
#   2  deb.libre.computer's source pointed at the staging copy (what publishing there would serve)
#   3  apt-get update && apt-get upgrade, restricted to the Libre Computer source (no Debian upgrades on this card)
#   4  the migration (the one-shot service), watched; held (a runtime mask) until the throwaway key is back in place
#   5  a real source left behind: packages.libre.computer with the real key, checked by apt-get update
# Prints PASS/FAIL per check; exit 0 iff every check passes.

set -u
S=${1:?usage: test-board-move.sh <staging URL> <dir>}
D=$(cd "${2:?usage: test-board-move.sh <staging URL> <dir>}" && pwd)
[[ $EUID -eq 0 ]] || { echo "needs root" >&2; exit 1; }
KEY=/usr/share/keyrings/libre-computer-deb.gpg
LIST=/etc/apt/sources.list.d/libre-computer-deb.list
SRC=/etc/apt/sources.list.d/libre-computer.sources
PASS=0 FAIL=0
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "PASS  $what"; else FAIL=$((FAIL + 1)); echo "FAIL  $what"; fi; }
st() { dpkg-query -W -f '${db:Status-Status} ${Version}' "$1" 2>/dev/null || echo not-installed; }
OURS=(-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts=/etc/apt/sources.list.d)
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin  # su -c keeps a user PATH

echo "== 0: the board as found"
uname -r
for p in libretech-keyring libretech-gpio libretech-dtoverlay libre-computer-archive-keyring libre-computer-gpio; do echo "$p: $(st $p)"; done
grep -h -v '^#' "$LIST" 2>/dev/null

echo "== 1: deb.libre.computer's libretech-keyring, as an owner has it"
check "1: real-keyring.deb matches deb.libre.computer's index" bash -c "[[ \$(sha256sum '$D/real-keyring.deb' | cut -d' ' -f1) == \$(cat '$D/real-keyring.sha256') ]]"
apt-get -y -q install "$D/real-keyring.deb" > "$D/1-install.log" 2>&1
check "1: libretech-keyring $(dpkg-deb -f "$D/real-keyring.deb" Version) installed" bash -c "[[ \$(dpkg-query -W -f '\${db:Status-Status}' libretech-keyring) == installed ]]"
cp -p "$KEY" "$D/real-key.gpg"

echo "== 2: deb.libre.computer's source pointed at the staging copy"
cp -p "$LIST" "$D/libre-computer-deb.list.orig"
echo "deb [arch=arm64 signed-by=$KEY] $S/deb.libre.computer/repo linux main" > "$LIST"
cp "$D/test-key.gpg" "$KEY"
apt-get "${OURS[@]}" -q update > "$D/2-update.log" 2>&1
check "2: apt reads the staging deb.libre.computer (signature checked)" bash -c "! grep -qE '^(E|W): ' '$D/2-update.log'"

echo "== 3: the owner's ordinary upgrade"
before=$(st libretech-keyring)
# hold the migration: the package puts the real key back, the staging repos need the throwaway one; its timers
# (the retry timer and the 30 s one) find the service masked until step 4
systemctl mask --runtime libre-computer-migrate.service >/dev/null 2>&1
LC_PACKAGES_URI=$S/packages/deb LC_PACKAGES_KEY=$D/test-key.gpg apt-get "${OURS[@]}" -y -q upgrade > "$D/3-upgrade.log" 2>&1
check "3: apt-get upgrade took the self-contained libretech-keyring ($before -> $(st libretech-keyring))" bash -c "dpkg-query -W -f '\${Version}' libretech-keyring | grep -q '~deb.libre.computer\$'"
check "3: its install moved the board: deb.libre.computer's source set aside, packages.libre.computer's in" bash -c "test ! -e '$LIST' && grep -qx 'URIs: $S/packages/deb' '$SRC' && grep -qx 'Suites: bookworm' '$SRC'"
check "3: the migration is pending, its retry timer enabled" bash -c "test -e /var/lib/libre-computer-archive-keyring/migrate-pending && systemctl is-enabled libre-computer-migrate.timer"
grep -h 'libre-computer-archive-keyring:' "$D/3-upgrade.log"

echo "== 4: the migration"
cp "$D/test-key.gpg" "$KEY"
t0=$(date +%s)
systemctl unmask --runtime libre-computer-migrate.service >/dev/null 2>&1
# bounded: a maintainer script that starts the unit from inside it deadlocks here (seen on a board)
timeout 900 systemctl start libre-computer-migrate.service
check "4: the migration unit returned within 900 s" test $? -ne 124
journalctl -u libre-computer-migrate.service --since "@$t0" --no-pager -o cat > "$D/4-migrate.log" 2>&1
grep -E '^libre-computer-migrate:' "$D/4-migrate.log"
check "4: the migration finished" grep -q 'done: the board reads packages.libre.computer' "$D/4-migrate.log"
for p in libre-computer-archive-keyring libre-computer-gpio libre-computer-dtoverlay; do
	check "4: $p installed ($(st $p))" bash -c "[[ \$(dpkg-query -W -f '\${db:Status-Status}' $p) == installed ]]"
done
for p in libretech-keyring libretech-gpio libretech-dtoverlay; do
	check "4: $p gone" bash -c "[[ \$(dpkg-query -W -f '\${db:Status-Status}' $p 2>/dev/null) != installed ]]"
done
check "4: lgpio and ldto still run" bash -c "command -v lgpio && command -v ldto && test -x \$(readlink -f /usr/bin/lgpio) && test -x \$(readlink -f /usr/bin/ldto)"
check "4: nothing pending, the timer disabled" bash -c "test ! -e /var/lib/libre-computer-archive-keyring/migrate-pending && ! systemctl is-enabled libre-computer-migrate.timer"
check "4: dpkg --audit says nothing" bash -c "[[ -z \$(dpkg --audit) ]]"

echo "== 5: a real source left behind"
cp -p "$D/real-key.gpg" "$KEY"
sed -i -E "s|^URIs: .*|URIs: https://packages.libre.computer/deb|" "$SRC"
apt-get "${OURS[@]}" -q update > "$D/5-update.log" 2>&1
check "5: packages.libre.computer verifies with the real key" bash -c "! grep -qE '^(E|W): ' '$D/5-update.log' && grep -q 'packages.libre.computer' '$D/5-update.log'"
cat "$SRC"

echo "test-board-move: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
