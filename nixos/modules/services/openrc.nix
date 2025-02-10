{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;

  # Simplified service aggregation
  openrcServices = pkgs.runCommand "openrc-services" {
    nativeBuildInputs = [ pkgs.rsync ];
  } ''
    mkdir -p $out/etc/openrc/{init.d,conf.d}

    # Create missing functions.sh symlink
    ln -s ${config.boot.initrd.openrc.package}/libexec/rc/sh/functions.sh $out/etc/openrc/init.d/

    # Copy core services from OpenRC package - handle empty directories
    if [ -d ${config.boot.initrd.openrc.package}/etc/openrc/init.d ]; then
      cp -r ${config.boot.initrd.openrc.package}/etc/openrc/init.d/* $out/etc/openrc/init.d/ || true
    fi
    if [ -d ${config.boot.initrd.openrc.package}/etc/openrc/conf.d ]; then
      cp -r ${config.boot.initrd.openrc.package}/etc/openrc/conf.d/* $out/etc/openrc/conf.d/ || true
    fi

    # Install user-defined services with proper error handling
    shopt -s nullglob
    ${lib.concatStrings (lib.mapAttrsToList (name: cfg: ''
      if [ -f ${cfg.script} ]; then
        install -Dm755 ${cfg.script} $out/etc/openrc/init.d/${name}
      else
        echo "Warning: Service script ${cfg.script} not found" >&2
      fi
    '') config.services.openrc.services)}
  '';

in {
  options.services.openrc = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable OpenRC service management";
    };

    services = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          script = mkOption {
            type = types.path;
            description = "Path to service init script";
          };
          runlevels = mkOption {
            type = types.listOf types.str;
            default = ["default"];
            description = "Runlevels to enable this service in";
          };
          dependencies = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Services this depends on";
          };
        };
      });
      default = {};
      description = "OpenRC service definitions";
    };
  };

  config = lib.mkIf config.services.openrc.enable {
    environment.etc = {
      "openrc/init.d".source = "${openrcServices}/etc/openrc/init.d";
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

      # Link store paths to expected locations
      ln -sfn ${openrcServices}/etc/openrc/init.d /etc/init.d
      ln -sfn ${openrcServices}/etc/openrc/conf.d /etc/conf.d

      # Initialize service links
      ${pkgs.openrc}/bin/rc-update -u
    '';

    environment.systemPackages = [ pkgs.openrc ];

    boot.initrd.systemd.enable = false;
    boot.initrd.openrc = {
      enable = true;
      package = pkgs.openrc;
    };
  };
}
