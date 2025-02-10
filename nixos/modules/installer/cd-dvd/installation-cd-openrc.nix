# This module defines a NixOS installation CD with OpenRC instead of systemd.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./installation-cd-base.nix
    ../../system/boot/openrc-init.nix
  ];

  # Enable OpenRC and disable systemd
  boot.initrd.openrc.enable = true;
  boot.initrd.systemd.enable = false;

  # Hardware support
  hardware.enableRedistributableFirmware = lib.mkDefault true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # ISO image configuration
  isoImage.edition = "openrc";
  isoImage.volumeID = "NIXOS_OPENRC";

  # Add some useful packages for installation
  environment.systemPackages = with pkgs; [
    # Basic system utilities
    vim
    curl
    wget
    htop
    pciutils
    usbutils

    # Networking tools
    iproute2
    nettools
    wirelesstools

    # Disk utilities
    gparted
    parted
    gptfdisk

    # File system tools
    dosfstools
    e2fsprogs
    btrfs-progs
    xfsprogs
  ];

  # Allow unfree firmware needed for ISO boot
  nixpkgs.config.allowUnfree = true;

  # Add common kernel modules
  boot.initrd.availableKernelModules = [
    "ahci"
    "sd_mod"
    "sr_mod"
    "uas"
    "usbhid"
    "usb_storage"
    "virtio_pci"
    "virtio_scsi"
  ];

  # System configuration
  system.stateVersion = lib.mkDefault lib.trivial.release;
}
