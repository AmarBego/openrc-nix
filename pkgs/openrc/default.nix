{ stdenv, lib, fetchFromGitHub, meson, ninja, pkg-config, audit, libcap, pam }:

stdenv.mkDerivation rec {
  pname = "openrc";
  version = "0.56";

  src = fetchFromGitHub {
    owner = "OpenRC";
    repo = "openrc";
    rev = version;
    sha256 = "03rmy06mn1xdw2lsicpz1wxs8qdfp77lcfcj1kcjgfsfz07vhsp1";
  };

  patches = [
    ./openrc-nixos-paths.patch
    ./openrc-nixos-runlevels.patch
  ];

  nativeBuildInputs = [ meson ninja pkg-config ];
  buildInputs = [ audit libcap pam ];

  # Set DESTDIR for meson_runlevels.sh
  DESTDIR = placeholder "out";

  mesonFlags = [
    "-Drootprefix=${placeholder "out"}"
    "--prefix=${placeholder "out"}"
    "--sysconfdir=/etc"
    "--libexecdir=${placeholder "out"}/libexec"
    "--localstatedir=/run/openrc"
    "-Dpam=true"
    "-Daudit=enabled"
    "-Dselinux=disabled"
    "-Dnewnet=false"
    "-Dsysvinit=false"
    "--buildtype=release"
  ];

  # Prevent the runlevels script from trying to create system directories
  preConfigure = ''
    substituteInPlace tools/meson_runlevels.sh \
      --replace 'mkdir -p "$DESTDIR$3"' 'mkdir -p "$3"' \
      --replace 'mkdir -p "$DESTDIR$4"' 'mkdir -p "$4"'
  '';

  # First apply patches to source files
  prePatch = ''
    # Debug: Show source directory structure
    echo "Source directory contents:"
    ls -R

    # Adjust hardcoded paths in source files
    for file in src/rc/*.c; do
      if [ -f "$file" ]; then
        substituteInPlace "$file" \
          --replace "/etc/rc.conf" "/run/openrc/rc.conf" \
          --replace "/etc/conf.d" "/run/openrc/conf.d" \
          --replace "/etc/init.d" "/run/openrc/init.d" \
          --replace "/etc/runlevels" "/run/openrc/runlevels"
      fi
    done
  '';

  preBuild = ''
    echo "=== Build Directory Structure ==="
    find . -type f -name "rc" -o -name "openrc"
  '';

  postInstall = ''
    # Create directory structure
    mkdir -p $out/{bin,lib,libexec/rc/{bin,sh}}  # Added lib directory
    mkdir -p $out/share/openrc/{init.d,conf.d,runlevels/{boot,sysinit,default,nonetwork,shutdown}}

    # Install OpenRC libraries with proper permissions and symlinks
    for libname in libeinfo librc; do
      # Find and install the versioned library
      for libpath in build/src/lib"$libname"/lib"$libname".so*; do
        if [ -f "$libpath" ]; then
          echo "Installing library: $libpath"
          install -Dm755 "$libpath" "$out/lib/$(basename $libpath)"

          # Create .so symlink if this is the .so.X version
          if [[ "$libpath" =~ \.so\.[0-9]+$ ]]; then
            ln -sf "$(basename $libpath)" "$out/lib/$libname.so"
          fi
        fi
      done
    done

    # Verify library installation
    echo "=== Library Verification ==="
    ls -la $out/lib/
    for binary in $out/bin/*; do
      echo "Checking dependencies for $(basename $binary):"
      ldd "$binary" || true
    done

    # First handle the rc binary specifically since it's special
    for rcpath in build/src/rc/openrc build/src/rc/rc src/rc/openrc src/rc/rc; do
      if [ -f "$rcpath" ]; then
        install -Dm755 "$rcpath" "$out/bin/rc"
        install -Dm755 "$rcpath" "$out/libexec/rc/bin/rc"
        break
      fi
    done

    # If rc still isn't installed, try to find it
    if [ ! -f "$out/bin/rc" ]; then
      echo "Searching for rc binary..."
      if rcfile=$(find . -type f -name "openrc" -o -name "rc" | grep -E "/(rc|openrc)$" | head -n1); then
        echo "Found rc at: $rcfile"
        install -Dm755 "$rcfile" "$out/bin/rc"
        install -Dm755 "$rcfile" "$out/libexec/rc/bin/rc"
      else
        echo "Error: Could not find rc binary"
        exit 1
      fi
    fi

    # Copy binaries from build directory to final locations
    for binary in openrc-init rc rc-service rc-status rc-update start-stop-daemon; do
      # Try multiple possible locations with multiple possible names
      found=0
      for dir in . src/rc src/"$binary" bin sbin build/src/rc build/src/"$binary"; do
        # Try both the binary name and openrc-$binary
        for name in "$binary" "openrc-$binary"; do
          if [ -f "$dir/$name" ]; then
            install -Dm755 "$dir/$name" "$out/bin/$binary"
            install -Dm755 "$dir/$name" "$out/libexec/rc/bin/$binary"
            found=1
            break 2
          fi
        done
      done

      if [ $found -eq 0 ]; then
        echo "Warning: Binary $binary not found in expected locations"
        echo "Searching entire build directory for $binary:"
        find . -type f -name "$binary" -o -name "openrc-$binary"
      fi
    done

    # Special handling for rc binary
    if [ ! -f "$out/bin/rc" ] && [ -f "build/src/rc/openrc" ]; then
      install -Dm755 build/src/rc/openrc "$out/bin/rc"
      install -Dm755 build/src/rc/openrc "$out/libexec/rc/bin/rc"
    fi

    # Install support files
    if [ -f "sh/functions.sh" ]; then
      install -Dm644 sh/functions.sh $out/libexec/rc/sh/functions.sh
    fi

    # Copy init scripts and configs with error handling
    for dir in init.d conf.d etc/conf.d; do
      if [ -d "$dir" ]; then
        echo "Processing directory: $dir"
        for file in "$dir"/*; do
          if [ -f "$file" ]; then
            basename=$(basename "$file")
            case "$dir" in
              *init.d)
                install -Dm755 "$file" "$out/share/openrc/init.d/$basename"
                ;;
              *conf.d)
                install -Dm644 "$file" "$out/share/openrc/conf.d/$basename"
                ;;
            esac
          fi
        done
      fi
    done

    # Make init scripts executable
    find $out/share/openrc/init.d -type f -exec chmod +x {} +

    # Create default configuration
    cat > $out/share/openrc/rc.conf << EOF
    rc_sys=""
    rc_controller_cgroups="NO"
    rc_depend_strict="YES"
    rc_logger="YES"
    rc_shell=/bin/sh

    # Runtime directories
    rc_basedir="/run/openrc"
    rc_runleveldir="/run/openrc/runlevels"
    rc_initdir="/run/openrc/init.d"
    rc_confdir="/run/openrc/conf.d"
    EOF

    # Add library check to debug output
    echo "=== Final Directory Structure ==="
    echo "bin directory:"
    ls -la $out/bin/
    echo "lib directory:"  # Added lib directory listing
    ls -la $out/lib/
    echo "libexec/rc/bin directory:"
    ls -la $out/libexec/rc/bin/
    echo "share/openrc directory:"
    ls -la $out/share/openrc/
  '';

  # Add runtime library path
  NIX_LDFLAGS = "-rpath ${placeholder "out"}/lib";

  passthru = {
    services = builtins.attrNames (builtins.readDir "${src}/init.d");
    inherit version;
  };

  meta = {
    description = "OpenRC init system configured for NixOS";
    homepage = "https://github.com/OpenRC/openrc";
    license = lib.licenses.bsd2;
    platforms = lib.platforms.linux;
    maintainers = [];
  };
}
