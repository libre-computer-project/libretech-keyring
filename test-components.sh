#!/bin/bash
# test-components.sh -- apt/libre-computer-components on fixture sources files (no root, no apt needed beyond
# apt-config, which falls back to the default parts directory when absent).
#   bash test-components.sh
set -u
H=$(cd "$(dirname "$0")" && pwd)/apt/libre-computer-components
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
check() { local what=$1; shift; if "$@"; then PASS=$((PASS + 1)); echo "ok   $what"; else FAIL=$((FAIL + 1)); echo "FAIL $what"; fi; }
run() { LC_SOURCES_FILE=$1 sh "$H" >"$T/out" 2>&1; }
ours='Types: deb
URIs: https://packages.libre.computer/deb
Suites: trixie
Components: main non-free
Signed-By: /usr/share/keyrings/libre-computer-deb.gpg'

f=$T/a.sources; printf '%s\n' "$ours" >"$f"; chmod 640 "$f"
run "$f"
check "the stanza libre-computer-move writes gets non-free-firmware" grep -qx 'Components: main non-free non-free-firmware' "$f"
check "and nothing else in it changes" bash -c "diff <(grep -v '^Components:' '$f') <(printf '%s\n' \"\$1\" | grep -v '^Components:')" _ "$ours"
check "the file keeps its mode" test "$(stat -c %a "$f")" = 640
check "it says what it did" grep -q 'added non-free-firmware' "$T/out"
cp "$f" "$T/a.again"; run "$f"
check "a second run changes nothing" cmp -s "$f" "$T/a.again"

f=$T/b.sources; printf '%s\n' "${ours/main non-free/main}" >"$f"; cp "$f" "$T/b.orig"; run "$f"
check "a stanza the owner changed (main only) is left alone" cmp -s "$f" "$T/b.orig"

f=$T/c.sources; printf '%s\n' "${ours/packages.libre.computer\/deb/example.org\/deb}" >"$f"; cp "$f" "$T/c.orig"; run "$f"
check "a stanza for another repository is left alone" cmp -s "$f" "$T/c.orig"

f=$T/d.sources; { printf '%s\n\n' "${ours/main non-free/main}"; printf '%s\n' "${ours/trixie/bookworm}"; } >"$f"; run "$f"
check "two stanzas: only the one with our components changes" bash -c "grep -c '^Components: main\$' '$f' | grep -qx 1 && grep -qx 'Components: main non-free non-free-firmware' '$f'"

f=$T/e.sources; printf '%s\n' "${ours/https:\/\/packages.libre.computer\/deb/https://packages.libre.computer/deb/}" >"$f"; run "$f"
check "a URI with a trailing slash is ours too" grep -qx 'Components: main non-free non-free-firmware' "$f"

run "$T/none.sources"
check "no file: exits 0 and makes none" bash -c "test ! -e '$T/none.sources'"
check "no temporary file is left beside the sources" bash -c "! ls '$T' | grep -q 'sources\.'"

echo "test-components: $PASS passed, $FAIL failed"
((FAIL == 0))
