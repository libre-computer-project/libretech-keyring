# libretech-keyring as a Nix flake (infra multi-distro plan, NixOS): what the keyring is on NixOS, trust for
# packages.libre.computer's binary cache, which every other Libre Computer flake takes its builds from. Cut per
# release by the release process (Libre Computer's pkg-mkflake.sh, --src embed), which adds ./version.nix; this
# directory alone is not a flake. nixpkgs is the newest NixOS stable channel, pinned by flake.lock (the same pin as
# the other Libre Computer flakes).
#
# On NixOS: imports = [ <this flake>.nixosModules.default ]; it adds the cache to nix.settings.extra-substituters
# and its key to nix.settings.extra-trusted-public-keys (the extra- forms, so cache.nixos.org stays).
{
  description = "Trust for packages.libre.computer's Nix binary cache (Libre Computer's keyring for NixOS)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      version = import ./version.nix;
      cache = import ./cache.nix;
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      drv = pkgs: pkgs.callPackage ./package.nix { inherit cache version; };
    in
    {
      packages = forAll (pkgs: rec {
        libre-computer-keyring = drv pkgs;
        default = libre-computer-keyring;
      });
      nixosModules.default = { ... }: {
        nix.settings.extra-substituters = [ cache.url ];
        nix.settings.extra-trusted-public-keys = [ cache.key ];
      };
    };
}
