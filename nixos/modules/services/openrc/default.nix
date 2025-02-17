{ config, lib, pkgs, ... }:

let
  cfg = config.services.openrc;
  openrcPkg = config.boot.initrd.openrc.package;
in {
  imports = [
    ./library-setup.nix
    ./runtime.nix
    ./runtime-setup.nix
    ./service-aggregation.nix
    ../../system/boot/openrc-init.nix
  ];

  options.services.openrc = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable OpenRC service management";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          script = lib.mkOption {
            type = lib.types.path;
            description = "Path to service init script";
          };
          runlevels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["default"];
            description = "Runlevels to enable this service in";
          };
          dependencies = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Services this depends on";
          };
        };
      });
      default = {};
      description = "OpenRC service definitions";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.etc = {
        "init.d".source = "${openrcServices}/etc/openrc/init.d";
        "openrc/conf.d".source = "${openrcServices}/etc/openrc/conf.d";
        "openrc/rc.conf".text = ''
          rc_sys=""
          rc_controller_cgroups=""
          rc_depend_strict="YES"
          rc_confd="/etc/openrc/conf.d"
          rc_initd="/etc/openrc/init.d"
        '';
      };

      system.activationScripts.openrc = lib.stringAfter [ "etc" ] ''
        mkdir -p /run/openrc/{softlevel,started}
        chmod 0755 /run/openrc /run/openrc/*
        ${openrcPkg}/bin/rc-update -u
      '';

      environment.systemPackages = [ openrcPkg ];
    })

    (lib.mkIf config.boot.initrd.openrc.enable {
      boot.initrd.systemd.enable = false;
    })
  ];
}
