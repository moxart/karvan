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
SSHD_SHARE_ONLY_PREFIX="/etc/ssh/sshd_config.d/10-karvan-share-only-"
SHARE_ROOT="/srv/karvan"
SHARE_LINK="$HOME/Karvan"
HOST_KEY="/etc/ssh/ssh_host_ed25519_key.pub"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
LAN_RANGES=(192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 fe80::/10 fd00::/8)
LAUNCHER_BIN="$HOME/.local/bin/karvan"
LAUNCHER_DESKTOP="$HOME/.local/share/applications/karvan.desktop"
LAUNCHER_ICON_THEME="$HOME/.local/share/icons/hicolor"
LAUNCHER_ICON="$LAUNCHER_ICON_THEME/256x256/apps/karvan.png"

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

# A short code people can compare by eye: the first 64 bits of the SHA-256 of a base64 public key
key_code() { printf '%s' "$1" | base64 -d | sha256sum | cut -c1-16 | sed 's/..../& /g; s/ $//'; }

this_computer_details() {
  local code="Run \"⚙️ Set up this computer\" first."
  [ -r "$HOST_KEY" ] && code="$(key_code "$(awk '{print $2}' "$HOST_KEY")")"
  printf '%s' "Network name:\n<b>$(hostname).local</b>\n\nUsername:\n<b>$USER</b>\n\nIP:\n<b>$(hostname -I | awk '{print $1}')</b>\n\nCode:\n<b><big>$code</big></b>"
}

# The first connection to a computer is checked by comparing its code with the one it shows itself,
# so another device on the network cannot pretend to be it; after that ssh remembers its key
verify_host() {
  local host="$1" line
  ssh-keygen -F "$host" -f "$KNOWN_HOSTS" >/dev/null 2>&1 && return 0
  line="$(ssh-keyscan -T 5 -t ed25519 "$host" 2>/dev/null | grep -v '^#' | head -n 1)"
  if [ -z "$line" ]; then
    error "Could not reach $host.\nHas Setup been run on that computer?"
    return 1
  fi
  if ! ask "First connection to <b>$host</b>.\n\nOn that computer, open Karvan and choose \"ℹ️ This computer's details\". Does it show this code?\n\n<b><big>$(key_code "$(awk '{print $3}' <<<"$line")")</big></b>"; then
    error "Not connected.\nIf the codes are different, another device may be pretending to be $host."
    return 1
  fi
  mkdir -p "$(dirname "$KNOWN_HOSTS")"
  chmod 700 "$(dirname "$KNOWN_HOSTS")"
  echo "$line" >> "$KNOWN_HOSTS"
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

  info "Setup complete ✅\n\n$(this_computer_details)\n\nNow do the same on the other computer."
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
    --text="Your username on <b>$1</b>:\n(it may differ from your username on this computer)" --entry-text="$USER" 2>/dev/null)" || return 1
  if ! is_safe_name "$user"; then
    error "Invalid username."
    return 1
  fi
  echo "$user"
}

open_remote_files() {
  local host user url
  host="$(pick_computer)" || return
  verify_host "$host" || return
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
  verify_host "$host" || return
  user="$(ask_username "$host")" || return

  [ -f "$HOME/.ssh/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"

  # Ask for the password in a dialog instead of a terminal
  if SSH_ASKPASS="$SELF" SSH_ASKPASS_REQUIRE=force KARVAN_ASKPASS=1 \
      ssh-copy-id -o StrictHostKeyChecking=yes "$user@$host" </dev/null >/dev/null 2>&1; then
    info "Done ✅\nConnecting to <b>$host</b> will no longer ask for a password."
  else
    error "Could not connect to $host.\n\n• Has Setup been run on that computer?\n• Is the username the one used <b>on that computer</b>?\n• Was the password correct?"
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

toggle_share_only() {
  local mode shared="$SHARE_ROOT/home/$USER"
  if [ -f "$SSHD_SHARE_ONLY_PREFIX$USER.conf" ]; then
    ask "Other computers can currently see only your shared folder.\nShare your whole home folder again?" || return
    mode=off
  else
    ask "After this, other computers see only one shared folder instead of your whole home folder. Put the files you want to share there.\n\n⚠️ First, run \"🔑 Passwordless login\" for this computer on each other computer. It cannot be set up afterwards.\n\nContinue?" || return
    mode=on
  fi
  if ! pkexec "$SELF" --root-share-only "$mode" >/dev/null 2>&1; then
    error "Failed to change the settings."
    return
  fi
  if [ "$mode" = off ]; then
    info "Done ✅\nOther computers can see your whole home folder again.\nFiles in $shared stay where they are."
    return
  fi
  [ -e "$SHARE_LINK" ] || ln -s "$shared" "$SHARE_LINK"
  if [ "$(readlink "$SHARE_LINK")" = "$shared" ]; then
    info "Done ✅\nThe shared folder is <b>Karvan</b> in your home folder."
  else
    info "Done ✅\nThe shared folder is <b>$shared</b>."
  fi
}

# An existing icon cache hides icons it doesn't list, so rebuild it; with no cache, icons are found directly
refresh_icon_cache() {
  if [ -f "$LAUNCHER_ICON_THEME/icon-theme.cache" ] && command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache --force --ignore-theme-index --quiet "$LAUNCHER_ICON_THEME" || true
  fi
}

install_launcher() {
  set -e
  mkdir -p "$(dirname "$LAUNCHER_BIN")" "$(dirname "$LAUNCHER_DESKTOP")" "$(dirname "$LAUNCHER_ICON")"
  [ "$SELF" = "$LAUNCHER_BIN" ] || cp "$SELF" "$LAUNCHER_BIN"
  chmod +x "$LAUNCHER_BIN"
  # The icon ships next to karvan.sh; a reinstall from ~/.local/bin keeps the one already installed
  local icon_src
  icon_src="$(dirname "$SELF")/karvan.png"
  if [ -f "$icon_src" ]; then
    cp "$icon_src" "$LAUNCHER_ICON"
  fi
  # Earlier versions installed a 512px icon by file path
  rm -f "$LAUNCHER_ICON_THEME/512x512/apps/karvan.png"
  refresh_icon_cache
  local icon="folder-remote"
  [ -f "$LAUNCHER_ICON" ] && icon="karvan"
  # Karvan's windows are zenity windows; StartupWMClass makes the dock show them under Karvan
  cat > "$LAUNCHER_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$APP
Comment=Access files on other computers at home
Exec=$LAUNCHER_BIN
Icon=$icon
StartupWMClass=zenity
Terminal=false
Categories=Network;FileTransfer;
EOF
  echo "Installed. Find \"$APP\" in your applications menu."
}

uninstall_launcher() {
  rm -f "$LAUNCHER_BIN" "$LAUNCHER_DESKTOP" "$LAUNCHER_ICON"
  refresh_icon_cache
  echo "Removed $APP from your applications menu."
  echo "System settings made by Setup are left in place; see README.md to remove them."
}

main_menu() {
  local choice
  while true; do
    choice="$(zenity --list --title="$APP" --width=480 --height=390 \
      --text="What would you like to do?" --column="id" --column="Action" --hide-column=1 \
      open  "📂  Open files on another computer" \
      setup "⚙️  Set up this computer (once on each machine)" \
      key   "🔑  Passwordless login" \
      lock  "🛡️  Key login only (disable password login)" \
      share "📁  Share only one folder" \
      about "ℹ️  This computer's details" \
      2>/dev/null)" || exit 0

    case "$choice" in
      open)  open_remote_files ;;
      setup) setup_this_computer ;;
      key)   setup_passwordless ;;
      lock)  toggle_password_login ;;
      share) toggle_share_only ;;
      about) info "$(this_computer_details)" ;;
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
  --root-share-only)
    [[ "${2:-}" = on || "${2:-}" = off ]] || exit 2
    root_set_share_only "$2"
    ;;
  --install)    install_launcher ;;
  --uninstall)  uninstall_launcher ;;
  *)
    command -v zenity >/dev/null || { echo "zenity is required: sudo apt install zenity"; exit 1; }
    main_menu
    ;;
esac
