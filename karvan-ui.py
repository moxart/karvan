#!/usr/bin/env python3
"""Karvan's window, built with GTK 4 and libadwaita.

karvan.sh starts it and passes its own path in KARVAN_SH; tasks that need the
administrator password go back through `pkexec karvan.sh --root-...`.
"""

import base64
import getpass
import hashlib
import os
import re
import socket
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, GObject, Gtk  # noqa: E402

APP_ID = "io.github.moxart.Karvan"
SERVICE_TYPE = "_sftp-ssh._tcp"
USER = getpass.getuser()
HOME = Path.home()
HOST_KEY = Path("/etc/ssh/ssh_host_ed25519_key.pub")
AVAHI_SERVICE_FILE = Path("/etc/avahi/services/karvan.service")
SSHD_KEYS_ONLY = Path("/etc/ssh/sshd_config.d/10-karvan-keys-only.conf")
SSHD_SHARE_ONLY = Path(f"/etc/ssh/sshd_config.d/10-karvan-share-only-{USER}.conf")
SHARED_FOLDER = Path("/srv/karvan/home") / USER
SHARE_LINK = HOME / "Karvan"
KNOWN_HOSTS = HOME / ".ssh/known_hosts"
SSH_KEY = HOME / ".ssh/id_ed25519"
BOOKMARKS = HOME / ".config/gtk-3.0/bookmarks"
CONFIG_DIR = HOME / ".config/karvan"
LANGUAGE_FILE = CONFIG_DIR / "language"
USERNAMES_FILE = CONFIG_DIR / "usernames"
KARVAN_SH = os.environ.get("KARVAN_SH", "")

# Names coming from the network or the user must use safe characters only
# (prevents option injection into ssh and unsafe characters in URLs and bookmarks)
SAFE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._:-]{0,252}$")

CSS = """
.code { font-family: monospace; font-size: 1.5em; letter-spacing: 0.06em; }
.hero-title { margin-top: 6px; }
"""


# ---------- Language ----------

def ui_language():
    """The saved choice wins; otherwise follow the system language."""
    try:
        saved = LANGUAGE_FILE.read_text().strip()
        if saved in ("en", "fa"):
            return saved
    except OSError:
        pass
    for var in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(var)
        if value:
            return "fa" if value.startswith("fa") else "en"
    return "en"


UI_LANG = ui_language()


def t(text, *args):
    """English text is the key; the Persian interface looks it up in FA (end of this file)."""
    if UI_LANG == "fa":
        text = FA.get(text, text)
    return text % args if args else text


# ---------- Network and SSH ----------

def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def unescape_avahi(name):
    """avahi-browse -p writes characters such as spaces as \\032 (decimal)."""
    return re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1))), name)


def lan_preference(ip):
    for rank, prefix in enumerate(("192.168.", "10.", "172.")):
        if ip.startswith(prefix):
            return rank
    return 3


def discover_computers():
    """Returns [(name, host, ip)] for the other Karvan computers on the network."""
    me = socket.gethostname()
    try:
        out = run(["timeout", "8", "avahi-browse", "-tpr", SERVICE_TYPE]).stdout
    except FileNotFoundError:
        return []
    found = {}
    for line in out.splitlines():
        fields = line.split(";")
        if len(fields) < 8 or fields[0] != "=" or fields[2] != "IPv4":
            continue
        name, host, ip = unescape_avahi(fields[3]), fields[6], fields[7]
        if name == me or not SAFE_NAME.match(host):
            continue
        found.setdefault(host, (name, set()))[1].add(ip)
    # A computer is advertised on every interface (Docker bridges too); show its home network address
    return sorted(
        (name, host, min(ips, key=lambda ip: (lan_preference(ip), ip)))
        for host, (name, ips) in found.items()
    )


def key_code(key_base64):
    """A short code people can compare by eye: the first 64 bits of the SHA-256 of the public key."""
    digest = hashlib.sha256(base64.b64decode(key_base64)).hexdigest()[:16]
    return " ".join(digest[i:i + 4] for i in range(0, 16, 4))


def this_computer_code():
    try:
        return key_code(HOST_KEY.read_text().split()[1])
    except (OSError, IndexError, ValueError):
        return None


def this_computer_ip():
    ips = run(["hostname", "-I"]).stdout.split()
    return min(ips, key=lambda ip: (lan_preference(ip), ip)) if ips else ""


def is_set_up():
    return AVAHI_SERVICE_FILE.exists() and HOST_KEY.exists()


def is_known_host(host):
    # ssh looks host names up in lowercase, and saves them that way
    return run(["ssh-keygen", "-F", host.lower(), "-f", str(KNOWN_HOSTS)]).returncode == 0


def resolve(host):
    """Returns the host's address, preferring IPv4, or None if the name can't be found."""
    for family in (socket.AF_INET, socket.AF_UNSPEC):
        try:
            return socket.getaddrinfo(host, 22, family, socket.SOCK_STREAM)[0][4][0]
        except (socket.gaierror, IndexError):
            continue
    return None


def scan_host_key(host):
    """Returns the known_hosts line for the host's ed25519 key, or None if it can't be reached."""
    # Ubuntu's AppArmor profile for ssh-keyscan blocks Avahi, so it can't look up .local names itself
    address = resolve(host)
    if not address:
        return None
    out = run(["ssh-keyscan", "-T", "5", "-t", "ed25519", address]).stdout
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 3 and not line.startswith("#"):
            return f"{host.lower()} {fields[1]} {fields[2]}"
    return None


def remember_host_key(line):
    KNOWN_HOSTS.parent.mkdir(mode=0o700, exist_ok=True)
    with KNOWN_HOSTS.open("a") as f:
        f.write(line + "\n")


def saved_usernames():
    try:
        pairs = (line.split() for line in USERNAMES_FILE.read_text().splitlines())
        return {p[0]: p[1] for p in pairs if len(p) == 2}
    except OSError:
        return {}


def save_username(host, user):
    names = saved_usernames()
    names[host] = user
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    USERNAMES_FILE.write_text("".join(f"{h} {u}\n" for h, u in sorted(names.items())))


def forget_username(host):
    names = saved_usernames()
    names.pop(host, None)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    USERNAMES_FILE.write_text("".join(f"{h} {u}\n" for h, u in sorted(names.items())))


def remote_url(host, user):
    return f"sftp://{user}@{host}/home/{user}"


def is_bookmarked(url):
    try:
        return any(line.split(" ")[0] == url for line in BOOKMARKS.read_text().splitlines())
    except OSError:
        return False


def add_bookmark(url, host):
    BOOKMARKS.parent.mkdir(parents=True, exist_ok=True)
    with BOOKMARKS.open("a") as f:
        f.write(f"{url} {host}\n")


def copy_key_to(host, user, password):
    if not SSH_KEY.exists():
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(SSH_KEY)])
    # ssh asks karvan.sh for the password (see its KARVAN_ASKPASS mode) instead of a terminal
    env = dict(os.environ, SSH_ASKPASS=KARVAN_SH, SSH_ASKPASS_REQUIRE="force",
               KARVAN_ASKPASS="1", KARVAN_ASKPASS_PASSWORD=password)
    try:
        result = run(["ssh-copy-id", "-o", "StrictHostKeyChecking=yes",
                      "-o", "NumberOfPasswordPrompts=1", f"{user}@{host}"],
                     env=env, stdin=subprocess.DEVNULL, timeout=60)
    except subprocess.TimeoutExpired:
        return False
    return result.returncode == 0


def run_as_admin(*args):
    return run(["pkexec", KARVAN_SH, *args]).returncode == 0


def in_background(work, done):
    """Runs work() off the main thread, then done(result) on it."""
    def worker():
        result = work()
        GLib.idle_add(lambda: done(result) and False)
    threading.Thread(target=worker, daemon=True).start()


# ---------- Window ----------

class KarvanWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Karvan", default_width=500, default_height=780)
        self.computer_rows = []
        self.busy_toggle = False

        self.toasts = Adw.ToastOverlay()
        view = Adw.ToolbarView()
        view.add_top_bar(self.build_header())
        view.set_content(self.toasts)
        self.set_content(view)

        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                       margin_top=12, margin_bottom=32, margin_start=16, margin_end=16)
        page.append(self.build_hero())
        self.computers = Adw.PreferencesGroup(title=t("Computers on your network"))
        self.spinner = Gtk.Spinner()
        self.computers.set_header_suffix(self.spinner)
        page.append(self.computers)
        self.this_computer = Adw.PreferencesGroup(title=t("This computer"))
        page.append(self.this_computer)
        self.security = Adw.PreferencesGroup(title=t("Security"))
        page.append(self.security)

        clamp = Adw.Clamp(maximum_size=560, child=page)
        self.toasts.set_child(Gtk.ScrolledWindow(child=clamp, hscrollbar_policy=Gtk.PolicyType.NEVER))

        for name, handler in (("open", self.on_open), ("passwordless", self.on_passwordless),
                              ("forget-username", self.on_forget_username)):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new("s"))
            action.connect("activate", lambda _a, host, h=handler: h(host.get_string()))
            self.add_action(action)

        self.refresh_this_computer()
        self.search()

    # ----- Layout -----

    def build_header(self):
        header = Adw.HeaderBar()
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text=t("Search again"))
        refresh.connect("clicked", lambda _b: self.search())
        header.pack_start(refresh)

        menu = Gio.Menu()
        languages = Gio.Menu()
        languages.append("English", "app.language('en')")
        languages.append("فارسی", "app.language('fa')")
        menu.append_section(t("Language"), languages)
        more = Gio.Menu()
        more.append(t("Run setup again"), "app.setup")
        more.append(t("About Karvan"), "app.about")
        menu.append_section(None, more)
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                                       tooltip_text=t("Main menu")))
        return header

    def build_hero(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
        local_icon = Path(KARVAN_SH).parent / "karvan.png"
        if not theme.has_icon("karvan") and local_icon.exists():
            icon = Gtk.Image.new_from_file(str(local_icon))
        else:
            icon = Gtk.Image.new_from_icon_name("karvan")
        icon.set_pixel_size(112)
        box.append(icon)
        title = Gtk.Label(label=t("Files on your home computers"), wrap=True,
                          justify=Gtk.Justification.CENTER, css_classes=["title-1", "hero-title"])
        box.append(title)
        box.append(Gtk.Label(label=t("Open another computer's files right in Files."), wrap=True,
                             justify=Gtk.Justification.CENTER, css_classes=["dim-label"]))
        return box

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text, timeout=4))

    def copy_text(self, text):
        provider = Gdk.ContentProvider.new_for_value(GObject.Value(str, text))
        self.get_clipboard().set_content(provider)
        self.toast(t("Code copied"))

    def show_error(self, heading, body=None):
        dialog = Adw.AlertDialog(heading=heading, body=body or "")
        dialog.add_response("close", t("OK"))
        dialog.present(self)

    # ----- Computers on the network -----

    def search(self):
        if self.spinner.get_spinning():
            return
        self.spinner.start()
        self.show_computers(None)
        in_background(discover_computers, self.show_computers)

    def show_computers(self, computers):
        for row in self.computer_rows:
            self.computers.remove(row)
        self.computer_rows = []
        if computers is None:
            self.add_computer_row(Adw.ActionRow(title=t("Searching…")))
        else:
            self.spinner.stop()
            if not computers:
                self.add_computer_row(Adw.ActionRow(
                    title=t("No computers found"),
                    subtitle=t("Check that the other computer is on, on the same network, and set up.")))
            for name, host, ip in computers:
                self.add_computer_row(self.computer_row(name, host, ip))

        add = Adw.ActionRow(title=t("Connect by name or IP"), activatable=True)
        add.add_prefix(Gtk.Image(icon_name="list-add-symbolic"))
        add.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
        add.connect("activated", lambda _r: self.ask_address())
        self.add_computer_row(add)

    def add_computer_row(self, row):
        self.computers.add(row)
        self.computer_rows.append(row)

    def computer_row(self, name, host, ip):
        row = Adw.ActionRow(title=name, subtitle=f"{host} · {ip}", use_markup=False, activatable=True)
        row.add_prefix(Gtk.Image(icon_name="computer-symbolic", pixel_size=32))
        open_button = Gtk.Button(label=t("Open"), valign=Gtk.Align.CENTER, css_classes=["suggested-action"])
        open_button.connect("clicked", lambda _b: self.on_open(host))
        row.add_suffix(open_button)

        menu = Gio.Menu()
        item = Gio.MenuItem.new(t("Passwordless login"), None)
        item.set_action_and_target_value("win.passwordless", GLib.Variant.new_string(host))
        menu.append_item(item)
        if host in saved_usernames():
            item = Gio.MenuItem.new(t("Use a different username"), None)
            item.set_action_and_target_value("win.forget-username", GLib.Variant.new_string(host))
            menu.append_item(item)
        row.add_suffix(Gtk.MenuButton(icon_name="view-more-symbolic", menu_model=menu,
                                      valign=Gtk.Align.CENTER, css_classes=["flat"],
                                      tooltip_text=t("More")))
        row.connect("activated", lambda _r: self.on_open(host))
        return row

    def ask_address(self):
        entry = Adw.EntryRow(title=t("Name or IP"), activates_default=True)
        dialog = self.dialog(t("Connect by name or IP"), t("For example, laptop.local or 192.168.1.20"),
                             extra=self.boxed(entry), ok=t("Connect"))

        def answered(ok):
            if not ok:
                return
            host = entry.get_text().strip()
            if not SAFE_NAME.match(host):
                self.show_error(t("That address isn't valid"),
                                t("Use a name such as laptop.local or an IP address such as 192.168.1.20."))
                return
            self.on_open(host)
        dialog.connect("response", lambda _d, r: answered(r == "ok"))
        dialog.present(self)

    # ----- Connecting -----

    def verify_then(self, host, next_step):
        """The first connection is checked by comparing codes, so another device can't pretend to be it."""
        def check():
            return None if is_known_host(host) else (scan_host_key(host) or "")

        def checked(line):
            if line is None:
                next_step()
            elif line == "":
                self.show_error(t("Couldn't reach %s", host),
                                t("Check that the other computer is on, on the same network, and set up."))
            else:
                self.confirm_code(host, line, next_step)
        in_background(check, checked)

    def confirm_code(self, host, line, next_step):
        code = Gtk.Label(label=key_code(line.split()[2]), selectable=True, css_classes=["code"],
                         margin_top=6)
        dialog = Adw.AlertDialog(
            heading=t("Is this the right computer?"),
            body=t("On %s, open Karvan and look at the code under “This computer”. "
                   "It should be the same as this one.", host),
            extra_child=code)
        dialog.add_response("different", t("Codes differ"))
        dialog.add_response("same", t("Codes match"))
        dialog.set_response_appearance("same", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_close_response("different")

        def answered(_d, response):
            if response == "same":
                remember_host_key(line)
                next_step()
            else:
                self.show_error(t("Not connected"),
                                t("If the codes are different, another device may be pretending to be %s.", host))
        dialog.connect("response", answered)
        dialog.present(self)

    def with_username(self, host, next_step, offer_bookmark=False):
        user = saved_usernames().get(host)
        if user:
            next_step(user, False)
            return
        entry = Adw.EntryRow(title=t("Your username on %s", host), text=USER, activates_default=True)
        group = Adw.PreferencesGroup(
            description=t("It may be different from your username on this computer."))
        group.add(entry)
        sidebar = Adw.SwitchRow(title=t("Show in the Files sidebar"), active=True)
        if offer_bookmark:
            group.add(sidebar)
        dialog = self.dialog(t("Who are you on %s?", host), None, extra=group, ok=t("Continue"))

        def answered(_d, response):
            if response != "ok":
                return
            user = entry.get_text().strip()
            if not SAFE_NAME.match(user):
                self.show_error(t("That username isn't valid"),
                                t("Use the username shown under “This computer” on %s.", host))
                return
            save_username(host, user)
            next_step(user, offer_bookmark and sidebar.get_active())
        dialog.connect("response", answered)
        dialog.present(self)

    def on_open(self, host):
        def open_files(user, bookmark):
            url = remote_url(host, user)
            if bookmark and not is_bookmarked(url):
                add_bookmark(url, host)
            subprocess.Popen(["nautilus", "--new-window", url], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.toast(t("Opening %s in Files…", host))
        self.verify_then(host, lambda: self.with_username(host, open_files, offer_bookmark=True))

    def on_passwordless(self, host):
        def ask_password(user, _bookmark):
            entry = Adw.PasswordEntryRow(title=t("Password for %s on %s", user, host), activates_default=True)
            dialog = self.dialog(
                t("Passwordless login"),
                t("Enter your password on %s once. After that, connecting won't ask for it.", host),
                extra=self.boxed(entry), ok=t("Set up"))

            def answered(_d, response):
                if response != "ok":
                    return
                self.toast(t("Setting up passwordless login…"))
                in_background(lambda: copy_key_to(host, user, entry.get_text()), done)
            dialog.connect("response", answered)
            dialog.present(self)

        def done(ok):
            if ok:
                self.toast(t("Connecting to %s won't ask for a password anymore.", host))
            else:
                self.show_error(t("Passwordless login wasn't set up"),
                                t("Check the username and password, and that %s is set up.", host))
        self.verify_then(host, lambda: self.with_username(host, ask_password))

    def on_forget_username(self, host):
        forget_username(host)
        self.toast(t("Karvan will ask for your username on %s next time.", host))
        self.search()

    # ----- This computer and security -----

    def clear(self, group):
        for row in getattr(group, "karvan_rows", []):
            group.remove(row)
        group.karvan_rows = []

    def add(self, group, row):
        group.add(row)
        group.karvan_rows.append(row)

    def refresh_this_computer(self):
        self.clear(self.this_computer)
        self.clear(self.security)
        if not is_set_up():
            row = Adw.ActionRow(
                title=t("Set up this computer"),
                subtitle=t("Do this once on each computer, so they can find and open each other."))
            row.add_prefix(Gtk.Image(icon_name="emblem-system-symbolic"))
            button = Gtk.Button(label=t("Set up"), valign=Gtk.Align.CENTER, css_classes=["suggested-action"])
            button.connect("clicked", lambda _b: self.app_setup())
            row.add_suffix(button)
            self.add(self.this_computer, row)
            self.security.set_visible(False)
            return

        for title, value in ((t("Network name"), f"{socket.gethostname()}.local"),
                             (t("Username"), USER), ("IP", this_computer_ip())):
            row = Adw.ActionRow(title=title, subtitle=value, use_markup=False,
                                subtitle_selectable=True, css_classes=["property"])
            self.add(self.this_computer, row)

        code = this_computer_code()
        row = Adw.ActionRow(title=t("Code"), subtitle=code, css_classes=["property"])
        copy = Gtk.Button(icon_name="edit-copy-symbolic", valign=Gtk.Align.CENTER,
                          css_classes=["flat"], tooltip_text=t("Copy"))
        copy.connect("clicked", lambda _b: self.copy_text(code))
        row.add_suffix(copy)
        self.add(self.this_computer, row)

        self.security.set_visible(True)
        keys = Adw.SwitchRow(title=t("Key login only"), active=SSHD_KEYS_ONLY.exists(),
                             subtitle=t("Nobody can log in to this computer by guessing your password"))
        keys.connect("notify::active", self.on_keys_only)
        self.add(self.security, keys)
        share = Adw.SwitchRow(title=t("Share only one folder"), active=SSHD_SHARE_ONLY.exists(),
                              subtitle=t("Other computers see only the Karvan folder in your home folder"))
        share.connect("notify::active", self.on_share_only)
        self.add(self.security, share)

    def app_setup(self):
        self.get_application().activate_action("setup", None)

    def change_setting(self, switch, heading, body, args, done_text, after=None):
        """Confirms, runs a karvan.sh admin task, and puts the switch back if anything fails."""
        if self.busy_toggle:
            return
        wanted = switch.get_active()

        def put_back():
            self.busy_toggle = True
            switch.set_active(not wanted)
            self.busy_toggle = False

        def finished(ok):
            switch.set_sensitive(True)
            if ok:
                if after:
                    after()
                self.toast(done_text)
            else:
                put_back()
                self.show_error(t("Couldn't change the setting"),
                                t("Nothing was changed. Try again, and enter the administrator password when asked."))

        def answered(_d, response):
            if response != "ok":
                put_back()
                return
            switch.set_sensitive(False)
            in_background(lambda: run_as_admin(*args), finished)

        dialog = self.dialog(heading, body, ok=t("Continue"))
        dialog.connect("response", answered)
        dialog.present(self)

    def on_keys_only(self, switch, _param):
        if switch.get_active():
            self.change_setting(
                switch, t("Turn on key login only?"),
                t("Other computers can then connect to this one only with passwordless login.\n\n"
                  "First, on each other computer, set up “Passwordless login” for this computer "
                  "and check that it works."),
                ("--root-password-login", "off"), t("Password login is off"))
        else:
            self.change_setting(
                switch, t("Turn password login back on?"), None,
                ("--root-password-login", "on"), t("Password login is on"))

    def on_share_only(self, switch, _param):
        if switch.get_active():
            def make_link():
                if not SHARE_LINK.exists() and not SHARE_LINK.is_symlink():
                    SHARE_LINK.symlink_to(SHARED_FOLDER)
            self.change_setting(
                switch, t("Share only one folder?"),
                t("Other computers will see only the Karvan folder in your home folder, not the rest "
                  "of your files.\n\nFirst, on each other computer, set up “Passwordless login” for "
                  "this computer. It can't be set up afterwards."),
                ("--root-share-only", "on"), t("Only the Karvan folder is shared"), make_link)
        else:
            self.change_setting(
                switch, t("Share your whole home folder again?"),
                t("The files in the Karvan folder stay where they are."),
                ("--root-share-only", "off"), t("Your whole home folder is shared again"))

    # ----- Dialog helpers -----

    def boxed(self, row):
        group = Adw.PreferencesGroup()
        group.add(row)
        return group

    def dialog(self, heading, body, extra=None, ok=None):
        dialog = Adw.AlertDialog(heading=heading, body=body or "")
        if extra:
            dialog.set_extra_child(extra)
        dialog.add_response("cancel", t("Cancel"))
        dialog.add_response("ok", ok or t("Continue"))
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("ok")
        dialog.set_close_response("cancel")
        return dialog


# ---------- Application ----------

class KarvanApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.window = None
        self.connect("activate", lambda _a: self.show_window())
        self.connect("startup", lambda _a: self.on_startup())

    def on_startup(self):
        Gtk.Window.set_default_icon_name("karvan")
        # libadwaita 1.5 (Ubuntu 24.04) lays the page out far too narrow when no DPI is set,
        # as in sessions without GNOME's settings daemon
        settings = Gtk.Settings.get_default()
        if settings.props.gtk_xft_dpi <= 0:
            settings.props.gtk_xft_dpi = 96 * 1024
        css = Gtk.CssProvider()
        css.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        language = Gio.SimpleAction.new("language", GLib.VariantType.new("s"))
        language.connect("activate", lambda _a, value: self.set_language(value.get_string()))
        self.add_action(language)
        for name, handler in (("setup", self.on_setup), ("about", self.on_about)):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda *_a, h=handler: h())
            self.add_action(action)

    def show_window(self):
        if not self.window:
            Gtk.Widget.set_default_direction(
                Gtk.TextDirection.RTL if UI_LANG == "fa" else Gtk.TextDirection.LTR)
            self.window = KarvanWindow(self)
        self.window.present()

    def set_language(self, language):
        global UI_LANG
        if language == UI_LANG:
            return
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        LANGUAGE_FILE.write_text(language + "\n")
        UI_LANG = language
        old, self.window = self.window, None
        self.show_window()
        old.destroy()

    def on_setup(self):
        window = self.window
        dialog = window.dialog(
            t("Set up this computer?"),
            t("Karvan will install and turn on the SSH server, make this computer visible on your "
              "home network, and allow connections from your home network only.\n\n"
              "You'll be asked for the administrator password."),
            ok=t("Set up"))

        def finished(ok):
            window.refresh_this_computer()
            if ok:
                window.toast(t("This computer is set up. Now set up the other one."))
            else:
                window.show_error(t("Setup didn't finish"),
                                  t("Check your internet connection and try again."))

        def answered(_d, response):
            if response == "ok":
                window.toast(t("Setting up… this can take a few minutes."))
                in_background(lambda: run_as_admin("--root-setup"), finished)
        dialog.connect("response", answered)
        dialog.present(window)

    def on_about(self):
        about = Adw.AboutDialog(
            application_name="Karvan", application_icon="karvan",
            developer_name="Patrick Der Avakians", license_type=Gtk.License.MIT_X11,
            website="https://github.com/moxart/karvan",
            comments=t("Browse the files of your other Ubuntu computers at home, right in Files."))
        about.add_legal_section(
            t("Icon"), None, Gtk.License.CUSTOM,
            t("From “Head of Asiatic Camel”, an engraving in Bayard Taylor's “Central Asia” "
              "(1891). Public domain."))
        about.present(self.window)


# ---------- Persian translations ----------

FA = {
    "Computers on your network": "کامپیوترهای شبکه",
    "This computer": "این کامپیوتر",
    "Security": "امنیت",
    "Search again": "جست‌وجوی دوباره",
    "Language": "زبان",
    "Run setup again": "راه‌اندازی دوباره",
    "About Karvan": "درباره‌ی Karvan",
    "Main menu": "منوی اصلی",
    "Files on your home computers": "فایل‌های کامپیوترهای خانه",
    "Open another computer's files right in Files.": "فایل‌های کامپیوتر دیگر را مستقیم در Files باز کنید.",
    "Searching…": "در حال جست‌وجو…",
    "No computers found": "کامپیوتری پیدا نشد",
    "Check that the other computer is on, on the same network, and set up.":
        "مطمئن شوید کامپیوتر دیگر روشن است، در همین شبکه است و راه‌اندازی شده است.",
    "Connect by name or IP": "اتصال با نام یا IP",
    "Open": "باز کردن",
    "Passwordless login": "ورود بدون رمز",
    "Use a different username": "استفاده از نام کاربری دیگر",
    "More": "بیشتر",
    "Name or IP": "نام یا IP",
    "For example, laptop.local or 192.168.1.20": "مثلاً laptop.local یا 192.168.1.20",
    "Connect": "اتصال",
    "Is this the right computer?": "کامپیوتر درست است؟",
    "On %s, open Karvan and look at the code under “This computer”. It should be the same as this one.":
        "Karvan را روی %s باز کنید و کد زیر «این کامپیوتر» را ببینید. باید با این کد یکی باشد.",
    "Codes differ": "کدها فرق دارند",
    "Codes match": "کدها یکی‌اند",
    "Your username on %s": "نام کاربری شما روی %s",
    "It may be different from your username on this computer.":
        "ممکن است با نام کاربری‌تان روی این کامپیوتر فرق داشته باشد.",
    "Show in the Files sidebar": "نمایش در نوار کناری Files",
    "Who are you on %s?": "روی %s با چه نامی وارد می‌شوید؟",
    "Continue": "ادامه",
    "Opening %s in Files…": "در حال باز کردن %s در Files…",
    "Password for %s on %s": "رمز %s روی %s",
    "Enter your password on %s once. After that, connecting won't ask for it.":
        "رمزتان روی %s را یک بار وارد کنید. بعد از آن، اتصال دیگر رمز نمی‌خواهد.",
    "Set up": "راه‌اندازی",
    "Setting up passwordless login…": "در حال راه‌اندازی ورود بدون رمز…",
    "Connecting to %s won't ask for a password anymore.": "اتصال به %s دیگر رمز نمی‌خواهد.",
    "Karvan will ask for your username on %s next time.":
        "دفعه‌ی بعد Karvan نام کاربری‌تان روی %s را می‌پرسد.",
    "Set up this computer": "راه‌اندازی این کامپیوتر",
    "Do this once on each computer, so they can find and open each other.":
        "این کار را یک بار روی هر کامپیوتر انجام دهید تا همدیگر را پیدا و باز کنند.",
    "Network name": "نام شبکه",
    "Username": "نام کاربری",
    "Code": "کد",
    "Copy": "کپی",
    "Code copied": "کد کپی شد",
    "Key login only": "فقط ورود با کلید",
    "Nobody can log in to this computer by guessing your password":
        "هیچ‌کس نمی‌تواند با حدس زدن رمز وارد این کامپیوتر شود",
    "Share only one folder": "اشتراک فقط یک پوشه",
    "Other computers see only the Karvan folder in your home folder":
        "کامپیوترهای دیگر فقط پوشه‌ی Karvan در پوشه‌ی خانه را می‌بینند",
    "Turn on key login only?": "فقط ورود با کلید روشن شود؟",
    "Other computers can then connect to this one only with passwordless login.\n\n"
    "First, on each other computer, set up “Passwordless login” for this computer and check that it works.":
        "بعد از این، کامپیوترهای دیگر فقط با ورود بدون رمز به این کامپیوتر وصل می‌شوند.\n\n"
        "اول روی هر کدام از کامپیوترهای دیگر، «ورود بدون رمز» را برای این کامپیوتر راه بیندازید "
        "و مطمئن شوید کار می‌کند.",
    "Password login is off": "ورود با رمز خاموش شد",
    "Turn password login back on?": "ورود با رمز دوباره روشن شود؟",
    "Password login is on": "ورود با رمز روشن شد",
    "Share only one folder?": "فقط یک پوشه به اشتراک گذاشته شود؟",
    "Other computers will see only the Karvan folder in your home folder, not the rest of your files.\n\n"
    "First, on each other computer, set up “Passwordless login” for this computer. "
    "It can't be set up afterwards.":
        "کامپیوترهای دیگر فقط پوشه‌ی Karvan در پوشه‌ی خانه را می‌بینند، نه بقیه‌ی فایل‌ها را.\n\n"
        "اول روی هر کدام از کامپیوترهای دیگر، «ورود بدون رمز» را برای این کامپیوتر راه بیندازید. "
        "بعد از این کار دیگر نمی‌شود آن را راه انداخت.",
    "Only the Karvan folder is shared": "فقط پوشه‌ی Karvan به اشتراک گذاشته شده است",
    "Share your whole home folder again?": "دوباره کل پوشه‌ی خانه به اشتراک گذاشته شود؟",
    "The files in the Karvan folder stay where they are.": "فایل‌های پوشه‌ی Karvan سر جایشان می‌مانند.",
    "Your whole home folder is shared again": "کل پوشه‌ی خانه دوباره به اشتراک گذاشته شد",
    "Cancel": "انصراف",
    "OK": "باشه",
    "That address isn't valid": "این نشانی معتبر نیست",
    "Use a name such as laptop.local or an IP address such as 192.168.1.20.":
        "نامی مثل laptop.local یا نشانی IP مثل 192.168.1.20 وارد کنید.",
    "Couldn't reach %s": "به %s دسترسی نیست",
    "Not connected": "وصل نشد",
    "If the codes are different, another device may be pretending to be %s.":
        "اگر کدها فرق دارند، ممکن است دستگاه دیگری خود را به‌جای %s جا زده باشد.",
    "That username isn't valid": "این نام کاربری معتبر نیست",
    "Use the username shown under “This computer” on %s.":
        "نام کاربری‌ای را وارد کنید که روی %s زیر «این کامپیوتر» نوشته شده است.",
    "Passwordless login wasn't set up": "ورود بدون رمز راه‌اندازی نشد",
    "Check the username and password, and that %s is set up.":
        "نام کاربری و رمز را بررسی کنید، و این‌که %s راه‌اندازی شده باشد.",
    "Couldn't change the setting": "تنظیم تغییر نکرد",
    "Nothing was changed. Try again, and enter the administrator password when asked.":
        "چیزی تغییر نکرد. دوباره امتحان کنید و وقتی رمز مدیر سیستم خواسته شد، آن را وارد کنید.",
    "Setup didn't finish": "راه‌اندازی تمام نشد",
    "Check your internet connection and try again.": "اتصال اینترنت را بررسی کنید و دوباره امتحان کنید.",
    "Set up this computer?": "این کامپیوتر راه‌اندازی شود؟",
    "Karvan will install and turn on the SSH server, make this computer visible on your home network, "
    "and allow connections from your home network only.\n\nYou'll be asked for the administrator password.":
        "Karvan سرور SSH را نصب و روشن می‌کند، این کامپیوتر را در شبکه‌ی خانه قابل دیدن می‌کند "
        "و فقط اتصال از شبکه‌ی خانه را اجازه می‌دهد.\n\nرمز مدیر سیستم از شما پرسیده می‌شود.",
    "This computer is set up. Now set up the other one.":
        "این کامپیوتر راه‌اندازی شد. حالا کامپیوتر دیگر را راه‌اندازی کنید.",
    "Setting up… this can take a few minutes.": "در حال راه‌اندازی… ممکن است چند دقیقه طول بکشد.",
    "Browse the files of your other Ubuntu computers at home, right in Files.":
        "فایل‌های کامپیوترهای اوبونتوی دیگر خانه را مستقیم در Files ببینید.",
    "Icon": "آیکون",
    "From “Head of Asiatic Camel”, an engraving in Bayard Taylor's “Central Asia” (1891). Public domain.":
        "برگرفته از «Head of Asiatic Camel»، حکاکی‌ای در کتاب «Central Asia» نوشته‌ی Bayard Taylor (۱۸۹۱). "
        "مالکیت عمومی.",
}


if __name__ == "__main__":
    KarvanApp().run(None)
