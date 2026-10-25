# Karvan

Browse the files of another Ubuntu computer on your home network from the
Files app. You can do it in both directions, with no terminal needed after
installation.

Karvan is a small desktop tool built on things Ubuntu already has: SSH/SFTP for
the connection, Avahi (mDNS) to find the other computers, Nautilus to show their
files, and zenity for the dialogs.

## Features

- **Set up this computer.** Installs and enables the SSH server, makes the
  computer discoverable on the local network, and opens the firewall for the
  local network only.
- **Open files on another computer.** Lists the Karvan computers it finds on
  your network and opens the one you pick in Files. It can also add that
  computer to the Files sidebar.
- **Passwordless login.** Creates an SSH key if needed and copies it to the
  other computer.
- **Key login only.** Turns off SSH password login on this computer. The same
  option turns it back on.

## Requirements

- Ubuntu 22.04 or newer, desktop edition (GNOME with Files/Nautilus)
- `zenity`, which comes with Ubuntu Desktop
- An administrator account on each computer (needed once, for setup)
- All computers on the same local network

## Installation

Do these steps on **each** computer.

### 1. Get Karvan

```bash
git clone https://github.com/moxart/karvan.git
cd karvan
```

If `git` is not installed, either install it with `sudo apt install git`, or
download the ZIP from GitHub (**Code → Download ZIP**) and extract it.

### 2. Add it to the applications menu

```bash
bash karvan.sh --install
```

This copies Karvan to `~/.local/bin/karvan` and adds **Karvan** to your
applications menu. You can delete the cloned folder afterwards.

### 3. Set up the computer

Open **Karvan** from the applications menu and choose
**⚙️ Set up this computer**. Enter your administrator password when asked.

At the end Karvan shows the computer's network name (for example
`computer-a.local`) and its IP address.

Once both computers are set up, they can see each other.

## Usage

### Open files on another computer

1. Open Karvan and choose **📂 Open files on another computer**.
2. Pick the computer from the list. If it is not listed, choose
   **✏️ Enter manually** and type its name or IP address.
3. Enter your username on that computer.
4. Enter that computer's password when Files asks for it.

Its home folder opens in Files. You can copy, open and edit the files as if
they were on your own computer.

### Recommended: switch to key login

Password login works, but anyone on your network who can guess the password
can get in. Keys are safer:

1. On computer **A**, run **🔑 Passwordless login** and pick computer **B**.
2. On computer **B**, run **🔑 Passwordless login** and pick computer **A**.
3. Check that each computer can now open the other without a password.
4. On **both** computers, run **🛡️ Key login only**.

Do step 4 if one of the computers is a laptop that joins public Wi-Fi.

## Security

Setup changes these system settings:

| What | Where |
| --- | --- |
| Allows SSH logins only from local network addresses (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`, IPv6 link-local and ULA) | `/etc/ssh/sshd_config.d/10-karvan-lan-only.conf` |
| Disables password login (only with **Key login only**) | `/etc/ssh/sshd_config.d/10-karvan-keys-only.conf` |
| Advertises the computer on the local network | `/etc/avahi/services/karvan.service` |
| Opens port 22 for the ranges above (only if `ufw` is active) | `ufw` rules |

Karvan checks every SSH config change with `sshd -t` before applying it. If a
change is invalid, Karvan does not apply it.

Some risks remain:

- **First connection.** The first time you connect to a computer, its host key
  is accepted without a check (trust on first use). On a home network the risk
  is low.
- **Public networks.** Café and hotel Wi-Fi also use local addresses, so the
  local-network limit gives no protection there. Turn on **Key login only** on
  laptops.
- **Remote access.** Karvan blocks access from outside your home network. If
  you need it, use a VPN such as Tailscale or WireGuard. Do not forward port 22
  on your router.

## Uninstall

Remove Karvan from the applications menu:

```bash
karvan --uninstall
```

To also undo the system changes made by setup:

```bash
sudo rm -f /etc/ssh/sshd_config.d/10-karvan-*.conf /etc/avahi/services/karvan.service
```

```bash
sudo systemctl restart ssh avahi-daemon
```

If you want to keep the SSH server but turn off SSH completely, run:

```bash
sudo systemctl disable --now ssh
```

## Troubleshooting

**The other computer is not in the list**
- Make sure setup has been run on that computer.
- Some routers block mDNS. Choose **✏️ Enter manually** and use the IP address
  shown at the end of setup.

**The IP address keeps changing**
In your router settings, reserve a fixed IP for each computer (often called
*DHCP reservation*). Another option is to use the `name.local` address.

**Setup failed**
Setup has to download packages, so check your internet connection. To see the
full error, run the setup step from a terminal:

```bash
pkexec ~/.local/bin/karvan --root-setup
```

**Cannot log in after enabling Key login only**
Sit at that computer, open Karvan, and run **🛡️ Key login only** again to
turn password login back on.
