{ package, pkgs, lib }:
pkgs.writeScript "openrc-lib-setup" ''
#!${pkgs.bash}/bin/bash
set -x

echo "Setting up OpenRC libraries..."

# Create required directories
mkdir -p /lib /run/ldconfig

echo "OpenRC package path: ${package}"
echo "Contents of OpenRC lib directory:"
ls -la ${package}/lib/

# Copy all OpenRC libraries
echo "Copying OpenRC libraries..."
for lib in ${package}/lib/lib{einfo,rc}.so*; do
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
''
