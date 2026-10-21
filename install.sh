#!/usr/bin/env bash
set -euo pipefail

COPY_ONLY=0
ROOT=""

usage() {
  cat <<'USAGE'
Uso: install.sh [opciones]

  -c, --copy-only     solo copia la configuracion (sin nixos-rebuild)
  -r, --root DIR      preparar un sistema ya montado (ej: -r /mnt tras
                      nixos-generate-config); no ejecuta nixos-rebuild
  -h, --help          muestra esta ayuda

Si $ROOT/etc/nixos/configuration.nix existe (instalacion normal), el monto se
importa con `imports` sin tocar fileSystems ni el usuario del instalador.
Si no existe, se usa como configuracion completa (detecta EFI/BIOS,
VirtualBox y stateVersion).

Descarga directa (sobre el sistema instalado):
  curl -fsSL https://raw.githubusercontent.com/AnesMx96/nixos-config/main/install.sh | bash

Instalacion por consola (desde el live, en una TTY con root):
  curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/AnesMx96/nixos-config/main/install.sh
  bash /tmp/install.sh -r /mnt
  nixos-install
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--copy-only) COPY_ONLY=1 ;;
    -r|--root)
      if [[ "${2:-}" == "" ]]; then echo "--root requiere un directorio" >&2; exit 1; fi
      ROOT="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; usage; exit 1 ;;
  esac
  shift
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

NAME="$(prompt 'Tu nombre de usuario (el que creaste en el instalador): ')"
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

STATE="25.11"
if [[ -r /etc/os-release ]]; then
  VID="$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2- | tr -d '"' || true)"
  CAND="$(echo "$VID" | cut -d. -f1,2)"
  if [[ "$CAND" =~ ^[0-9]+\.[0-9]+$ ]]; then
    STATE="$CAND"
  fi
fi

if [[ -d /sys/firmware/efi ]]; then
  BOOTLOADER='boot.loader.systemd-boot.enable = true;\n  boot.loader.efi.canTouchEfiVariables = true;'
else
  BOOTLOADER='boot.loader.grub.enable = true;\n  boot.loader.grub.device = "/dev/sda";'
fi

VBOX=""
if [[ "$(systemd-detect-virt 2>/dev/null || true)" == "oracle" ]]; then
  VBOX='virtualisation.virtualbox.guest.enable = true;'
fi

echo "Usuario: $NAME | Equipo: $HOST | stateVersion: $STATE"
echo "Arranque: $([[ -d /sys/firmware/efi ]] && echo 'EFI (systemd-boot)' || echo 'BIOS (GRUB)') | VirtualBox: $([[ -n "$VBOX" ]] && echo si || echo no)"

ETC="$ROOT/etc/nixos"
if [[ -n "$ROOT" ]]; then
  DOTHOME="$ROOT/home/$NAME"
  echo "Modo --root: preparando el sistema montado en $ROOT (nixos-rebuild no se ejecuta)"
else
  DOTHOME="$HOME"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<'NIX'
{ config, pkgs, lib, ... }:

{
  __BOOTLOADER__

  networking.hostName = lib.mkForce "__HOST__";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  time.timeZone = lib.mkForce "Europe/Madrid";
  i18n.defaultLocale = lib.mkForce "es_ES.UTF-8";
  console.keyMap = lib.mkForce "es";
  services.xserver.xkb = lib.mkForce {
    layout = "es";
    variant = "";
  };

  users.users."__USER__" = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "nixos";
  };

  services.displayManager.gdm.enable = false;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  hardware.graphics.enable = true;

  __VBOX__

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

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-emoji
    jetbrains-mono
  ];

  environment.systemPackages = with pkgs; [
    git
    python3
    firefox
    wget
    curl
    foot
    wofi
    waybar
    pavucontrol
    grim
    slurp
    wl-clipboard
  ];

  system.stateVersion = "__STATE__";
}
NIX

sed -i \
  -e "s|__USER__|$NAME|g" \
  -e "s|__HOST__|$HOST|g" \
  -e "s|__STATE__|$STATE|g" \
  -e "s|__BOOTLOADER__|$BOOTLOADER|" \
  -e "s|__VBOX__|$VBOX|" \
  "$TMP"

if [[ ! -d "$ETC" ]]; then
  echo "No existe $ETC: ejecuta nixos-generate-config --root <dir> primero." >&2
  exit 1
fi

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
fi

if [[ -f "$ETC/configuration.nix" ]]; then
  BAK="$ETC/configuration.nix.bak.$(date +%Y%m%d-%H%M%S)"
  echo "Respaldando configuracion actual -> $BAK"
  $SUDO cp "$ETC/configuration.nix" "$BAK"
  $SUDO cp "$TMP" "$ETC/hyprland-desktop.nix"
  if ! grep -q 'hyprland-desktop.nix' "$ETC/configuration.nix"; then
    $SUDO sed -i '0,/^{$/s|^{$|{\n  imports = [ ./hyprland-desktop.nix ];|' "$ETC/configuration.nix"
  fi
  echo "Montado en $ETC/hyprland-desktop.nix (imports anadido, fileSystems y usuario intactos)."
else
  $SUDO cp "$TMP" "$ETC/configuration.nix"
  echo "configuration.nix instalado en $ETC (modo completo, sin config previa)."
fi

echo "Contrasena inicial del usuario: nixos  (cambiala despues con: passwd)"

mkdir -p "$DOTHOME/.config/hypr" "$DOTHOME/.config/waybar"

if [[ ! -f "$DOTHOME/.config/hypr/hyprland.conf" ]]; then
  cat > "$HOME/.config/hypr/hyprland.conf" <<'HYPR'
monitor = ,preferred,auto,1

$terminal = foot
$menu = wofi --show drun

exec-once = waybar
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP

env = XCURSOR_SIZE,24
env = QT_QPA_PLATFORM,wayland

input {
    kb_layout = es
    follow_mouse = 1
}

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(89b4faff) rgba(74c7ecff) 45deg
    col.inactive_border = rgba(585b70aa)
}

decoration {
    rounding = 8
    blur {
        enabled = true
    }
}

animations {
    enabled = true
}

dwindle {
    pseudotile = true
}

misc {
    force_default_wallpaper = 0
}

bind = SUPER, Q, exec, $terminal
bind = SUPER, D, exec, $menu
bind = SUPER, C, killactive,
bind = SUPER, M, exit,
bind = SUPER, V, togglefloating,
bind = SUPER, P, pseudo,
bind = SUPER, J, togglesplit,
bind = SUPER, S, exec, grim -g "$(slurp)" - | wl-copy
bind = ALT, Tab, cyclenext
bind = SUPER, left, movefocus, l
bind = SUPER, right, movefocus, r
bind = SUPER, up, movefocus, u
bind = SUPER, down, movefocus, d
bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
bind = SUPER, 3, workspace, 3
bind = SUPER, 4, workspace, 4
bind = SUPER, 5, workspace, 5
bind = SUPER SHIFT, 1, movetoworkspace, 1
bind = SUPER SHIFT, 2, movetoworkspace, 2
bind = SUPER SHIFT, 3, movetoworkspace, 3
bind = SUPER SHIFT, 4, movetoworkspace, 4
bind = SUPER SHIFT, 5, movetoworkspace, 5

bindm = SUPER, mouse:272, movewindow
bindm = SUPER, mouse:273, resizewindow
HYPR
  echo "Hyprland: escrito ~/.config/hypr/hyprland.conf"
fi

if [[ ! -f "$DOTHOME/.config/waybar/config" ]]; then
  cat > "$HOME/.config/waybar/config" <<'WB'
{
  "layer": "top",
  "position": "top",
  "height": 30,
  "modules-left": ["hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["network", "pulseaudio", "tray"],
  "hyprland/workspaces": {
    "format": "{name}"
  },
  "clock": {
    "format": "{:%H:%M  %d/%m}"
  },
  "network": {
    "format-wifi": "wifi {signalStrength}%",
    "format-ethernet": "eth",
    "format-disconnected": "offline"
  },
  "pulseaudio": {
    "format": "vol {volume}%"
  },
  "tray": {}
}
WB
  cat > "$HOME/.config/waybar/style.css" <<'CSS'
* {
    font-family: jetbrains-mono, noto-fonts;
    font-size: 13px;
}

window#waybar {
    background: rgba(30, 30, 46, 0.9);
    color: #cdd6f4;
}

#workspaces button {
    padding: 0 8px;
    color: #a6adc8;
}

#workspaces button.active {
    background: #89b4fa;
    color: #1e1e2e;
}

#clock, #network, #pulseaudio, #tray {
    padding: 0 10px;
}
CSS
  echo "Waybar: escrito ~/.config/waybar/config + style.css"
fi

if [[ -n "$ROOT" ]]; then
  echo "Listo. Sistema preparado en $ROOT. Siguiente paso: nixos-install"
  exit 0
fi

if [[ "$COPY_ONLY" -eq 1 ]]; then
  echo "Modo --copy-only: no se ejecuta nixos-rebuild."
  exit 0
fi

echo "Aplicando con nixos-rebuild switch (descargara paquetes, tarda unos minutos)..."
$SUDO nixos-rebuild switch
echo "Listo. Cierra sesion y en SDDM elige la sesion Hyprland."
