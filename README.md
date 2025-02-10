
# NixOS OpenRC Experimental Fork

## Objective
Implement OpenRC as alternative init system while maintaining NixOS principles. Key challenges:
- Adapt OpenRC to read-only Nix store
- Replace systemd's service management
- Handle Nix-specific path requirements

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

### 3. Initramfs Integration
*(nixos/modules/system/boot/openrc-init.nix)*

**Initrd Setup:**
- Copies OpenRC binaries and libraries to initrd:
```nix
copy_bin_and_libs ${config.boot.initrd.openrc.package}/bin/openrc-init
```
- Creates minimal runtime environment:
```bash
mkdir -p /run/openrc/{init.d,conf.d,runlevels,started}
```

**Current Stage 1 Failure:**
Library resolution fails despite:
```nix
# Explicit library copying in extraUtilsCommands
for libfile in ${openrcPkg}/lib/libeinfo.so*; do
  copy_bin_and_libs "$libfile"
done
```
Error manifests as:
```
openrc-init: error while loading shared libraries: libeinfo.so.1: cannot open shared object file
```

### 4. Stage 2 Initialization
*(nixos/modules/system/boot/stage-2.nix)*

**Environment Preparation:**
- Sets up OpenRC-specific paths:
```nix
runtimeConfig = pkgs.writeText "openrc-runtime-config" ''
  rc_basedir="/run/openrc"
  rc_runleveldir="/run/openrc/runlevels"
'';
```

**Init Switching:**
```bash
if [ "@USE_OPENRC@" = "1" ]; then
  exec "@openrcPackage@/sbin/openrc-init"
fi
```

## Known Issues

### 1. Stage 1 Library Resolution
Despite explicit copying in `extraUtilsCommands`, initrd fails to find libeinfo.so.1. Debugging steps:

- Verified library exists in initrd's /lib
- Checked ELF dependencies:
```bash
ldd /nix/store/...-extra-utils/bin/openrc-init
    libeinfo.so.1 => not found
```
- Suspected issue: initrd's ld cache not updated

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

# Inspect initrd contents
nix-build -A config.system.build.initialRamdisk -I nixpkgs=.
ls result/initrd | grep -E 'libeinfo|openrc'

# Test in QEMU
qemu-kvm -cdrom ./result/iso/nixos-*.iso -m 4096
```

## Contribution Notes

This fork demonstrates several non-standard patterns:
1. **Path Remapping:** Overriding meson's prefix handling
2. **Initrd Library Injection:** Manual library copying vs Nix auto-detection
3. **Service Translation:** Ad-hoc conversion of NixOS services to OpenRC scripts

Current priority: Fix Stage 1 library loading through:
- LD_LIBRARY_PATH injection
- patchelf adjustments
- Initrd ldconfig execution
