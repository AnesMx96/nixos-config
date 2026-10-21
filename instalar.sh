#!/usr/bin/env bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/AnesMx96/nixos-config/main"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Ejecuta como root (este script instala NixOS en el disco virtual)." >&2
  exit 1
fi

if [[ ! -b /dev/sda ]]; then
  echo "No encuentro /dev/sda:" >&2
  lsblk >&2
  exit 1
fi

echo "=================================================="
echo " AVISO: este script BORRA /dev/sda (disco virtual)"
echo " y sobre el instala NixOS 25.11 + Hyprland/SDDM."
echo "=================================================="
read -rp "Pulsa ENTER para continuar... " _

if findmnt /mnt >/dev/null 2>&1; then
  umount /mnt || true
fi

parted -s /dev/sda mklabel msdos
parted -s /dev/sda mkpart primary ext4 1MiB 100%
parted -s /dev/sda set 1 boot on
partprobe /dev/sda || sleep 2

mkfs.ext4 -F -L nixos /dev/sda1
mount /dev/disk/by-label/nixos /mnt

nixos-generate-config --root /mnt

curl -fsSL -o /tmp/install.sh "$REPO/install.sh"
bash /tmp/install.sh -r /mnt

nixos-install

echo
echo "=================================================="
echo " INSTALACION COMPLETA. Ahora: reboot"
echo " (si pide quitar el medio, pulsa Intro en la VM)"
echo "=================================================="
