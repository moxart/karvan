#!/usr/bin/env bash
# Builds dist/karvan_<version>_all.deb from this repository.
# The version comes from VERSION in karvan-ui.py.
#
# Run: bash packaging/build-deb.sh
set -euo pipefail
# Files in a system package must not be group- or world-writable
umask 022

cd "$(dirname "$0")/.."
VERSION="$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' karvan-ui.py)"
[ -n "$VERSION" ] || { echo "VERSION not found in karvan-ui.py" >&2; exit 1; }
APP_ID="io.github.moxart.Karvan"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"

install -D -m 755 karvan.sh "$STAGE/usr/bin/karvan"
install -D -m 644 karvan-ui.py "$STAGE/usr/share/karvan/karvan-ui.py"
install -D -m 644 karvan.png "$STAGE/usr/share/icons/hicolor/256x256/apps/karvan.png"
install -D -m 644 LICENSE "$STAGE/usr/share/doc/karvan/copyright"

mkdir -p "$STAGE/usr/share/applications"
cat > "$STAGE/usr/share/applications/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Karvan
Comment=Access files on other computers at home
Exec=karvan
Icon=karvan
StartupWMClass=$APP_ID
Terminal=false
Categories=Network;FileTransfer;
DESKTOP

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: karvan
Version: $VERSION
Architecture: all
Section: net
Priority: optional
Maintainer: Patrick Der Avakians <patrickderavakians@gmail.com>
Homepage: https://github.com/moxart/karvan
Depends: python3, python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1 (>= 1.5), openssh-client, avahi-utils, pkexec, nautilus
Recommends: openssh-server, avahi-daemon, libnss-mdns
Installed-Size: $(du -sk "$STAGE/usr" | cut -f1)
Description: browse the files of your other Ubuntu computers at home
 Karvan opens the files of another Ubuntu computer on your home network
 right in Files, in both directions, over SSH. It finds the other
 computers by itself, checks a short code on the first connection, and
 can send files from the Files right-click menu. It needs no internet
 connection and no cloud account.
CONTROL

mkdir -p dist
dpkg-deb --root-owner-group --build "$STAGE" "dist/karvan_${VERSION}_all.deb" >/dev/null
echo "Built dist/karvan_${VERSION}_all.deb"
