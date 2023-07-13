{
  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-22.05";
    };
    openwrt = {
      url = git+https://git.openwrt.org/openwrt/openwrt.git;
      flake = false;
    };
  };
  outputs = inputs@{ self, ... }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    inherit (inputs.nixpkgs) lib;
  in {
    lib.withConfig = { system, settings ? import ./sample-settings.nix }: import ./default.nix {
      inherit system settings;
      inherit (inputs) nixpkgs;
      openwrt-src = inputs.openwrt;
    };
    legacyPackages = lib.genAttrs systems (system: self.lib.withConfig { inherit system; });
    packages = lib.genAttrs systems (system: {
      default = inputs.self.legacyPackages.${system}.boot;
    });
  };
}
