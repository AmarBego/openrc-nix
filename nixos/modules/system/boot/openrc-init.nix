{ config, lib, pkgs, ... }:

let
  openrcPkg = pkgs.openrc;

  # Create runtime configuration
  runtimeConfig = pkgs.writeText "openrc-runtime-config" ''
    rc_sys=""
    rc_controller_cgroups="NO"
    rc_depend_strict="YES"
    rc_logger="YES"
    rc_shell=/bin/sh

    # Use runtime directories
    rc_basedir="/run/openrc"
    rc_runleveldir="/run/openrc/runlevels"
    rc_initdir="/run/openrc/init.d"
    rc_confdir="/run/openrc/conf.d"
  '';

in {
  options.boot.initrd.openrc = {
    enable = lib.mkEnableOption "OpenRC init system";
    package = lib.mkOption {
      type = lib.types.package;
      default = openrcPkg;
      description = "OpenRC package to use";
    };
  };

  config = lib.mkIf config.boot.initrd.openrc.enable {
    environment.systemPackages = [ openrcPkg ];
  };
}
