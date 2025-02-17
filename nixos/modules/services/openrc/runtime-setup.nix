{ package, pkgs, lib, runtimeConfig }:
pkgs.writeScript "openrc-runtime-setup" ''
    #!${pkgs.bash}/bin/bash
    set -x

    # Essential environment setup
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.bash pkgs.gnused ]}:${package}/bin:${package}/sbin:$PATH
    export LD_LIBRARY_PATH=${package}/lib:$LD_LIBRARY_PATH
    export RC_LIBEXECDIR=/run/openrc/rc

    # Create runtime directories with explicit permissions
    mkdir -p -m 0755 /run/openrc
    mkdir -p -m 0755 /run/openrc/{init.d,conf.d,rc/sh,rc/bin,rc/sbin}
    mkdir -p -m 0755 /run/openrc/runlevels/{sysinit,boot,default,nonetwork,shutdown}

    # Create log directories
    mkdir -p -m 0755 /var/log
    mkdir -p -m 0755 /var/run
    mkdir -p -m 0755 /var/lock

    # Create essential symlinks for shell compatibility
    mkdir -p /bin
    ln -sf ${pkgs.bash}/bin/bash /bin/sh
    ln -sf ${pkgs.bash}/bin/bash /bin/bash

    # Install runtime configuration
    cp -f ${runtimeConfig} /run/openrc/rc.conf
    chmod 644 /run/openrc/rc.conf

    # Set up OpenRC shell environment
    echo "Setting up OpenRC shell environment..."

    # Copy shell scripts to runtime location
    mkdir -p /run/openrc/rc/sh
    for script in init.sh gendepends.sh functions.sh rc-functions.sh; do
      if [ -f "${package}/libexec/rc/sh/$script" ]; then
        cp -fv "${package}/libexec/rc/sh/$script" "/run/openrc/rc/sh/$script"
        chmod 755 "/run/openrc/rc/sh/$script"
      fi
    done

    # Create additional required symlinks
    ln -sf /run/openrc/rc/sh/functions.sh /run/openrc/rc/sh/rc-functions.sh
    ln -sf /run/openrc/rc/sh/functions.sh /etc/init.d/functions.sh

    # Copy RC binaries
    echo "Copying RC binaries..."
    mkdir -p /run/openrc/rc/bin
    for bin in ${package}/libexec/rc/bin/*; do
      if [ -f "$bin" ]; then
        name=$(basename "$bin")
        echo "Installing $name..."
        cp -fv "$bin" "/run/openrc/rc/bin/$name"
        chmod 755 "/run/openrc/rc/bin/$name"
      fi
    done

    # Ensure PATH includes OpenRC locations
    export PATH=/run/openrc/rc/bin:/run/openrc/rc/sh:/run/openrc/rc/sbin:$PATH

    # Copy and prepare init scripts
    echo "Copying init scripts..."
    for script in ${package}/share/openrc/init.d/*; do
      if [ -f "$script" ]; then
        name=$(basename "$script")
        target="/run/openrc/init.d/$name"

        # Copy the original script
        cp -f "$script" "$target"

        # Modify shebang and make executable
        sed -i "1s|#!/bin/sh|#!${pkgs.bash}/bin/bash|" "$target"
        chmod 755 "$target"

        # Create conf.d file if it exists in the original location
        if [ -f "${package}/share/openrc/conf.d/$name" ]; then
          cp -f "${package}/share/openrc/conf.d/$name" "/run/openrc/conf.d/$name"
          chmod 644 "/run/openrc/conf.d/$name"
        fi
      fi
    done

    # Create openrc-run wrapper
    cat > "/run/openrc/init.d/openrc-run" << EOF
    #!${pkgs.bash}/bin/bash
    exec ${package}/bin/openrc-run "\$@"
    EOF
    chmod 755 "/run/openrc/init.d/openrc-run"

    # Set up essential runlevels with error checking
    declare -A runlevel_services
    runlevel_services[sysinit]="devfs procfs sysfs dmesg"
    runlevel_services[boot]="localmount hostname modules bootmisc root fsck"
    runlevel_services[default]="local"

    for level in "''${!runlevel_services[@]}"; do
      echo "Setting up $level runlevel..."
      mkdir -p -m 0755 "/run/openrc/runlevels/$level"

      for svc in ''${runlevel_services[$level]}; do
        if [ -f "/run/openrc/init.d/$svc" ]; then
          echo "Enabling $svc in $level"
          ln -sf "/run/openrc/init.d/$svc" "/run/openrc/runlevels/$level/$svc"
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
    ln -sf /run/openrc/rc/sh /etc/rc.d

    # Create softlevel indicator
    touch /run/openrc/softlevel
  ''
