# NixOS OpenRC Experimental Fork

## Module Architecture

```text
nixos/
├── modules/
│   ├── services/
│   │   └── openrc/
│   │       ├── default.nix         # Main service
│   │       ├── library-setup.nix  # Library
│   │       ├── runtime.nix        # Runtime config
│   │       ├── runtime-setup.nix  # Runtime env
│   │       └── service-aggregation.nix # Service
│   └── system/
│       └── boot/
│           └── openrc-init.nix    # Core boot
```

### Key Technical Challenges

1. **Read-Only Store Compatibility**
   - Problem: OpenRC expects writable /etc/init.d
   - Solution: Symlink farm in /run/openrc with Nix store backing
   - Relevant Files: `service-aggregation.nix`, `runtime-setup.nix`

2. **Service Management**
   - Problem: systemd-style declarative services → OpenRC scripts
   - Solution: Nix-generated init scripts with dependency resolution
   - Relevant Files: `default.nix` (services.openrc options)

3. **Library Paths**
   - Problem: OpenRC binaries expect libraries in /lib
   - Solution: Copy libraries to /lib at runtime + ldconfig in writable store
   - Relevant Files: `library-setup.nix`

## Core Components

### 1. Runtime Environment (runtime-setup.nix)
```bash
# Creates writable OpenRC structure
mkdir -p /run/openrc/{init.d,conf.d,rc/sh,rc/bin}

# Critical environment variables
export RC_LIBEXECDIR=/run/openrc/rc
export PATH="${openrcPkg}/bin:${coreutils}/bin:$PATH"

# Init script patching
sed -i "1s|#!/bin/sh|#!${bash}/bin/bash|" "$target"
```

### 2. Service Aggregation (service-aggregation.nix)
```nix
# Aggregates services from Nix store
rsync -a ${openrcPkg}/etc/openrc/init.d/ $out/etc/openrc/init.d/

# User-defined services
install -Dm755 ${cfg.script} $out/etc/openrc/init.d/${name}
```

### 3. Library Initialization (library-setup.nix)
```bash
# Library copy from Nix store to /lib
cp -av ${package}/lib/lib{einfo,rc}.so* /lib/

# Writable ld.so.cache generation
TMPDIR=/run/ldconfig ldconfig -C /run/ldconfig/ld.so.cache
```

## Known Issues & Workarounds

### 1. Missing rc/sh Scripts
```text
* openrc: unable to exec `/nix/store/.../libexec/rc/sh/init.sh`: No such file or directory
* gendepends.sh: No such file or directory
```

**Root Cause:**
OpenRC hardcodes paths to its libexec scripts. The Nix build puts these in the store path, but OpenRC's init process looks for them in runtime paths.

**Workarounds:**
1. Add explicit symlinks in service aggregation:
```nix
# service-aggregation.nix
ln -s ${openrcPkg}/libexec/rc/sh/init.sh $out/etc/openrc/init.d/
ln -s ${openrcPkg}/libexec/rc/sh/gendepends.sh $out/etc/openrc/init.d/
```

2. Patch OpenRC source to use runtime paths:
```diff
# openrc-nixos-init.patch
- rc_confdir = "/libexec/rc";
+ rc_confdir = "/run/openrc/rc";
```

3. Add to runtime-setup.nix:
```bash
# Copy critical RC scripts to runtime directory
cp -v ${openrcPkg}/libexec/rc/sh/*.sh /run/openrc/rc/sh/
chmod 755 /run/openrc/rc/sh/*
```

### 2. Library Path Resolution
```text
ERROR: libeinfo.so.1: cannot open shared object file
```

**Workaround:**
Add explicit library cache regeneration step:
```nix
# library-setup.nix
echo "Force-regenerating library cache..."
LD_LIBRARY_PATH=/lib /run/current-system/sw/bin/ldconfig
```

### 3. Partial Boot Sequence
```text
Starting default runlevel... [hangs]
```

## Source Patches Overview
*(pkgs/openrc/)*

### 1. Path Structure Patch (`openrc-nixos-paths.patch`)
```diff
diff --git a/meson.build b/meson.build
+rootprefix = get_option('prefix')
-bindir = get_option('prefix') / get_option('bindir')
+bindir = rootprefix / get_option('bindir')
```
**Purpose:** Separates build-time paths from runtime paths using `rootprefix`
**Impact:** Enables Nix store path isolation while maintaining FHS compatibility

### 2. Runlevel Symlink Patch (`openrc-nixos-runlevels.patch`)
```diff
diff --git a/tools/meson_runlevels.sh b/tools/meson_runlevels.sh
-ln -snf "${init_d_dir}/$x" "${DESTDIR}${sysinitdir}/$x"
+ln -snf "${DESTDIR}${init_d_dir}/$x" "${DESTDIR}${sysinitdir}/$x"
```
**Purpose:** Fixes symlink creation with DESTDIR during installation
**Why Needed:** Prevents broken symlinks in final Nix package

### 3. Init Process Patch (`openrc-nixos-init.patch`)
```diff
diff --git a/src/openrc-init/openrc-init.c b/src/openrc-init/openrc-init.c
-execlp("openrc", "openrc", runlevel, NULL);
+execlp("@OPENRC@/bin/openrc", "openrc", runlevel, NULL);
```
**Purpose:** Hardcodes Nix store path for init process
**Critical For:** Stage 2 initialization reliability

### 4. Script Compatibility Patch (`openrc-nixos-scripts.patch`)
```diff
diff --git a/init.d/bootmisc.in b/init.d/bootmisc.in
-need localmount
+use localmount
-migrate_to_run /var/lock /run/lock
+migrate_to_run /var/lock /run/openrc/lock
```
**Purpose:** Adapts service scripts for NixOS directory structure
**Key Change:** Lock file relocation prevents conflicts

## Package Build Configuration
*(pkgs/openrc/default.nix)*

### Core Build Parameters
```nix
mesonFlags = [
  "-Drootprefix=${placeholder "out"}"
  "--localstatedir=/run/openrc"
  "-Dselinux=disabled"
  "-Dnewnet=false"
];
```

### Critical Build Steps
1. **Path Substitution:**
```nix
substituteInPlace src/openrc-init/openrc-init.c \
  --replace "@PATH@" "${lib.makeBinPath [ coreutils bash ]}" \
  --replace "@OPENRC@" "$out"
```

2. **Library Installation:**
```bash
# Install OpenRC libraries with versioned symlinks
install -Dm755 "$libfile" "$out/lib/$(basename $libfile)"
ln -sf "$(basename $libfile)" "$out/lib/$base_libname.so"
```

3. **Runtime Directory Setup:**
```nix
postInstall = ''
  mkdir -p $out/{bin,sbin,lib,libexec/rc/{bin,sh}}
  install -Dm644 sh/functions.sh $out/libexec/rc/sh/functions.sh
'';
```

## Debugging Patch Effects

### Verify Applied Patches
```bash
nix-store --query --references $(which openrc) | grep openrc
nix-shell -p patchelf --run "patchelf --print-rpath ${pkgs.openrc}/lib/lib*"
```

### Test Symlink Resolution
```bash
# In NixOS VM:
ls -l /run/openrc/init.d/functions.sh
readlink /etc/init.d/functions.sh
```

### Patch Development Workflow
1. Modify patch files in `pkgs/openrc/`
2. Rebuild with debug symbols:
```bash
nix-build -E 'with import <nixpkgs> {}; openrc.overrideAttrs (o: {
  NIX_CFLAGS_COMPILE = "-O0 -g";
  patches = [ ./patches/new-patch.patch ];
})'
```

## Critical Path Analysis

### Patch Dependency Chain
1. `openrc-nixos-paths.patch` → Meson configuration
2. `openrc-nixos-runlevels.patch` → Runlevel setup
3. `openrc-nixos-init.patch` → Init process execution
4. `openrc-nixos-scripts.patch` → Service compatibility

### Build Artifact Validation
```bash
# Verify library presence
ls -l ${pkgs.openrc}/lib/lib{einfo,rc}.so*

# Check init script paths
grep -r '/run/openrc' ${pkgs.openrc}/share/openrc/init.d/
```

## Integration Points

### NixOS Overrides
```nix
# In system configuration
boot.initrd.systemd.enable = false;
boot.initrd.openrc.enable = true;
services.openrc.enable = true;
```

### Activation Hooks
```nix
# default.nix
system.activationScripts.openrc = ''
  ${openrcPkg}/bin/rc-update -u
'';
```

## Contributor Access Points

1. **Service Dependency Resolution**
   - File: `service-aggregation.nix`
   - Key Function: Service ordering in runlevels

2. **Init Script Compatibility**
   - File: `runtime-setup.nix`
   - Key Function: Script patching logic

3. **Boot Process Integration**
   - File: `system/boot/openrc-init.nix`
   - Key Function: Stage 2 initialization
