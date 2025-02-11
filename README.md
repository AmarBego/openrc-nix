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
- [x] OpenRC init starts successfully
- [~] Service management working (partial functionality)
- [ ] System shutdown/reboot handling
- [ ] Complete systemd replacement

## Technical Approach

### 1. OpenRC Source Patches
*(pkgs/openrc)*

**openrc-nixos-paths.patch:**
- Adds `rootprefix` meson option for NixOS store path separation
- Restructures directory definitions to use rootprefix:
```bash
# Before
bindir = get_option('prefix') / get_option('bindir')
# After
rootprefix = get_option('prefix')
bindir = rootprefix / get_option('bindir')
```
- Enables proper path separation between build-time and runtime paths

**openrc-nixos-runlevels.patch:**
- Fixes runlevel symlink creation with DESTDIR
- Ensures correct path resolution during installation:
```bash
# Before
ln -snf "${init_d_dir}/$x" "${DESTDIR}${sysinitdir}/$x"
# After
ln -snf "${DESTDIR}${init_d_dir}/$x" "${DESTDIR}${sysinitdir}/$x"
```
- Critical for NixOS to maintain store path integrity
- Prevents broken symlinks in final package

**openrc-nixos-init.patch:**
- Replaces hardcoded paths with NixOS store references
- Fixes binary execution paths for NixOS FHS:
```c
// Before
execlp("openrc", "openrc", runlevel, NULL);
// After
execlp("@OPENRC@/bin/openrc", "openrc", runlevel, NULL);
```

**openrc-nixos-scripts.patch:**
- Adapts init scripts for NixOS directory structure
- Updates lock file locations and service dependencies:
```bash
# Changed lock path
-migrate_to_run /var/lock /run/lock
+migrate_to_run /var/lock /run/openrc/lock

# Fixed service dependency
-need localmount
+use localmount
```

### 2. Dedicated Initialization Module
*(nixos/modules/system/boot/openrc-init.nix)*

**Key Components:**
1. Runtime Configuration Generation:
```nix
runtimeConfig = pkgs.writeText "openrc-runtime-config" ''
  rc_basedir="/run/openrc"
  rc_runleveldir="/run/openrc/runlevels"
  rc_initdir="/run/openrc/init.d"
'';
```

2. Library Setup Script:
- Copies OpenRC libraries to `/lib`
- Generates ld.so.cache in writable storage
- Verifies library loading through debug checks

3. Runtime Environment Builder:
```bash
openrcRuntimeSetup = pkgs.writeScript "openrc-runtime-setup" ''
  # Create NixOS-compatible directory structure
  mkdir -p /run/openrc/{init.d,conf.d,rc/sh}

  # Set up core environment variables
  export PATH=${openrcPkg}/bin:${pkgs.coreutils}/bin:$PATH
  export LD_LIBRARY_PATH=${openrcPkg}/lib:$LD_LIBRARY_PATH

  # Install patched init scripts
  for script in ${openrcPkg}/share/openrc/init.d/*; do
    cp "$script" /run/openrc/init.d/
    sed -i "1s|#!/bin/sh|#!${pkgs.bash}/bin/bash|" "$target"
  done
'';
```

**Critical Functionality:**
- Creates writable OpenRC structure in `/run/openrc`
- Maintains compatibility symlinks to `/etc`
- Implements NixOS-specific runlevel definitions:
```bash
runlevel_services = {
  sysinit = ["devfs" "procfs" "sysfs" "dmesg"];
  boot = ["localmount" "hostname" "modules" "bootmisc"];
  default = ["local"];
};
```

### 3. Stage 2 Integration
*(nixos/modules/system/boot/stage-2.nix)*

**Changes:**
- Moved OpenRC initialization logic to dedicated module
- Added environment variables for NixOS paths:
```bash
export USE_OPENRC="1"
export openrcPackage="@openrcPackage@"
```
- Maintains compatibility with existing activation scripts

## Known Issues

### 1. Init Script Paths
Missing critical infrastructure scripts:
```bash
ERROR: cannot find /nix/store/...-openrc-0.52/libexec/rc/init.sh
ERROR: cannot find gendepends.sh in path
```
Proposed solution:
```bash
hardware.firmware = [ pkgs.openrc ];
environment.pathsToLink = ["/libexec/rc"];
```

### 2. Libexec Structure
OpenRC expects specific libexec layout:
```bash
# Temporary workaround in openrc-init.nix
ln -sf ${openrcPkg}/libexec/rc /run/openrc/rc
```

### 3. Service Dependency Generation
Missing gendepends.sh location:
```bash
boot.initrd.openrc.extraBin = {
  gendepends = "${pkgs.openrc}/libexec/rc/gendepends.sh";
};
```

## Current Status
OpenRC now successfully initializes and enters runlevels, but service startup is blocked by missing infrastructure scripts. Next steps:
- Fix libexec directory structure
- Resolve gendepends.sh path issues
- Finalize service dependency resolution
- Implement proper shutdown handling
