#!/bin/bash
# fetch-test-images.sh -- one base image per release x arch from distro.libre.computer/ci (the images owners run
# on deb.libre.computer), each checked against the directory's SHA256SUMS, then decompressed: the inputs of
# test-image-move.sh.
#
#   fetch-test-images.sh <out dir>
#
# An image already decompressed in <out dir> is kept. Prints OK / NOSUM / SHA-MISMATCH / FETCH-FAIL per image.
#
# Style: software/convention/bash.md
set -u

B=https://distro.libre.computer/ci
O=${1:?usage: fetch-test-images.sh <out dir>}
mkdir -p "$O" && cd "$O" || exit 1
while read -r dir f; do
	[[ -n "$dir" ]] || continue
	img=${f%.xz}
	[[ -s "$img" ]] && { echo "have $img"; continue; }
	# the site redirects each file to its object store
	curl -fsSL -o "$f" "$B/$dir/${f//+/%2B}" || { echo "FETCH-FAIL $f"; continue; }
	want=$(curl -fsSL "$B/$dir/SHA256SUMS" | awk -v f="$f" '$2 == f || $2 == "*" f {print $1}')
	got=$(sha256sum "$f" | cut -d' ' -f1)
	if [[ -z "$want" ]]; then
		echo "NOSUM $f"
	elif [[ "$want" != "$got" ]]; then
		echo "SHA-MISMATCH $f"
		continue
	else
		echo "OK $f"
	fi
	xz -d "$f" || echo "XZ-FAIL $f"
done <<'EOF'
debian/11 debian-11-base-arm64+arm64.img.xz
debian/11 debian-11-base-armhf+arm32.img.xz
debian/12 debian-12-base-arm64+arm64.img.xz
debian/12 debian-12-base-armhf+arm32.img.xz
debian/12 debian-12-gnome-arm64+arm64.img.xz
raspbian/10 2023-05-03-raspbian-buster-armhf-lite+arm32.img.xz
raspbian/10 2023-05-03-raspbian-buster-armhf-lite+arm64.img.xz
raspbian/11 2023-05-03-raspbian-bullseye-arm64-lite+arm64.img.xz
raspbian/11 2023-05-03-raspbian-bullseye-armhf-lite+arm32.img.xz
raspbian/12 2023-10-10-raspbian-bookworm-arm64-lite+arm64.img.xz
raspbian/12 2023-10-10-raspbian-bookworm-armhf-lite+arm32.img.xz
ubuntu/20.04 ubuntu-20.04.5-preinstalled-base-arm64+arm64.img.xz
ubuntu/20.04 ubuntu-20.04.5-preinstalled-base-armhf+arm32.img.xz
ubuntu/22.04 ubuntu-22.04.3-preinstalled-base-arm64+arm64.img.xz
ubuntu/22.04 ubuntu-22.04.3-preinstalled-base-armhf+arm32.img.xz
ubuntu/23.04 ubuntu-23.04-preinstalled-base-arm64+arm64.img.xz
ubuntu/23.04 ubuntu-23.04-preinstalled-base-armhf+arm32.img.xz
EOF
echo FETCH-DONE
