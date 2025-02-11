{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  useHostResolvConf = config.networking.resolvconf.enable && config.networking.useHostResolvConf;

  # Add OpenRC configuration
  openrcEnabled = config.boot.initrd.openrc.enable;
  openrcPkg = config.boot.initrd.openrc.package;

  # Create runtime configuration
  runtimeConfig = pkgs.writeText "openrc-runtime-config" ''
    rc_sys=""
    rc_controller_cgroups="NO"
    rc_depend_strict="YES"
    rc_logger="YES"
    rc_shell=/bin/sh
    rc_basedir="/run/openrc"
    rc_initdir="/run/openrc/init.d"
    rc_runleveldir="/run/openrc/runlevels"
    rc_confdir="/run/openrc/conf.d"
  '';

  # Create OpenRC library setup script
  openrcLibSetup = pkgs.writeScript "openrc-lib-setup" ''
    #!${pkgs.bash}/bin/bash
    set -x  # Enable debug output

    echo "Setting up OpenRC libraries..."

    # Create required directories
    mkdir -p /lib /run/ldconfig

    echo "OpenRC package path: ${openrcPkg}"
    echo "Contents of OpenRC lib directory:"
    ls -la ${openrcPkg}/lib/

    # Copy all OpenRC libraries
    echo "Copying OpenRC libraries..."
    for lib in ${openrcPkg}/lib/lib{einfo,rc}.so*; do
      if [ -f "$lib" ]; then
        echo "Copying $lib to /lib/"
        cp -av "$lib" /lib/
      else
        echo "Warning: Library $lib not found!"
      fi
    done

    # Verify copied libraries
    echo "Verifying copied libraries:"
    ls -la /lib/lib{einfo,rc}.so*

    # Update library cache
    echo "Updating library cache..."
    mkdir -p /run/ldconfig
    TMPDIR=/run/ldconfig ldconfig -v -C /run/ldconfig/ld.so.cache /lib

    # Test library loading
    echo "Testing library loading:"
    for lib in /lib/lib{einfo,rc}.so*; do
      echo "Testing $lib:"
      ldd "$lib" || true
    done

    # Copy cache to final location
    cp -av /run/ldconfig/ld.so.cache /etc/ld.so.cache
  '';

  # Modified stage2 mount script
  stage2MountScript = pkgs.writeText "stage2-mount" ''
    specialMount() {
      local device="$1"
      local mountPoint="$2"
      local options="$3"
      local fsType="$4"

      # Only mount if not already mounted
      if ! mountpoint -q "$mountPoint"; then
        mkdir -m 0755 -p "$mountPoint"
        mount -n -t "$fsType" -o "$options" "$device" "$mountPoint"
      fi
    }

    # Mount essential filesystems
    specialMount "proc" "/proc" "nosuid,noexec,nodev" "proc"
    specialMount "sysfs" "/sys" "nosuid,noexec,nodev" "sysfs"
    specialMount "devtmpfs" "/dev" "nosuid,mode=0755" "devtmpfs"
    specialMount "tmpfs" "/run" "nosuid,nodev,mode=0755" "tmpfs"
  '';

        openrcRuntimeSetup = pkgs.writeScript "openrc-runtime-setup" ''
    #!${pkgs.bash}/bin/bash
    set -x

    # Essential environment setup
    export PATH=${openrcPkg}/bin:$PATH
    export LD_LIBRARY_PATH=${openrcPkg}/lib:$LD_LIBRARY_PATH

    # Create runtime directories under /run
    mkdir -p /run/openrc/{init.d,conf.d,runlevels/{boot,default,nonetwork,shutdown,sysinit},rc/{init.d,sh}}

    # Link shell functions to runtime location
    ln -sf ${openrcPkg}/libexec/rc/sh/functions.sh /run/openrc/rc/sh/

    # Create init script symlinks in runtime directory
    for script in ${openrcPkg}/share/openrc/init.d/*; do
      if [ -f "$script" ]; then
        ln -sf "$script" "/run/openrc/init.d/$(basename $script)"
      fi
    done

    # Set up essential runlevels
    declare -A runlevel_services
    runlevel_services[sysinit]="devfs procfs sysfs dmesg"
    runlevel_services[boot]="localmount hostname modules bootmisc root fsck"

    for level in ''${!runlevel_services[@]}; do
      for svc in ''${runlevel_services[$level]}; do
        if [ -f "/run/openrc/init.d/$svc" ]; then
          mkdir -p "/run/openrc/runlevels/$level"
          ln -sf "/run/openrc/init.d/$svc" "/run/openrc/runlevels/$level/$svc"
        fi
      done
    done

    # Create compatibility symlinks
    ln -sf /run/openrc/init.d /run/init.d
    ln -sf /run/openrc/runlevels /run/runlevels
    ln -sf /run/openrc/rc /run/rc
  '';

  bootStage2 = pkgs.replaceVarsWith {
    src = ./stage-2-init.sh;
    isExecutable = true;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      systemConfig = null; # replaced in ../activation/top-level.nix
      inherit (config.boot) readOnlyNixStore systemdExecutable;
      inherit (config.system.nixos) distroName;
      inherit useHostResolvConf;
      inherit stage2MountScript;
      inherit openrcLibSetup;
      inherit openrcRuntimeSetup;

      # Add OpenRC to path if enabled
      path = lib.makeBinPath (
        [
          pkgs.coreutils
          pkgs.util-linux
          pkgs.glibc.bin  # For ldconfig
          pkgs.findutils
        ]
        ++ lib.optional useHostResolvConf pkgs.openresolv
        ++ lib.optional openrcEnabled openrcPkg
      );

      # Export OpenRC environment variable and config
      USE_OPENRC = if openrcEnabled then "1" else "";
      openrcPackage = if openrcEnabled then openrcPkg else null;
      # Add the runtime config
      openrcRuntimeConfig = if openrcEnabled then runtimeConfig else null;

      postBootCommands = pkgs.writeText "local-cmds" ''
        ${config.boot.postBootCommands}
        ${config.powerManagement.powerUpCommands}
      '';
    };
  };


in {
  options = {
    boot = {
      postBootCommands = mkOption {
        default = "";
        example = "rm -f /var/log/messages";
        type = types.lines;
        description = ''
          Shell commands to be executed just before init system is started.
        '';
      };

      readOnlyNixStore = mkOption {
        type = types.bool;
        default = true;
        description = ''
          If set, NixOS will enforce the immutability of the Nix store
          by making {file}`/nix/store` a read-only bind mount.
        '';
      };

      systemdExecutable = mkOption {
        default = "/run/current-system/systemd/lib/systemd/systemd";
        type = types.str;
        description = ''
          The program to execute to start systemd.
        '';
      };

      extraSystemdUnitPaths = mkOption {
        default = [];
        type = types.listOf types.str;
        description = ''
          Additional paths that get appended to the SYSTEMD_UNIT_PATH environment variable
          that can contain mutable unit files.
        '';
      };
    };
  };

  config = {
    system.build = {
      bootStage2 = bootStage2;
    };
  };
}
