{ config, lib, pkgs, ... }:

let
  cfg = config.boot.initrd.openrc;
  runtimeConfig = pkgs.writeText "openrc-runtime-config" ''
    rc_sys=""
    rc_controller_cgroups="NO"
    rc_depend_strict="YES"
    rc_logger="YES"
    rc_shell=/bin/sh
    rc_basedir="/run/openrc"
    rc_runleveldir="/run/openrc/runlevels"
    rc_initdir="/run/openrc/init.d"
    rc_confdir="/run/openrc/conf.d"
  '';
in {
  config = lib.mkIf cfg.enable {
    system.build = {
      openrcConfig = runtimeConfig;
      openrcLibSetup = import ./library-setup.nix {
        inherit (cfg) package;
        inherit pkgs lib;
      };
      openrcRuntimeSetup = import ./runtime-setup.nix {
        inherit (cfg) package;
        inherit pkgs lib;
        runtimeConfig = runtimeConfig;
      };
    };
  };
}
