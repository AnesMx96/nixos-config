#!/usr/bin/env bash
set -euo pipefail

COPY_ONLY=0

usage() {
  cat <<'USAGE'
Uso: install.sh [opciones]

  -c, --copy-only   solo copia configuration.nix a /etc/nixos (sin nixos-rebuild)
  -h, --help        muestra esta ayuda

Descarga directa:
  curl -fsSL https://raw.githubusercontent.com/AnesMx96/nixos-config/main/install.sh | bash
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -c|--copy-only) COPY_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opcion desconocida: $arg" >&2; usage; exit 1 ;;
  esac
done

prompt() {
  local msg="$1" var=""
  if { exec 3</dev/tty; } 2>/dev/null; then
    read -rp "$msg" var <&3 || true
    exec 3<&- || true
  else
    read -rp "$msg" var || true
  fi
  printf '%s' "$var"
}

valid_name() {
  [[ "$1" =~ ^[a-z0-9_][a-z0-9_-]*$ ]]
}

NAME="$(prompt 'Tu nombre de usuario: ')"
if ! valid_name "$NAME"; then
  echo "Nombre no valido: '$NAME' (solo minusculas, digitos, '_' o '-')." >&2
  exit 1
fi

HOST="$(prompt 'Nombre del equipo [nixos]: ')"
HOST="${HOST:-nixos}"
if ! valid_name "$HOST"; then
  echo "Nombre de equipo no valido: '$HOST'" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<'NIX'
{ config, pkgs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "__HOST__";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  time.timeZone = "Europe/Madrid";
  i18n.defaultLocale = "es_ES.UTF-8";
  console.keyMap = "es";
  services.xserver.xkb = {
    layout = "es";
    variant = "";
  };

  users.users."__USER__" = {
    isNormalUser = true;
    description = "__USER__";
    extraGroups = [ "wheel" ];
    initialPassword = "nixos";
  };

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  hardware.graphics.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  environment.systemPackages = with pkgs; [
    git
    python3
    firefox
    wget
    curl
  ];

  system.stateVersion = "25.11";
}
NIX

sed -i "s|__USER__|$NAME|g; s|__HOST__|$HOST|g" "$TMP"

if [[ ! -d /etc/nixos ]]; then
  echo "No existe /etc/nixos: ejecuta este script dentro de NixOS." >&2
  exit 1
fi

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
fi

if [[ -f /etc/nixos/configuration.nix ]]; then
  BAK="/etc/nixos/configuration.nix.bak.$(date +%Y%m%d-%H%M%S)"
  echo "Respaldando configuracion actual -> $BAK"
  $SUDO cp /etc/nixos/configuration.nix "$BAK"
fi

$SUDO cp "$TMP" /etc/nixos/configuration.nix
echo "configuration.nix instalado (usuario: $NAME, equipo: $HOST)."
echo "Contrasena inicial: nixos  (cambiala despues con: passwd)"

if [[ "$COPY_ONLY" -eq 1 ]]; then
  echo "Modo --copy-only: no se ejecuta nixos-rebuild."
  exit 0
fi

echo "Aplicando con nixos-rebuild switch..."
$SUDO nixos-rebuild switch
