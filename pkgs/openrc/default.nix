{ stdenv, lib, fetchFromGitHub, meson, ninja, pkg-config, audit, libcap, pam, coreutils, bash }:

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
    ./openrc-nixos-init.patch
    ./openrc-nixos-scripts.patch
  ];

  postPatch = ''
  substituteInPlace src/openrc-init/openrc-init.c \
    --replace "@PATH@" "${lib.makeBinPath [ coreutils bash ]}" \
    --replace "@OPENRC@" "$out"
  '';

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
    echo "=== Starting OpenRC Post-Install ==="

    # Create directory structure
    mkdir -p $out/{bin,sbin,lib,libexec/rc/{bin,sh}}

    # Install OpenRC libraries with proper permissions and symlinks
    echo "=== Building and Installing Libraries ==="

    # First ensure the libraries are built
    for libname in libeinfo librc; do
      if [ -d "build/src/$libname" ]; then
        echo "Building $libname..."
        cd "build/src/$libname"
        make
        cd ../../..
      else
        echo "Warning: Source directory for $libname not found"
        find . -name "$libname*"
      fi
    done

    # Now install the libraries
    for libname in libeinfo librc; do
      # Try multiple possible locations
      for searchdir in "build/src/$libname" "src/$libname" "lib/$libname"; do
        if [ -d "$searchdir" ]; then
          echo "Searching in $searchdir for $libname..."
          find "$searchdir" -type f -name "*.so*" -print

          for libfile in $(find "$searchdir" -type f -name "*.so*"); do
            echo "Installing $libfile to $out/lib/"
            install -Dm755 "$libfile" "$out/lib/$(basename $libfile)"

            # Create .so symlink if this is the .so.X version
            if [[ "$(basename $libfile)" =~ \.so\.[0-9]+$ ]]; then
              base_libname=$(basename "$libfile" | sed 's/\.so\.[0-9]\+$//')
              echo "Creating symlink $out/lib/$base_libname.so -> $(basename $libfile)"
              ln -sf "$(basename $libfile)" "$out/lib/$base_libname.so"
            fi
          done
        fi
      done
    done

    # Verify library installation
    echo "=== Library Verification ==="
    echo "Contents of $out/lib:"
    ls -la $out/lib/

    # Test library loading
    echo "Testing library loading:"
    for lib in $out/lib/*.so*; do
      echo "Testing $lib:"
      LD_LIBRARY_PATH=$out/lib ldd "$lib" || true
    done

    echo "=== Installing OpenRC Binaries ==="

    # Debug: Show source directory structure
    echo "Source directory contents:"
    ls -R

    # Debug: Find all potential openrc binaries
    echo "Searching for openrc binary:"
    find . -type f -name "openrc" -o -name "rc"

    # First install the core openrc binary since others link to it
    found=0
    for dir in build/src/rc src/rc build/rc build; do
      for binary in openrc rc; do
        if [ -f "$dir/$binary" ]; then
          echo "Found core binary at $dir/$binary"
          install -Dm755 "$dir/$binary" "$out/sbin/openrc"
          install -Dm755 "$dir/$binary" "$out/bin/openrc"
          found=1
          break 2
        fi
      done
    done

    # Try searching in build directory if not found
    if [ $found -eq 0 ]; then
      echo "Searching build directory for openrc binary..."
      if openrc_bin=$(find . -type f -name "openrc" | head -n1); then
        if [ -n "$openrc_bin" ]; then
          echo "Found openrc at: $openrc_bin"
          install -Dm755 "$openrc_bin" "$out/sbin/openrc"
          install -Dm755 "$openrc_bin" "$out/bin/openrc"
          found=1
        fi
      fi
    fi

    # Verify core binary installation
    if [ ! -f "$out/sbin/openrc" ]; then
      echo "ERROR: Failed to install core openrc binary!"
      echo "Current directory: $(pwd)"
      echo "Directory contents:"
      ls -la
      echo "Build directory contents:"
      ls -la build/ || true
      echo "Build/src contents:"
      ls -la build/src/ || true
      exit 1
    fi

    # Now create openrc-run symlink
    echo "Creating openrc-run symlink..."
    ln -sf openrc "$out/sbin/openrc-run"
    ln -sf openrc "$out/bin/openrc-run"

    # Install other binaries
    for binary in rc rc-service rc-status rc-update start-stop-daemon openrc-init; do
      found=0
      for dir in build/src/rc src/rc build/src/"$binary" src/"$binary" bin sbin; do
        for name in "$binary" "openrc-$binary"; do
          if [ -f "$dir/$name" ]; then
            echo "Installing $binary..."
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

    # Install support files
    echo "=== Installing Support Files ==="

    # Install shell functions
    if [ -f "sh/functions.sh" ]; then
      install -Dm644 sh/functions.sh $out/libexec/rc/sh/functions.sh
    fi

    # Copy init scripts and configs with error handling
    echo "Installing init scripts and configs..."
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
    echo "Creating default configuration..."
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

    echo "=== Final Verification ==="

    # Verify binary installation
    echo "Binary locations:"
    echo "Contents of $out/sbin:"
    ls -la $out/sbin/
    echo "Contents of $out/bin:"
    ls -la $out/bin/

    # Test openrc-run symlink
    if [ -L "$out/sbin/openrc-run" ]; then
      echo "Verifying openrc-run symlink:"
      ls -la "$out/sbin/openrc-run"
      target=$(readlink "$out/sbin/openrc-run")
      if [ -f "$out/sbin/$target" ]; then
        echo "openrc-run symlink target exists"
      else
        echo "ERROR: openrc-run symlink target missing!"
        exit 1
      fi
    else
      echo "ERROR: openrc-run symlink missing!"
      exit 1
    fi

    # Show final directory structure
    echo "=== Final Directory Structure ==="
    echo "bin directory:"
    ls -la $out/bin/
    echo "lib directory:"
    ls -la $out/lib/
    echo "libexec/rc/bin directory:"
    ls -la $out/libexec/rc/bin/
    echo "share/openrc directory:"
    ls -la $out/share/openrc/

    echo "=== OpenRC Post-Install Complete ==="
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
