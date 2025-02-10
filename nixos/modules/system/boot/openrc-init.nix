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
  boot.initrd.extraUtilsCommands = ''
    # Create essential directories
    mkdir -p $out/{lib,run/openrc/{init.d,conf.d,runlevels,started}}
    mkdir -p $out/{libexec/rc/sh,usr/lib/rc/sh}

    # Copy OpenRC binaries AND libraries
    for binary in openrc-init rc rc-service rc-status rc-update start-stop-daemon; do
      copy_bin_and_libs ${config.boot.initrd.openrc.package}/bin/$binary
    done

    # Explicitly copy OpenRC libraries
    for lib in libeinfo librc; do
      for libfile in ${config.boot.initrd.openrc.package}/lib/''${lib}.so*; do
        if [ -f "$libfile" ]; then
          echo "Copying library: $libfile"
          copy_bin_and_libs "$libfile"
        fi
      done
    done

    # Create library symlinks
    ln -sf /lib/libeinfo.so.1 $out/lib/libeinfo.so
    ln -sf /lib/librc.so.1 $out/lib/librc.so

    # Set up ld.so.conf to find the libraries
    mkdir -p $out/etc
    echo "/lib" > $out/etc/ld.so.conf
    echo "/usr/lib" >> $out/etc/ld.so.conf

    # Create minimal runtime config
    cat > $out/run/openrc/rc.conf << EOF
      rc_sys=""
      rc_basedir="/run/openrc"
      rc_runleveldir="/run/openrc/runlevels"
      rc_initdir="/run/openrc/init.d"
      rc_confdir="/run/openrc/conf.d"
      rc_shell=/bin/sh
    EOF
    chmod 644 $out/run/openrc/rc.conf

    # Create minimal functions.sh
    cat > $out/usr/lib/rc/sh/functions.sh << EOF
      # Minimal functions.sh for initrd
      RC_GOT_FUNCTIONS="yes"

      get_bootparam() {
        return 1
      }

      is_running() {
        [ -e "/run/openrc/started/$1" ]
      }

      service_started() {
        is_running "$1"
      }

      mark_service_started() {
        touch "/run/openrc/started/$1"
      }

      mark_service_stopped() {
        rm -f "/run/openrc/started/$1"
      }
    EOF
    chmod 644 $out/usr/lib/rc/sh/functions.sh

    # Create basic sysinit script
    cat > $out/run/openrc/init.d/sysinit << EOF
      #!/bin/sh

      description="System initialization"

      depend() {
        before *
      }

      start() {
        return 0
      }
    EOF
    chmod +x $out/run/openrc/init.d/sysinit

    # Create symlink for init
    ln -sf openrc-init $out/bin/init

    # Create essential OpenRC directories and files
    mkdir -p $out/etc/runlevels/{boot,default,sysinit}
    mkdir -p $out/etc/{init.d,conf.d}

    # Copy OpenRC configuration
    cat > $out/etc/rc.conf << EOF
    rc_sys=""
    rc_basedir="/run/openrc"
    rc_runleveldir="/run/openrc/runlevels"
    rc_initdir="/run/openrc/init.d"
    rc_confdir="/run/openrc/conf.d"
    EOF

    # Create basic sysinit service
    cat > $out/etc/init.d/sysinit << EOF
    #!/bin/sh
    description="System initialization"

    depend() {
        before *
    }

    start() {
        return 0
    }
    EOF
    chmod +x $out/etc/init.d/sysinit
  '';

  boot.initrd.extraUtilsCommandsTest = ''
    # Test library presence
    if ! ldd $out/bin/openrc-init | grep -q libeinfo.so.1; then
      echo "ERROR: openrc-init is missing libeinfo.so.1 dependency"
      exit 1
    fi
    if ! ldd $out/bin/openrc-init | grep -q librc.so.1; then
      echo "ERROR: openrc-init is missing librc.so.1 dependency"
      exit 1
    fi
  '';

  boot.initrd.postMountCommands = ''
    # Create OpenRC runtime directories
    mkdir -p /run/openrc/{init.d,conf.d,runlevels,started}

    # Only mount if not already mounted
    mountpoint -q /proc || mount -t proc proc /proc
    mountpoint -q /sys || mount -t sysfs sysfs /sys
    mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev

    # Start OpenRC
    exec /bin/openrc-init
  '';

  environment.systemPackages = [ openrcPkg ];
};
}
