#!/usr/bin/env bash
# Karvan — access files on other Ubuntu computers on your home network
#
# Run:              ./karvan.sh
# Add to app menu:  ./karvan.sh --install
# Remove from menu: karvan --uninstall

set -u

APP="Karvan"
AVAHI_SERVICE_FILE="/etc/avahi/services/karvan.service"
SELF="$(realpath "${BASH_SOURCE[0]}")"
SSHD_LAN_ONLY="/etc/ssh/sshd_config.d/10-karvan-lan-only.conf"
SSHD_KEYS_ONLY="/etc/ssh/sshd_config.d/10-karvan-keys-only.conf"
SSHD_SHARE_ONLY_PREFIX="/etc/ssh/sshd_config.d/10-karvan-share-only-"
SHARE_ROOT="/srv/karvan"
LAN_RANGES=(192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 fe80::/10 fd00::/8)
LAUNCHER_BIN="$HOME/.local/bin/karvan"
LAUNCHER_ICON_THEME="$HOME/.local/share/icons/hicolor"
LAUNCHER_ICON="$LAUNCHER_ICON_THEME/256x256/apps/karvan.png"
LAUNCHER_UI="$HOME/.local/share/karvan/karvan-ui.py"
APP_ID="io.github.moxart.Karvan"
# Named after the window's app ID, so GNOME puts the window under this launcher's icon in the dock
LAUNCHER_DESKTOP="$HOME/.local/share/applications/$APP_ID.desktop"
# Earlier versions named the launcher karvan.desktop
OLD_LAUNCHER_DESKTOP="$HOME/.local/share/applications/karvan.desktop"
UI_CHECK='import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1"); from gi.repository import Adw; assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5)'

# Names coming from the network or the user must use safe characters only
# (prevents option injection into ssh and unsafe characters in URLs and bookmarks)
is_safe_name() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._:-]{0,252}$ ]]; }

# ---------- Run as root ----------

root_setup() {
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y openssh-server avahi-daemon avahi-utils libnss-mdns python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
  systemctl enable --now ssh

  # Accept logins from local network addresses only (even if the router forwards
  # the port or the machine has a public IPv6 address)
  echo "AllowUsers $(printf '*@%s ' 127.0.0.1 ::1 "${LAN_RANGES[@]}")" > "$SSHD_LAN_ONLY"
  apply_sshd_config "$SSHD_LAN_ONLY"

  # Advertise this computer on the network so the others can find it
  cat > "$AVAHI_SERVICE_FILE" <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_sftp-ssh._tcp</type>
    <port>22</port>
  </service>
</service-group>
EOF
  systemctl enable --now avahi-daemon
  systemctl restart avahi-daemon

  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    local range
    for range in "${LAN_RANGES[@]}"; do
      # IPv6 ranges fail when ufw has IPv6 disabled; that must not abort setup
      ufw allow from "$range" to any port 22 proto tcp || true
    done
  fi
}

# Applies a new config only if it is valid; otherwise removes it so SSH keeps working
apply_sshd_config() {
  # With socket activation (Ubuntu 22.10+) this directory may not exist yet, and sshd -t needs it
  mkdir -p /run/sshd
  if ! sshd -t; then
    rm -f "$1"
    echo "invalid sshd config: $1" >&2
    return 1
  fi
  systemctl restart ssh
}

root_set_password_login() {
  set -e
  if [ "$1" = off ]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > "$SSHD_KEYS_ONLY"
    apply_sshd_config "$SSHD_KEYS_ONLY"
  else
    rm -f "$SSHD_KEYS_ONLY"
    systemctl restart ssh
  fi
}

# Limits SSH logins of the user who ran pkexec to SFTP inside $SHARE_ROOT, where only
# home/<user> is theirs, so the usual sftp://user@host/home/user address still works
root_set_share_only() {
  set -e
  local user group conf
  user="$(id -nu "${PKEXEC_UID:?}")"
  is_safe_name "$user"
  conf="$SSHD_SHARE_ONLY_PREFIX$user.conf"
  if [ "$1" = on ]; then
    group="$(id -gn "$user")"
    # sshd requires every directory on the chroot path to be owned by root and writable only by root
    install -d -o root -g root -m 755 "$SHARE_ROOT" "$SHARE_ROOT/home"
    install -d -o "$user" -g "$group" -m 700 "$SHARE_ROOT/home/$user"
    cat > "$conf" <<EOF
Match User $user
    ChrootDirectory $SHARE_ROOT
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
Match all
EOF
    apply_sshd_config "$conf"
  else
    rm -f "$conf"
    systemctl restart ssh
  fi
}

# ---------- Window ----------

# The window is karvan-ui.py (GTK 4 + libadwaita); it calls back into this script for admin tasks
launch_window() {
  local ui
  ui="$(dirname "$SELF")/karvan-ui.py"
  [ -f "$ui" ] || ui="$LAUNCHER_UI"
  if ! python3 -c "$UI_CHECK" 2>/dev/null; then
    local text="Karvan needs GTK 4 and libadwaita 1.5 or newer (Ubuntu 24.04 or newer). Install them with:\n\nsudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1"
    zenity --error --title="$APP" --width=420 --text="$text" 2>/dev/null || echo -e "$text" >&2
    exit 1
  fi
  KARVAN_SH="$SELF" exec python3 "$ui"
}

# An existing icon cache hides icons it doesn't list, so rebuild it; with no cache, icons are found directly
refresh_icon_cache() {
  if [ -f "$LAUNCHER_ICON_THEME/icon-theme.cache" ] && command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache --force --ignore-theme-index --quiet "$LAUNCHER_ICON_THEME" || true
  fi
  # GNOME Shell rescans a theme only when the theme folder itself changes, not its size folders
  [ ! -d "$LAUNCHER_ICON_THEME" ] || touch "$LAUNCHER_ICON_THEME"
}

install_launcher() {
  set -e
  mkdir -p "$(dirname "$LAUNCHER_BIN")" "$(dirname "$LAUNCHER_DESKTOP")" "$(dirname "$LAUNCHER_ICON")" \
    "$(dirname "$LAUNCHER_UI")"
  [ "$SELF" = "$LAUNCHER_BIN" ] || cp "$SELF" "$LAUNCHER_BIN"
  chmod +x "$LAUNCHER_BIN"
  # The window and icon ship next to karvan.sh; a reinstall from ~/.local/bin keeps the installed ones
  local src
  src="$(dirname "$SELF")"
  if [ -f "$src/karvan-ui.py" ]; then
    cp "$src/karvan-ui.py" "$LAUNCHER_UI"
  fi
  if [ -f "$src/karvan.png" ]; then
    cp "$src/karvan.png" "$LAUNCHER_ICON"
  fi
  # Earlier versions installed a 512px icon by file path
  rm -f "$LAUNCHER_ICON_THEME/512x512/apps/karvan.png"
  refresh_icon_cache
  local icon="folder-remote"
  [ -f "$LAUNCHER_ICON" ] && icon="karvan"
  rm -f "$OLD_LAUNCHER_DESKTOP"
  cat > "$LAUNCHER_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$APP
Comment=Access files on other computers at home
Exec=$LAUNCHER_BIN
Icon=$icon
Terminal=false
Categories=Network;FileTransfer;
EOF
  echo "Installed. Find \"$APP\" in your applications menu."
  python3 -c "$UI_CHECK" 2>/dev/null \
    || echo "Karvan's window also needs: sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1"
}

uninstall_launcher() {
  rm -f "$LAUNCHER_BIN" "$LAUNCHER_DESKTOP" "$OLD_LAUNCHER_DESKTOP" "$LAUNCHER_ICON" "$LAUNCHER_UI"
  rmdir "$(dirname "$LAUNCHER_UI")" 2>/dev/null || true
  refresh_icon_cache
  echo "Removed $APP from your applications menu."
  echo "System settings made by Setup are left in place; see README.md to remove them."
}

# ---------- Entry point ----------

# ssh-copy-id runs this script as SSH_ASKPASS; the window passed the password it asked for.
# A yes/no question means ssh doesn't trust the host key: refuse rather than loop on the password.
if [ "${KARVAN_ASKPASS:-}" = 1 ]; then
  case "$*" in
    *yes*) echo no ;;
    *)     printf '%s\n' "${KARVAN_ASKPASS_PASSWORD:-}" ;;
  esac
  exit 0
fi

case "${1:-}" in
  --root-setup) root_setup ;;
  --root-password-login)
    [[ "${2:-}" = on || "${2:-}" = off ]] || exit 2
    root_set_password_login "$2"
    ;;
  --root-share-only)
    [[ "${2:-}" = on || "${2:-}" = off ]] || exit 2
    root_set_share_only "$2"
    ;;
  --install)    install_launcher ;;
  --uninstall)  uninstall_launcher ;;
  *)            launch_window ;;
esac
