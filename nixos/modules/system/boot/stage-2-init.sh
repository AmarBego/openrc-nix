#! @shell@

systemConfig=@systemConfig@
export HOME=/root PATH="@path@"

# Process the kernel command line
for o in $(</proc/cmdline); do
    case $o in
        boot.debugtrace)
            set -x
            ;;
    esac
done

# Print a greeting
echo
echo -e "\e[1;32m<<< @distroName@ Stage 2 >>>\e[0m"
echo

# Ensure root is writable
if [ -z "$container" ]; then
    mount -n -o remount,rw none /
fi

# Mount essential filesystems if not already mounted
if [ ! -e /proc/1 ]; then
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
fi

# Make /nix/store read-only
if [ -n "@readOnlyNixStore@" ]; then
    if ! [[ "$(findmnt --direction backward --first-only --noheadings --output OPTIONS /nix/store)" =~ (^|,)ro(,|$) ]]; then
        if [ -z "$container" ]; then
            mount --bind /nix/store /nix/store
        else
            mount --rbind /nix/store /nix/store
        fi
        mount -o remount,ro,bind /nix/store
    fi
fi

# Handle resolv.conf
if [ -n "@useHostResolvConf@" ] && [ -e /etc/resolv.conf ]; then
    resolvconf -m 1000 -a host </etc/resolv.conf
fi

# Set up logging
exec {logOutFd}>&1 {logErrFd}>&2
if test -w /dev/kmsg; then
    exec > >(tee -i /proc/self/fd/"$logOutFd" | while read -r line; do
        if test -n "$line"; then
            echo "<7>stage-2-init: $line" > /dev/kmsg
        fi
    done) 2>&1
else
    mkdir -p /run/log
    exec > >(tee -i /run/log/stage-2-init.log) 2>&1
fi

# Create essential directories
install -m 0755 -d /etc
install -m 0755 -d /etc/nixos
install -m 01777 -d /tmp

# Source the stage2 mount script instead of early mount script
source @stage2MountScript@

# Run activation script
echo "running activation script..."
$systemConfig/activate

# Record boot configuration
ln -sfn "$systemConfig" /run/booted-system

# Run post-boot commands
@shell@ @postBootCommands@

# Reset logging
exec 1>&$logOutFd 2>&$logErrFd
exec {logOutFd}>&- {logErrFd}>&-

# Start init system
if [ "@USE_OPENRC@" = "1" ]; then
    echo "Starting OpenRC..."

    # Set up OpenRC environment
    export RC_SVCNAME=openrc
    export RC_SVCDIR=/run/openrc
    export RC_LIBEXECDIR=/lib/rc

    # Create required directories
    mkdir -p /run/openrc/started
    mkdir -p /run/openrc/{init.d,conf.d,runlevels}

    # Copy runtime config if provided
    if [ -n "@openrcRuntimeConfig@" ]; then
        cp "@openrcRuntimeConfig@" /run/openrc/rc.conf
        chmod 644 /run/openrc/rc.conf
    fi

    # Start OpenRC
    exec "@openrcPackage@/sbin/openrc-init"
else
    echo "Starting systemd..."
    exec "@systemdExecutable@"
fi
