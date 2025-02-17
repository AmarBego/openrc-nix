{ config, lib, pkgs, ... }:

let
  openrcServices = pkgs.runCommand "openrc-services" {
    nativeBuildInputs = [ pkgs.rsync ];
  } ''
    mkdir -p $out/etc/openrc/{init.d,conf.d}

    # Create missing functions.sh symlink
    ln -s ${config.boot.initrd.openrc.package}/libexec/rc/sh/functions.sh $out/etc/openrc/init.d/

    # Copy core services from OpenRC package
    if [ -d ${config.boot.initrd.openrc.package}/etc/openrc/init.d ]; then
      cp -r ${config.boot.initrd.openrc.package}/etc/openrc/init.d/* $out/etc/openrc/init.d/ || true
    fi
    if [ -d ${config.boot.initrd.openrc.package}/etc/openrc/conf.d ]; then
      cp -r ${config.boot.initrd.openrc.package}/etc/openrc/conf.d/* $out/etc/openrc/conf.d/ || true
    fi

    # Install user-defined services
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
  config = lib.mkIf config.services.openrc.enable {
    environment.etc = {
      "init.d".source = "${openrcServices}/etc/openrc/init.d";
      "openrc/conf.d".source = "${openrcServices}/etc/openrc/conf.d";
    };
  };
}
