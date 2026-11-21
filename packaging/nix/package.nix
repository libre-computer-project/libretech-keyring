# The keyring for Nix outside NixOS: $out/share/libre-computer/nix.conf, the two lines a host's nix.conf takes to
# trust packages.libre.computer's binary cache (`!include` it, or copy them). On NixOS the flake's module sets the
# same two settings. The Nix counterpart of libre-computer-archive-keyring (deb), libre-computer-release (rpm) and
# libre-computer-keyring (pacman).
{ lib, stdenvNoCC, cache, version }:
stdenvNoCC.mkDerivation {
  pname = "libre-computer-keyring";
  inherit version;
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/share/libre-computer
    printf 'extra-substituters = %s\nextra-trusted-public-keys = %s\n' '${cache.url}' '${cache.key}' \
      >$out/share/libre-computer/nix.conf
  '';
  meta = {
    description = "Trust for packages.libre.computer's Nix binary cache";
    homepage = "https://github.com/libre-computer-project/libretech-keyring";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
