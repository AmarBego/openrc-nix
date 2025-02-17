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

  # Inherit OpenRC runtime configuration and setup scripts
  inherit (config.system.build) openrcConfig openrcLibSetup openrcRuntimeSetup;

  # Modified stage2 mount script
  stage2MountScript = pkgs.writeText "stage-2-mount" ''
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

  bootStage2 = pkgs.replaceVarsWith {
    src = ./stage-2-init.sh;
    isExecutable = true;
    replacements = {
      shell = "${pkgs.bash}/bin/bash";
      systemConfig = null;
      readOnlyNixStore = config.boot.readOnlyNixStore;
      systemdExecutable = config.boot.systemdExecutable;
      distroName = config.system.nixos.distroName;
      useHostResolvConf = useHostResolvConf;
      stage2MountScript = stage2MountScript;

      # Add OpenRC substitutions
      USE_OPENRC = if openrcEnabled then "1" else "";
      openrcLibSetup = toString openrcLibSetup;
      openrcRuntimeSetup = toString openrcRuntimeSetup;
      openrcRuntimeConfig = toString openrcConfig;
      openrcPackage = if openrcEnabled then "${openrcPkg}" else "";

      path = lib.makeBinPath ([
        pkgs.coreutils
        pkgs.util-linux
        pkgs.glibc.bin
        pkgs.findutils
      ] ++ lib.optional useHostResolvConf pkgs.openresolv
        ++ lib.optional openrcEnabled openrcPkg);

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
