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

  openrcRuntimeSetup = pkgs.writeScript "openrc-runtime-setup" ''
    #!${pkgs.bash}/bin/bash
    set -x

    # Essential environment setup
    export PATH=${openrcPkg}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:$PATH
    export LD_LIBRARY_PATH=${openrcPkg}/lib:$LD_LIBRARY_PATH

    # Create runtime directories with explicit permissions
    mkdir -p -m 0755 /run/openrc
    mkdir -p -m 0755 /run/openrc/{init.d,conf.d,rc/sh}
    mkdir -p -m 0755 /run/openrc/runlevels/{sysinit,boot,default,nonetwork,shutdown}

    # Create essential symlinks for shell compatibility
    mkdir -p /bin
    ln -sf ${pkgs.bash}/bin/bash /bin/sh
    ln -sf ${pkgs.bash}/bin/bash /bin/bash

    # Debug: Show directory structure
    echo "OpenRC directory structure:"
    ls -la /run/openrc
    ls -la /run/openrc/runlevels

    # Install runtime configuration
    cp -f ${runtimeConfig} /run/openrc/rc.conf
    chmod 644 /run/openrc/rc.conf

    # Link shell functions
    ln -sf ${openrcPkg}/libexec/rc/sh/functions.sh /run/openrc/rc/sh/
    chmod 755 /run/openrc/rc/sh/functions.sh

    # Copy and prepare init scripts
    echo "Copying init scripts..."
    for script in ${openrcPkg}/share/openrc/init.d/*; do
      if [ -f "$script" ]; then
        name=$(basename "$script")
        target="/run/openrc/init.d/$name"

        # Copy the original script
        cp -f "$script" "$target"

        # Modify shebang and make executable
        sed -i "1s|#!/bin/sh|#!${pkgs.bash}/bin/bash|" "$target"
        chmod 755 "$target"

        # Create conf.d file if it exists in the original location
        if [ -f "${openrcPkg}/share/openrc/conf.d/$name" ]; then
          cp -f "${openrcPkg}/share/openrc/conf.d/$name" "/run/openrc/conf.d/$name"
          chmod 644 "/run/openrc/conf.d/$name"
        fi
      fi
    done

    # Create openrc-run wrapper
    cat > "/run/openrc/init.d/openrc-run" << EOF
#!${pkgs.bash}/bin/bash
exec ${openrcPkg}/bin/openrc-run "\$@"
EOF
    chmod 755 "/run/openrc/init.d/openrc-run"

    # Set up essential runlevels with error checking
    declare -A runlevel_services
    runlevel_services[sysinit]="devfs procfs sysfs dmesg"
    runlevel_services[boot]="localmount hostname modules bootmisc root fsck"
    runlevel_services[default]="local"

    for level in ''${!runlevel_services[@]}; do
      echo "Setting up $level runlevel..."
      mkdir -p -m 0755 "/run/openrc/runlevels/$level"

      for svc in ''${runlevel_services[$level]}; do
        if [ -f "/run/openrc/init.d/$svc" ]; then
          echo "Enabling $svc in $level"
          ln -sf "/run/openrc/init.d/$svc" "/run/openrc/runlevels/$level/$svc"
          ls -l "/run/openrc/runlevels/$level/$svc" || echo "Failed to create symlink for $svc"
        else
          echo "Warning: Service script /run/openrc/init.d/$svc not found"
        fi
      done
    done

    # Create compatibility symlinks
    ln -sf /run/openrc/rc.conf /etc/rc.conf
    ln -sf /run/openrc/init.d /etc/init.d
    ln -sf /run/openrc/runlevels /etc/runlevels
    ln -sf /run/openrc/rc /etc/rc

    # Create essential directories that services might expect
    mkdir -p /var/log
    mkdir -p /var/run
    mkdir -p /var/lock

    # Debug: Final verification
    echo "Final runlevel contents:"
    for level in sysinit boot default; do
      echo "=== $level runlevel ==="
      ls -la "/run/openrc/runlevels/$level"
    done

    # Verify init scripts are executable
    echo "Verifying init scripts:"
    ls -la /run/openrc/init.d/

    # Create softlevel indicator
    touch /run/openrc/softlevel
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

    # Add the runtime configuration and setup scripts to system.build
    system.build = {
      openrcConfig = runtimeConfig;
      openrcLibSetup = openrcLibSetup;
      openrcRuntimeSetup = openrcRuntimeSetup;
    };
  };
}
