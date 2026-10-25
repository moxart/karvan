#!/usr/bin/env bash
# Karvan — access files on other Ubuntu computers on your home network
#
# Run:              ./karvan.sh
# Add to app menu:  ./karvan.sh --install
# Remove from menu: karvan --uninstall

set -u

APP="Karvan"
SERVICE_TYPE="_sftp-ssh._tcp"
AVAHI_SERVICE_FILE="/etc/avahi/services/karvan.service"
BOOKMARKS="$HOME/.config/gtk-3.0/bookmarks"
SELF="$(realpath "${BASH_SOURCE[0]}")"
SSHD_LAN_ONLY="/etc/ssh/sshd_config.d/10-karvan-lan-only.conf"
SSHD_KEYS_ONLY="/etc/ssh/sshd_config.d/10-karvan-keys-only.conf"
LAN_RANGES=(192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 fe80::/10 fd00::/8)
LAUNCHER_BIN="$HOME/.local/bin/karvan"
LAUNCHER_DESKTOP="$HOME/.local/share/applications/karvan.desktop"

# Names coming from the network or the user must use safe characters only
# (prevents option injection into ssh and unsafe characters in URLs and bookmarks)
is_safe_name() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._:-]{0,252}$ ]]; }

info()  { zenity --info  --title="$APP" --width=420 --text="$1" 2>/dev/null; }
error() { zenity --error --title="$APP" --width=420 --text="$1" 2>/dev/null; }
ask()   { zenity --question --title="$APP" --width=420 --text="$1" 2>/dev/null; }

# ---------- Run as root ----------

root_setup() {
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y openssh-server avahi-daemon avahi-utils libnss-mdns
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

# ---------- Main actions ----------

setup_this_computer() {
  ask "This will, on <b>this computer</b>:\n\n• Install and enable the SSH server\n• Make this computer discoverable on your home network\n• Open the SSH port in the firewall (if enabled) <b>for the home network only</b>\n• Block logins from outside the home network (internet)\n\nYou will be asked for the administrator password. Continue?" || return

  pkexec "$SELF" --root-setup 2>&1 \
    | zenity --progress --pulsate --auto-close --no-cancel \
        --title="$APP" --text="Installing and configuring..." --width=420 2>/dev/null
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    error "Setup failed. Check your internet connection and try again."
    return
  fi

  info "Setup complete ✅\n\nThis computer's network name:\n<b>$(hostname).local</b>\n\nIP:\n<b>$(hostname -I | awk '{print $1}')</b>\n\nNow do the same on the other computer."
}

# Output: lines of the form  name|hostname|ip
discover_computers() {
  command -v avahi-browse >/dev/null || return
  local me
  me="$(hostname)"
  timeout 8 avahi-browse -tpr "$SERVICE_TYPE" 2>/dev/null \
    | awk -F';' -v me="$me" '$1=="=" && $3=="IPv4" && $4!=me { print $4 "|" $7 "|" $8 }' \
    | sort -u
}

pick_computer() {
  local list=() name host ip found pid
  found="$(mktemp)"
  discover_computers > "$found" &
  pid=$!
  # Keep the "searching" dialog open until discovery finishes
  ( while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done ) \
    | zenity --progress --pulsate --auto-close --no-cancel \
        --title="$APP" --text="Searching for computers on the network..." 2>/dev/null
  wait "$pid"

  while IFS='|' read -r name host ip; do
    is_safe_name "$host" && list+=("$name" "$host" "$ip")
  done < "$found"
  rm -f "$found"

  list+=("✏️ Enter manually" "-" "-")

  local choice
  choice="$(zenity --list --title="$APP" --width=560 --height=380 \
    --text="Which computer do you want to connect to?" \
    --column="Name" --column="Address" --column="IP" \
    --print-column=2 "${list[@]}" 2>/dev/null)" || return 1

  if [ "$choice" = "-" ] || [ -z "$choice" ]; then
    choice="$(zenity --entry --title="$APP" --width=420 \
      --text="Enter the other computer's name or IP\n(e.g. computer-b.local or 192.168.1.20):" 2>/dev/null)" || return 1
  fi
  if ! is_safe_name "$choice"; then
    error "Invalid address."
    return 1
  fi
  echo "$choice"
}

ask_username() {
  local user
  user="$(zenity --entry --title="$APP" --width=420 \
    --text="Username on <b>$1</b>:" --entry-text="$USER" 2>/dev/null)" || return 1
  if ! is_safe_name "$user"; then
    error "Invalid username."
    return 1
  fi
  echo "$user"
}

open_remote_files() {
  local host user url
  host="$(pick_computer)" || return
  user="$(ask_username "$host")" || return
  url="sftp://$user@$host/home/$user"

  if ! grep -qsF "$url" "$BOOKMARKS" && ask "Add this computer to the Files sidebar?\n(for quick access next time)"; then
    mkdir -p "$(dirname "$BOOKMARKS")"
    echo "$url $host" >> "$BOOKMARKS"
  fi

  nautilus --new-window "$url" >/dev/null 2>&1 &
}

setup_passwordless() {
  local host user
  host="$(pick_computer)" || return
  user="$(ask_username "$host")" || return

  [ -f "$HOME/.ssh/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"

  # Ask for the password in a dialog instead of a terminal
  if SSH_ASKPASS="$SELF" SSH_ASKPASS_REQUIRE=force KARVAN_ASKPASS=1 \
      ssh-copy-id -o StrictHostKeyChecking=accept-new "$user@$host" </dev/null >/dev/null 2>&1; then
    info "Done ✅\nConnecting to <b>$host</b> will no longer ask for a password."
  else
    error "Could not connect to $host.\n\n• Has Setup been run on that computer?\n• Were the username and password correct?"
  fi
}

toggle_password_login() {
  local mode
  if [ -f "$SSHD_KEYS_ONLY" ]; then
    ask "Password login is currently <b>disabled</b> on this computer.\nRe-enable it?" || return
    mode=on
  else
    ask "After this, other computers can connect to this one only with key login (\"Passwordless login\"), and nobody can get in by guessing the password.\n\n⚠️ First, on the <b>other computer</b>, run \"🔑 Passwordless login\" for this computer and make sure it works.\n\nContinue?" || return
    mode=off
  fi
  if pkexec "$SELF" --root-password-login "$mode" >/dev/null 2>&1; then
    info "Done ✅"
  else
    error "Failed to change the settings."
  fi
}

install_launcher() {
  set -e
  mkdir -p "$(dirname "$LAUNCHER_BIN")" "$(dirname "$LAUNCHER_DESKTOP")"
  [ "$SELF" = "$LAUNCHER_BIN" ] || cp "$SELF" "$LAUNCHER_BIN"
  chmod +x "$LAUNCHER_BIN"
  cat > "$LAUNCHER_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$APP
Comment=Access files on other computers at home
Exec=$LAUNCHER_BIN
Icon=folder-remote
Terminal=false
Categories=Network;FileTransfer;
EOF
  echo "Installed. Find \"$APP\" in your applications menu."
}

uninstall_launcher() {
  rm -f "$LAUNCHER_BIN" "$LAUNCHER_DESKTOP"
  echo "Removed $APP from your applications menu."
  echo "System settings made by Setup are left in place; see README.md to remove them."
}

main_menu() {
  local choice
  while true; do
    choice="$(zenity --list --title="$APP" --width=480 --height=330 \
      --text="What would you like to do?" --column="id" --column="Action" --hide-column=1 \
      open  "📂  Open files on another computer" \
      setup "⚙️  Set up this computer (once on each machine)" \
      key   "🔑  Passwordless login" \
      lock  "🛡️  Key login only (disable password login)" \
      2>/dev/null)" || exit 0

    case "$choice" in
      open)  open_remote_files ;;
      setup) setup_this_computer ;;
      key)   setup_passwordless ;;
      lock)  toggle_password_login ;;
    esac
  done
}

# ---------- Entry point ----------

if [ "${KARVAN_ASKPASS:-}" = 1 ]; then
  zenity --password --title="${1:-Password}" 2>/dev/null
  exit $?
fi

case "${1:-}" in
  --root-setup) root_setup ;;
  --root-password-login)
    [[ "${2:-}" = on || "${2:-}" = off ]] || exit 2
    root_set_password_login "$2"
    ;;
  --install)    install_launcher ;;
  --uninstall)  uninstall_launcher ;;
  *)
    command -v zenity >/dev/null || { echo "zenity is required: sudo apt install zenity"; exit 1; }
    main_menu
    ;;
esac
