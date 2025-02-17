# Core boot configuration
{ config, lib, pkgs, ... }:

let
  runtime = import ../../services/openrc/runtime.nix { inherit config lib pkgs; };
in {
  options.boot.initrd.openrc = {
    enable = lib.mkEnableOption "OpenRC init system";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openrc;
      description = "OpenRC package to use";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.boot.initrd.openrc.enable {
      environment.systemPackages = [ config.boot.initrd.openrc.package ];
    })
    runtime.config
  ];
}
