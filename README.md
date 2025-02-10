# NixOS OpenRC Experimental Fork

## Objective
Implement OpenRC as alternative init system while maintaining NixOS principles. Key challenges:
- Adapt OpenRC to read-only Nix store
- Replace systemd's service management
- Handle Nix-specific path requirements

## Current Progress
- [x] OpenRC package builds successfully with NixOS paths
- [x] Stage-1 boot completes successfully
- [x] Transition to Stage-2 works
- [x] Runtime directories created correctly
- [x] OpenRC libraries copied to /lib
- [x] Library cache updated in writable location
- [x] Runtime configuration installed
- [ ] OpenRC init starts successfully (blocked by library loading)
- [ ] Service management working
- [ ] System shutdown/reboot handling
- [ ] Complete systemd replacement

## Technical Approach

### 1. OpenRC Package Modifications
*(pkgs/openrc/default.nix)*

**Build System Adjustments:**
- Added `rootprefix` meson option for NixOS paths
- Patched meson.build to use `@rootprefix@` instead of hardcoded paths
```meson
# Before
bindir = get_option('prefix') / get_option('bindir')
# After
bindir = rootprefix / get_option('bindir')
```

**Library Handling:**
- Explicitly copy .so files during installPhase
- Set RPATH in NIX_LDFLAGS:
```nix
NIX_LDFLAGS = "-rpath ${placeholder "out"}/lib";
```

**Critical Patches:**
- `openrc-nixos-paths.patch`: Rewrites hardcoded paths to NixOS equivalents
- `openrc-nixos-runlevels.patch`: Fixes symlink creation with DESTDIR

### 2. NixOS Service Integration
*(nixos/modules/services/openrc.nix)*

**Service Aggregation:**
```nix
openrcServices = pkgs.runCommand "openrc-services" {
  # Combines core services with user-defined ones
  nativeBuildInputs = [ pkgs.rsync ];
} ''
  mkdir -p $out/etc/openrc/{init.d,conf.d}
  # Merge package services and custom services
  ${lib.concatStrings (lib.mapAttrsToList installService config.services.openrc.services)}
'';
```

**Activation Scripts:**
- Creates runtime directories in /run/openrc
- Symlinks store paths to expected locations:
```bash
ln -sfn ${openrcServices}/etc/openrc/init.d /etc/init.d
```

### 3. Stage 2 Initialization
*(nixos/modules/system/boot/stage-2.nix)*

**Library Setup:**
```nix
openrcLibSetup = pkgs.writeScript "openrc-lib-setup" ''
  mkdir -p /lib /run/ldconfig

  # Copy OpenRC libraries
  cp -av ${openrcPkg}/lib/lib{einfo,rc}.so* /lib/

  # Update library cache with writable temp directory
  TMPDIR=/run/ldconfig ldconfig -C /run/ldconfig/ld.so.cache /lib
  cp -av /run/ldconfig/ld.so.cache /etc/ld.so.cache
'';
```

**Environment Preparation:**
```nix
runtimeConfig = pkgs.writeText "openrc-runtime-config" ''
  rc_sys=""
  rc_controller_cgroups="NO"
  rc_depend_strict="YES"
  rc_logger="YES"
  rc_shell=/bin/sh
  rc_basedir="/run/openrc"
  rc_runleveldir="/run/openrc/runlevels"
'';
```

**Init Switching:**
```bash
if [ "@USE_OPENRC@" = "1" ]; then
  exec "@openrcPackage@/bin/openrc-init"
fi
```

## Known Issues

### 1. Library Resolution
Boot process now reaches stage-2 but fails when executing openrc-init:
```
openrc-init: error while loading shared libraries: libeinfo.so.1: cannot open shared object file: No such file or directory
```
Current debugging steps:
- Libraries are copied to /lib
- ldconfig cache is updated in writable location
- LD_LIBRARY_PATH includes OpenRC library path

### 2. Service Dependency Handling
Missing NixOS->OpenRC service translation layer. Current approach:
```nix
services.openrc.services = {
  network = {
    script = "${pkgs.dhcpcd}/bin/dhcpcd";
    runlevels = [ "default" ];
  };
};
```

### 3. Cgroups Integration
OpenRC's cgroup support requires patching for NixOS's cgroup v2 layout:
```nix
hardware.cgroup.enable = true;
boot.initrd.openrc.extraConfig = "rc_cgroup_mode=\"unified\"";
```

## Building & Testing

```bash
# Build OpenRC-enabled system
nix-build -A config.system.build.isoImage -I nixpkgs=. nixos/release.nix

# Test in QEMU
qemu-kvm -cdrom ./result/iso/nixos-*.iso -m 4096
```

## Current Status
Successfully transitions from stage-1 to stage-2, but fails during OpenRC initialization due to library loading issues. Next steps:
- Debug library loading in stage-2
- Verify library paths and permissions
- Check dynamic linker configuration
