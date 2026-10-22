#!/usr/bin/python3
#
# uniCorne key heatmap: a floating 3D view of how often each key is pressed,
# with the battery of both halves.
#
#   corne-heatmap.py [--demo] [--name NAME | --address MAC]
#
# Bound to a click on the keyboard module; a second click (or Esc) closes it.
# Each key is a column whose height and colour both follow its press count.
# Hover a key for the exact number, drag to turn the keyboard, double-click to
# turn it back. Letters do nothing on purpose: the popup has the focus, and
# typing to watch the columns grow must not close or change it.
#
# The counts come from the keyboard's key stats service (a2b40001-...), the
# same one keystats-cli talks to: one JSON command written to RX, one
# newline-terminated JSON line back as notifications on TX. Like corne.sh this
# rides on the connection the keyboard already has and never connects or
# disconnects it. While the popup is open it holds the notification stream, so
# keystats.py cannot be used at the same time.
#
# System python on purpose: it needs PyGObject (GTK 4), which a venv python
# would not have. Nothing else is required.

import argparse
import json
import math
import os
import select
import subprocess
import threading
import time

import cairo
import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

APP_ID = "corne.heatmap"

W, H = 760, 430   # fixed, so sway floats the window by itself
TOP = 30          # clears the bar, as in popup.sh
MARGIN = 10

FONT = "JetBrainsMono Nerd Font Mono"

BLUEZ = "org.bluez"
DEVICE_IFACE = "org.bluez.Device1"
CHRC_IFACE = "org.bluez.GattCharacteristic1"
RX_UUID = "a2b40002-9d84-4d17-986f-6b1daac0e668"
TX_UUID = "a2b40003-9d84-4d17-986f-6b1daac0e668"

REFRESH = 2.0   # s between reads while the popup is open
BATTERY_REFRESH = 60.0
BATTERY_WARN, BATTERY_CRIT = 20, 10   # %, as in corne.sh
BATTERY_UUID = "00002a19-0000-1000-8000-00805f9b34fb"
USER_DESCRIPTION_UUID = "00002901-0000-1000-8000-00805f9b34fb"
RETRY = 3.0     # s before looking for the keyboard again
REPLY_TIMEOUT = 5.0

CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "corne-heatmap.json"
)
THEME_CSS = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "waybar/current-theme.css"
)

# Default layer, by key position. Only used as captions.
LABELS = [
    "ESC", "Q", "W", "E", "R", "T",      "Y", "U", "I", "O", "P", "BSP",
    "TAB", "A", "S", "D", "F", "G",      "H", "J", "K", "L", ";", "'",
    "CTL", "Z", "X", "C", "V", "B",      "N", "M", ",", ".", "/", "SFT",
                    "GUI", "RSE", "ENT", "SPC", "LWR", "ALT",
]

# ---- keyboard geometry ----------------------------------------------------
#
# In key pitches (19 mm); x to the right, y away from the typist. The left half
# is laid out and the right one mirrored from it. Stagger and thumb positions
# are the switch positions of unicorne-3x6-chocolate-reversible.kicad_pcb.

STAGGER = [0.0, 0.0, 0.25, 0.375, 0.25, 0.125]   # column offsets, outer to inner
# between the two inner columns; wide enough that the inner thumb keys, which
# reach past them, stay clear of each other
HALF_GAP = 3.6
# x, y, turn in degrees, width, height. The innermost thumb key is 1.5u. The
# middle one also has a 1.5u footprint on the PCB, but a cap that long would
# run into its neighbour, so it is drawn as the 1u key it has to be.
THUMBS = [
    (3.5, -0.783, 0.0, 1.0, 1.0),
    (4.584, -0.893, -15.0, 1.0, 1.0),
    (5.755, -1.091, -30.0, 1.0, 1.5),
]
KEY_GAP = 0.1    # between neighbouring caps
MIN_HEIGHT = 0.07
MAX_HEIGHT = 2.3

VIEW_YAW = math.radians(-16)
VIEW_PITCH = math.radians(40)   # camera elevation; 90 would be straight down


def build_keys():
    """Return, per key position, the four ground corners and the turn of the key."""
    left = {}
    for row in range(3):
        for col in range(6):
            left[row * 12 + col] = (col, 2 - row + STAGGER[col], 0.0, 1.0, 1.0)
    for i, thumb in enumerate(THUMBS):
        left[36 + i] = thumb

    mirror_x = 5 + HALF_GAP / 2
    placed = dict(left)
    for row in range(3):
        for col in range(6):
            x, y, turn, w, h = left[row * 12 + col]
            placed[row * 12 + 11 - col] = (2 * mirror_x - x, y, -turn, w, h)
    for i in range(3):
        x, y, turn, w, h = left[36 + i]
        placed[41 - i] = (2 * mirror_x - x, y, -turn, w, h)

    xs = [p[0] for p in placed.values()]
    ys = [p[1] for p in placed.values()]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2

    keys = []
    for pos in range(42):
        x, y, turn, w, h = placed[pos]
        a = math.radians(turn)
        ca, sa = math.cos(a), math.sin(a)
        hw, hh = (w - KEY_GAP) / 2, (h - KEY_GAP) / 2
        corners = [
            (x - cx + dx * ca - dy * sa, y - cy + dx * sa + dy * ca)
            for dx, dy in ((-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh))
        ]
        keys.append({"center": (x - cx, y - cy), "corners": corners, "turn": a})
    return keys


KEYS = build_keys()
MODEL_WIDTH = max(c[0] for k in KEYS for c in k["corners"]) * 2

# ---- colour ---------------------------------------------------------------


def hex_to_rgb(value):
    value = value.lstrip("#")
    if len(value) == 3:
        value = "".join(ch * 2 for ch in value)
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))


def load_theme():
    """The palette of the active waybar theme, as corne.sh reads it."""
    defined = {}
    try:
        with open(THEME_CSS, encoding="utf-8") as file:
            for line in file:
                parts = line.split()
                if len(parts) >= 3 and parts[0] == "@define-color":
                    defined[parts[1]] = parts[2].rstrip(";")
    except OSError:
        pass

    def resolve(name, fallback):
        value = defined.get(name, "")
        for _ in range(10):
            if not value.startswith("@"):
                break
            value = defined.get(value[1:], "")
        try:
            return hex_to_rgb(value) if value.startswith("#") else hex_to_rgb(fallback)
        except ValueError:
            return hex_to_rgb(fallback)

    return {
        "bg": resolve("tooltip-bg", "#11111b"),
        "fg": resolve("tooltip-fg", "#d8cab8"),
        "dim": resolve("tooltip-dim", "#9b9b9b"),
        "accent": resolve("tooltip-br", "#CE6B29"),
        "warning": resolve("warning", "#f9e2af"),
        "critical": resolve("critical", "#f38ba8"),
    }


def _to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _to_srgb(c):
    c = min(max(c, 0.0), 1.0)
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def rgb_to_oklch(rgb):
    r, g, b = (_to_linear(c) for c in rgb)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    b2 = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(a, b2), math.atan2(b2, a)


def oklch_to_rgb(L, C, h):
    a, b = C * math.cos(h), C * math.sin(h)
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (
        _to_srgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        _to_srgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        _to_srgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    )


def make_ramp(accent):
    """A one-hue ramp for the dark surface: dim for few presses, bright for many.

    Lightness rises evenly so the order reads without the hue; the hue is the
    theme accent, drifting a little towards yellow at the bright end.
    """
    _, chroma, hue = rgb_to_oklch(accent)
    chroma = max(chroma, 0.08)
    cache = {}

    def ramp(t, light=1.0):
        """Colour for a share t of the busiest key; light < 1 gives a face in shade."""
        # in steps too fine to see, so a frame of the animation is mostly lookups
        step = (round(min(max(t, 0.0), 1.0) * 400), round(light * 50))
        if step not in cache:
            cache[step] = compute(step[0] / 400, step[1] / 50)
        return cache[step]

    def compute(t, light):
        L = 0.40 + 0.52 * t
        if t < 0.55:
            C = 0.045 + (chroma - 0.045) * (t / 0.55)
            h = hue
        else:
            u = (t - 0.55) / 0.45
            C = chroma + (0.10 - chroma) * u
            h = hue + math.radians(28) * u
        # darkened in lightness only, so a shaded face keeps the hue of its key
        return oklch_to_rgb(L * light, C * (0.5 + 0.5 * light), h)

    return ramp


def luminance(rgb):
    r, g, b = (_to_linear(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


# ---- data -----------------------------------------------------------------


class Unavailable(Exception):
    """The keyboard cannot be read right now; the message goes on screen."""


class Keyboard(threading.Thread):
    """Reads the counters in the background and hands them to the UI thread."""

    def __init__(self, name, address, on_counts, on_status, on_battery):
        super().__init__(daemon=True)
        self._name = name
        self._address = address
        self._on_counts = on_counts
        self._on_status = on_status
        self._on_battery = on_battery
        self.stopped = threading.Event()

    def run(self):
        while not self.stopped.is_set():
            try:
                self._session()
            except Unavailable as error:
                GLib.idle_add(self._on_status, str(error))
            except GLib.Error as error:
                GLib.idle_add(self._on_status, _dbus_reason(error))
            self.stopped.wait(RETRY)

    def _session(self):
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        try:
            device, right_battery, rx, tx = self._find(bus)
        except Unavailable:
            GLib.idle_add(self._on_battery, None, None)
            raise
        if rx is None:
            # older firmware: the batteries can still be shown
            GLib.idle_add(self._on_battery, *self._battery(bus, device, right_battery))
            raise Unavailable("firmware has no key stats service")

        # A socket that yields one notification per read; closing it turns
        # notifications off again.
        reply, fds = bus.call_with_unix_fd_list_sync(
            BLUEZ, tx, CHRC_IFACE, "AcquireNotify", GLib.Variant("(a{sv})", ({},)),
            GLib.VariantType("(hq)"), Gio.DBusCallFlags.NONE, 5000, None, None,
        )
        fd = fds.get(reply.unpack()[0])
        battery_due = 0.0
        try:
            while not self.stopped.is_set():
                counts = self._get(bus, rx, fd)
                GLib.idle_add(self._on_counts, counts)
                # after the counts, so the first picture is not held up by it
                if time.monotonic() >= battery_due:
                    GLib.idle_add(self._on_battery, *self._battery(bus, device, right_battery))
                    battery_due = time.monotonic() + BATTERY_REFRESH
                self.stopped.wait(REFRESH)
        finally:
            os.close(fd)

    def _battery(self, bus, device, right_battery):
        """Battery of the left and the right half in percent, None where unknown.

        The left half is the one BlueZ knows as the device's battery. The right
        one is relayed by the left as a second Battery Level characteristic,
        which has to be read directly -- see corne.sh.
        """
        left = right = None
        try:
            left = bus.call_sync(
                BLUEZ, device, "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", ("org.bluez.Battery1", "Percentage")),
                GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 2000, None,
            ).unpack()[0]
        except GLib.Error:
            pass
        if right_battery:
            try:
                # a live read over the air, so with a short timeout as in corne.sh
                value = bus.call_sync(
                    BLUEZ, right_battery, CHRC_IFACE, "ReadValue", GLib.Variant("(a{sv})", ({},)),
                    GLib.VariantType("(ay)"), Gio.DBusCallFlags.NONE, 2000, None,
                ).unpack()[0]
                right = value[0] if value else None
            except GLib.Error:
                pass
        return left, right

    def _find(self, bus):
        objects = bus.call_sync(
            BLUEZ, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", None,
            GLib.VariantType("(a{oa{sa{sv}}})"), Gio.DBusCallFlags.NONE, 3000, None,
        ).unpack()[0]

        device = None
        for path, ifaces in objects.items():
            props = ifaces.get(DEVICE_IFACE)
            if not props or not props.get("Paired"):
                continue
            if self._address:
                match = props.get("Address", "").lower() == self._address.lower()
            else:
                names = (props.get("Name", "").lower(), props.get("Alias", "").lower())
                match = self._name.lower() in names
            if match and (device is None or props.get("Connected")):
                device = (path, props)

        if device is None:
            raise Unavailable("keyboard is not paired")
        if not device[1].get("Connected"):
            raise Unavailable("keyboard is asleep — press a key")

        chars = {}
        right_battery = None
        described = {
            path.rsplit("/", 1)[0]
            for path, ifaces in objects.items()
            if ifaces.get("org.bluez.GattDescriptor1", {}).get("UUID", "").lower() == USER_DESCRIPTION_UUID
        }
        for path, ifaces in objects.items():
            if CHRC_IFACE not in ifaces or not path.startswith(device[0] + "/"):
                continue
            uuid = ifaces[CHRC_IFACE].get("UUID", "").lower()
            chars[uuid] = path
            # of the two Battery Level characteristics, the relayed one is the
            # one that carries a description ("Peripheral 0")
            if uuid == BATTERY_UUID and path in described:
                right_battery = path
        if RX_UUID not in chars or TX_UUID not in chars:
            return device[0], right_battery, None, None
        return device[0], right_battery, chars[RX_UUID], chars[TX_UUID]

    def _get(self, bus, rx, fd):
        # leftovers of a reply that timed out earlier
        while select.select([fd], [], [], 0)[0]:
            if not os.read(fd, 512):
                raise Unavailable("keyboard disconnected")

        command = GLib.Variant(
            "(aya{sv})", (b'{"cmd":"get"}', {"type": GLib.Variant("s", "request")})
        )
        for attempt in range(4):
            try:
                bus.call_sync(BLUEZ, rx, CHRC_IFACE, "WriteValue", command, None,
                              Gio.DBusCallFlags.NONE, 5000, None)
                break
            except GLib.Error as error:
                # 0xfe: still answering the previous command
                if "0xfe" not in error.message or attempt == 3:
                    raise
                time.sleep(0.3)

        buffer = b""
        deadline = time.monotonic() + REPLY_TIMEOUT
        while b"\n" not in buffer:
            if self.stopped.is_set() or time.monotonic() > deadline:
                raise Unavailable("keyboard did not answer")
            if select.select([fd], [], [], 0.2)[0]:
                data = os.read(fd, 512)
                if not data:
                    raise Unavailable("keyboard disconnected")
                buffer += data

        try:
            keys = json.loads(buffer.split(b"\n", 1)[0])["keys"]
        except (ValueError, KeyError, TypeError):
            raise Unavailable("keyboard sent an unreadable reply") from None
        if not isinstance(keys, list) or len(keys) != len(KEYS):
            raise Unavailable("keyboard reports a different layout")
        return keys


def _dbus_reason(error):
    message = error.message.split(": ", 1)[-1] if error.message else "Bluetooth error"
    if "Notify acquired" in message or "NotPermitted" in error.message:
        return "key stats are in use by another program"
    return message[:60]


def demo_counts():
    """Plausible counts for trying the popup without the keyboard."""
    weight = {
        "E": 127, "T": 91, "A": 82, "O": 75, "I": 70, "N": 67, "S": 63, "H": 61, "R": 60,
        "D": 43, "L": 40, "C": 28, "U": 28, "M": 24, "W": 24, "F": 22, "G": 20, "Y": 20,
        "P": 19, "B": 15, "V": 10, "K": 8, "J": 2, "X": 2, "Q": 1, "Z": 1,
        "SPC": 190, "BSP": 70, "ENT": 38, "SFT": 45, "CTL": 30, "TAB": 18, "ESC": 14,
        "LWR": 40, "RSE": 34, "GUI": 26, "ALT": 4, ",": 12, ".": 14, "/": 5, ";": 6, "'": 4,
    }
    return [weight.get(label, 3) * 37 for label in LABELS]


def load_cache():
    try:
        with open(CACHE, encoding="utf-8") as file:
            data = json.load(file)
        keys = data["keys"]
        if isinstance(keys, list) and len(keys) == len(KEYS):
            return keys, float(data.get("time", 0))
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None, 0.0


def save_cache(keys):
    try:
        with open(CACHE + ".tmp", "w", encoding="utf-8") as file:
            json.dump({"keys": keys, "time": time.time()}, file)
        os.replace(CACHE + ".tmp", CACHE)
    except OSError:
        pass


# ---- drawing --------------------------------------------------------------


def ease_out(p):
    p = min(max(p, 0.0), 1.0)
    return 1 - (1 - p) ** 3


def age_text(seconds):
    if seconds < 90:
        return "a moment ago"
    if seconds < 5400:
        return f"{round(seconds / 60)} min ago"
    if seconds < 129600:
        return f"{round(seconds / 3600)} h ago"
    return f"{round(seconds / 86400)} days ago"


class Scene:
    """Everything the popup shows, kept apart from GTK so it can be drawn anywhere."""

    def __init__(self, theme):
        self.theme = theme
        self.ramp = make_ramp(theme["accent"])
        self.counts = None
        self.level = [0.0] * len(KEYS)   # heights as drawn, 0..1
        self.yaw = VIEW_YAW
        self.pitch = VIEW_PITCH
        self.hover = None
        self.status = ""
        self.live = False
        self.battery = (None, None)      # left, right; percent or None
        self.faces = []                  # per key, the screen polygons last drawn
        self._extents = {}               # caption metrics, which never change
        self._font_options = cairo.FontOptions()
        # unhinted, so a caption measures the same however the key is turned
        self._font_options.set_hint_style(cairo.HINT_STYLE_NONE)
        self._font_options.set_hint_metrics(cairo.HINT_METRICS_OFF)

    def targets(self):
        if not self.counts:
            return [0.0] * len(KEYS)
        top = max(self.counts)
        return [c / top if top else 0.0 for c in self.counts]

    def _project(self, width, height):
        scale = (width - 2 * 38) / MODEL_WIDTH
        cy, sy = math.cos(self.yaw), math.sin(self.yaw)
        sp, cp = math.sin(self.pitch), math.cos(self.pitch)
        ox, oy = width / 2, height / 2 + 46

        def project(x, y, z):
            return (ox + scale * (x * cy - y * sy), oy - scale * ((x * sy + y * cy) * sp + z * cp))

        def depth(x, y):
            return x * sy + y * cy

        return project, depth, scale

    def draw(self, cr, width, height):
        theme = self.theme
        cr.set_source_rgb(*theme["bg"])
        cr.paint()

        project, depth, scale = self._project(width, height)
        cy, sy = math.cos(self.yaw), math.sin(self.yaw)
        sp = math.sin(self.pitch)
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        cr.set_font_options(self._font_options)
        cr.select_font_face(FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)

        self.faces = [None] * len(KEYS)
        order = sorted(range(len(KEYS)), key=lambda i: -depth(*KEYS[i]["center"]))
        for i in order:
            key = KEYS[i]
            level = self.level[i]
            z = MIN_HEIGHT + (MAX_HEIGHT - MIN_HEIGHT) * level
            colour = self.ramp(level)
            corners = key["corners"]
            polygons = []

            for n in range(4):
                (x1, y1), (x2, y2) = corners[n], corners[(n + 1) % 4]
                nx, ny = y2 - y1, x1 - x2            # outward normal of this side
                if depth(nx, ny) >= 0:
                    continue                          # faces away from the viewer
                side = [project(x1, y1, 0), project(x2, y2, 0), project(x2, y2, z), project(x1, y1, z)]
                # lit from the upper left
                light = 0.58 + 0.24 * max(0.0, (-nx * 0.6 - ny * 0.8) / math.hypot(nx, ny))
                self._fill(cr, side, self.ramp(level, light))
                polygons.append(side)

            top = [project(x, y, z) for x, y in corners]
            self._fill(cr, top, colour)
            polygons.append(top)
            self.faces[i] = polygons

            if i == self.hover:
                cr.set_source_rgb(*theme["fg"])
                cr.set_line_width(1.6)
                self._path(cr, top)
                cr.stroke()

            self._caption(cr, key, LABELS[i], project(*key["center"], z), colour, scale, cy, sy, sp)

        self._chrome(cr, width, height)

    def _path(self, cr, points):
        cr.move_to(*points[0])
        for point in points[1:]:
            cr.line_to(*point)
        cr.close_path()

    def _fill(self, cr, points, colour):
        self._path(cr, points)
        cr.set_source_rgb(*colour)
        cr.fill_preserve()
        # a hairline of the surface colour keeps neighbouring faces apart
        cr.set_source_rgb(*self.theme["bg"])
        cr.set_line_width(1.0)
        cr.stroke()

    def _caption(self, cr, key, text, origin, colour, scale, cy, sy, sp):
        """The key's label, lying flat on its top face."""
        a = key["turn"]
        ux, uy = math.cos(a), math.sin(a)        # along the key
        vx, vy = math.sin(a), -math.cos(a)       # towards the typist: down the text
        cr.save()
        cr.transform(cairo.Matrix(
            scale * (ux * cy - uy * sy), -scale * (ux * sy + uy * cy) * sp,
            scale * (vx * cy - vy * sy), -scale * (vx * sy + vy * cy) * sp,
            origin[0], origin[1],
        ))
        cr.set_font_size(0.4 if len(text) == 1 else 0.27)
        if text not in self._extents:
            extents = cr.text_extents(text)
            self._extents[text] = (-extents.x_bearing - extents.width / 2,
                                   -extents.y_bearing - extents.height / 2)
        cr.move_to(*self._extents[text])
        # ink that reads on this face: the surface colour on bright, the text colour on dim
        cr.set_source_rgb(*(self.theme["bg"] if luminance(colour) > 0.2 else self.theme["fg"]))
        cr.show_text(text)
        cr.restore()

    def _text(self, cr, text, x, y, colour, size=13, bold=False, align="left"):
        cr.select_font_face(FONT, cairo.FONT_SLANT_NORMAL,
                            cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(size)
        advance = cr.text_extents(text).x_advance
        if align == "right":
            x -= advance
        cr.move_to(x, y)
        cr.set_source_rgb(*colour)
        cr.show_text(text)
        return advance

    def _chrome(self, cr, width, height):
        theme = self.theme
        pad = 18

        advance = self._text(cr, "uniCorne", pad, 30, theme["accent"], 15, bold=True)
        self._text(cr, "key presses", pad + advance + 10, 30, theme["dim"])

        x = pad
        for label, level in zip(("Left", "Right"), self.battery):
            x = self._battery(cr, label, level, x, 49) + 20

        if self.counts:
            total = sum(self.counts)
            self._text(cr, f"{total:,} total", width - pad, 30, theme["fg"], align="right")
        if self.status:
            x = width - pad
            if self.live:
                cr.arc(x - 4, 45, 3, 0, 2 * math.pi)
                cr.set_source_rgb(*theme["accent"])
                cr.fill()
                x -= 14
            self._text(cr, self.status, x, 49, theme["dim"], 12, align="right")

        base = height - 18
        if self.hover is not None and self.counts:
            count = self.counts[self.hover]
            total = sum(self.counts)
            advance = self._text(cr, LABELS[self.hover], pad, base, theme["fg"], bold=True)
            share = f" · {100 * count / total:.1f}% of all" if total else ""
            noun = "press" if count == 1 else "presses"
            self._text(cr, f"{count:,} {noun}{share}", pad + advance + 12, base, theme["dim"])
        else:
            self._text(cr, "hover a key · drag to turn · esc to close", pad, base, theme["dim"], 12)

        if self.counts:
            # the scale: colour and height both run from 0 to the busiest key
            strip, top = 96, max(self.counts)
            right = width - pad
            advance = cr.text_extents(f"{top:,}").x_advance
            self._text(cr, f"{top:,}", right, base, theme["dim"], 12, align="right")
            x0 = right - advance - 8 - strip
            for n in range(strip):
                cr.set_source_rgb(*self.ramp(n / (strip - 1)))
                cr.rectangle(x0 + n, base - 9, 1.5, 9)
                cr.fill()
            self._text(cr, "0", x0 - 8, base, theme["dim"], 12, align="right")

    def _battery(self, cr, label, level, x, base):
        """One half's battery: label, gauge and percentage. Returns where it ends."""
        theme = self.theme
        x += self._text(cr, label, x, base, theme["dim"], 12) + 8
        if level is None:
            return x + self._text(cr, "–", x, base, theme["dim"], 12)

        # the gauge takes the state colour; the number stays in text colour
        if level <= BATTERY_CRIT:
            colour = theme["critical"]
        elif level <= BATTERY_WARN:
            colour = theme["warning"]
        else:
            colour = theme["accent"]
        gauge, height = 44, 6
        top = base - 8
        track = tuple(b + (d - b) * 0.3 for b, d in zip(theme["bg"], theme["dim"]))
        for width, fill in ((gauge, track), (max(height, gauge * min(level, 100) / 100), colour)):
            cr.new_sub_path()
            cr.arc(x + height / 2, top + height / 2, height / 2, math.pi / 2, 3 * math.pi / 2)
            cr.arc(x + width - height / 2, top + height / 2, height / 2, -math.pi / 2, math.pi / 2)
            cr.close_path()
            cr.set_source_rgb(*fill)
            cr.fill()
        x += gauge + 8
        return x + self._text(cr, f"{level}%", x, base, theme["fg"], 12)

    def key_at(self, x, y):
        """The key under the pointer, front-most first."""
        for i in sorted(range(len(KEYS)), key=lambda i: self._depth_of(i)):
            for polygon in self.faces[i] or ():
                if _inside(polygon, x, y):
                    return i
        return None

    def _depth_of(self, i):
        x, y = KEYS[i]["center"]
        return x * math.sin(self.yaw) + y * math.cos(self.yaw)


def _inside(polygon, x, y):
    inside = False
    for n in range(len(polygon)):
        (x1, y1), (x2, y2) = polygon[n], polygon[n - 1]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


# ---- window ---------------------------------------------------------------


class Popup(Gtk.Application):
    def __init__(self, args):
        super().__init__(application_id=APP_ID)
        self.args = args
        self.window = None
        self.keyboard = None
        self.scene = Scene(load_theme())
        self.cache_time = 0.0
        self.tick = None
        self.tween = None       # (start µs, duration s, from, to, delays)
        self.swing = None       # (start µs, duration s, extra yaw at the start)
        self.drag_from = None
        self.revealed = False
        self.frame = 0

    def do_activate(self):
        if self.window:          # the second click
            self.window.close()
            return

        GLib.set_prgname(APP_ID)
        out = os.environ.get("WAYBAR_OUTPUT_NAME", "")
        if out and os.environ.get("SWAYSOCK"):
            # sway opens windows on the focused output, not the clicked one
            subprocess.run(["swaymsg", "-q", "focus", "output", out], check=False)

        self.window = Gtk.ApplicationWindow(application=self, title="uniCorne key heatmap")
        self.window.set_default_size(W, H)
        self.window.set_resizable(False)
        self.window.set_decorated(False)
        self.window.connect("close-request", self.on_close)

        self.area = Gtk.DrawingArea()
        self.area.set_content_width(W)
        self.area.set_content_height(H)
        self.area.set_draw_func(lambda _area, cr, w, h: self.scene.draw(cr, w, h))
        self.window.set_child(self.area)

        motion = Gtk.EventControllerMotion()
        motion.connect("motion", self.on_motion)
        motion.connect("leave", lambda *_: self.set_hover(None))
        self.area.add_controller(motion)

        drag = Gtk.GestureDrag()
        drag.connect("drag-begin", self.on_drag_begin)
        drag.connect("drag-update", self.on_drag_update)
        drag.connect("drag-end", self.on_drag_end)
        self.area.add_controller(drag)

        click = Gtk.GestureClick()
        click.connect("pressed", self.on_click)
        self.area.add_controller(click)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.window.add_controller(keys)

        if self.args.demo:
            self.scene.counts = demo_counts()
            self.scene.battery = (64, 18)
            self.scene.status = "demo data"
        else:
            self.scene.counts, self.cache_time = load_cache()
            self.scene.status = "connecting…"
            self.keyboard = Keyboard(self.args.name, self.args.address,
                                     self.on_counts, self.on_status, self.on_battery)
            self.keyboard.start()

        # all but invisible until sway has put it in place, so it does not jump.
        # Not 0: a fully transparent window is never mapped, and sway cannot
        # move what it has not seen.
        self.window.set_opacity(0.01)
        self.window.present()
        self.place_tries = 0
        GLib.timeout_add(30, self.place)

    def place(self):
        """Float the window under the bar on the clicked output, then reveal it."""
        placed = not os.environ.get("SWAYSOCK")
        if not placed:
            try:
                outputs = json.loads(subprocess.run(
                    ["swaymsg", "-t", "get_outputs"], capture_output=True, text=True, check=False,
                ).stdout or "[]")
                name = os.environ.get("WAYBAR_OUTPUT_NAME", "")
                chosen = [o for o in outputs if (o.get("name") == name if name else o.get("focused"))]
                rect = (chosen or outputs)[0]["rect"]
                x = rect["x"] + rect["width"] - W - MARGIN - 4
                y = rect["y"] + TOP
                # "workspace current": sway may have opened the window on the
                # workspace waybar itself was started from rather than this one
                result = subprocess.run(
                    ["swaymsg", f'[app_id="{APP_ID}"] floating enable, border pixel 2, '
                                f"move container to workspace current, "
                                f"move absolute position {x} {y}, focus"],
                    capture_output=True, text=True, check=False,
                )
                placed = result.returncode == 0 and '"success": false' not in result.stdout
            except (OSError, ValueError, KeyError, IndexError):
                placed = True

        self.place_tries += 1
        if not placed and self.place_tries < 60:
            return GLib.SOURCE_CONTINUE

        self.window.set_opacity(1.0)
        self.revealed = True
        self.animate(intro=True)
        return GLib.SOURCE_REMOVE

    # ---- animation: only runs while something is moving ----

    def animate(self, intro=False):
        scene = self.scene
        now = self.area.get_frame_clock().get_frame_time() if self.area.get_frame_clock() else 0
        if intro:
            # columns rise outwards from the middle of the keyboard
            reach = max(math.hypot(*k["center"]) for k in KEYS)
            delays = [0.35 * math.hypot(*k["center"]) / reach for k in KEYS]
            self.tween = (now, 0.6, [0.0] * len(KEYS), scene.targets(), delays)
            self.swing = (now, 0.95, math.radians(-12))
        else:
            self.tween = (now, 0.3, list(scene.level), scene.targets(), [0.0] * len(KEYS))
        if self.tick is None:
            self.tick = self.area.add_tick_callback(self.on_tick)

    def on_tick(self, _area, clock):
        now = clock.get_frame_time()
        scene = self.scene
        busy = False

        # A frame costs a few ms, nearly all of it cairo stroking edges. The
        # opening runs at full rate; the small moves of a live update are drawn
        # on every other frame, which is not visible and halves their cost.
        self.frame += 1
        if self.swing is None and self.frame % 2:
            return GLib.SOURCE_CONTINUE

        if self.tween:
            start, duration, source, target, delays = self.tween
            if start == 0:
                start = now
                self.tween = (start, duration, source, target, delays)
            elapsed = (now - start) / 1e6
            for i in range(len(KEYS)):
                p = (elapsed - delays[i]) / duration
                scene.level[i] = source[i] + (target[i] - source[i]) * ease_out(p)
            if elapsed < duration + max(delays):
                busy = True
            else:
                self.tween = None

        if self.swing:
            start, duration, extra = self.swing
            if start == 0:
                start = now
                self.swing = (start, duration, extra)
            p = (now - start) / 1e6 / duration
            scene.yaw = VIEW_YAW + extra * (1 - ease_out(p))
            if p < 1:
                busy = True
            else:
                self.swing = None

        self.area.queue_draw()
        if busy:
            return GLib.SOURCE_CONTINUE
        self.tick = None
        return GLib.SOURCE_REMOVE

    # ---- data from the keyboard thread ----

    def on_counts(self, counts):
        scene = self.scene
        if not scene.live:
            scene.live = True
            scene.status = "live"
            self.area.queue_draw()
        if counts != scene.counts:
            scene.counts = counts
            save_cache(counts)
            if self.revealed:
                self.animate()
            self.area.queue_draw()
        return GLib.SOURCE_REMOVE

    def on_battery(self, left, right):
        if (left, right) != self.scene.battery:
            self.scene.battery = (left, right)
            self.area.queue_draw()
        return GLib.SOURCE_REMOVE

    def on_status(self, message):
        scene = self.scene
        if scene.counts and self.cache_time:
            message += f" · showing {age_text(time.time() - self.cache_time)}"
        if scene.live or message != scene.status:
            scene.live = False
            scene.status = message
            self.area.queue_draw()
        return GLib.SOURCE_REMOVE

    # ---- input ----

    def set_hover(self, key):
        if key != self.scene.hover:
            self.scene.hover = key
            self.area.queue_draw()

    def on_motion(self, _controller, x, y):
        if self.drag_from is None:
            self.set_hover(self.scene.key_at(x, y))

    def on_drag_begin(self, _gesture, _x, _y):
        self.swing = None
        self.drag_from = (self.scene.yaw, self.scene.pitch)
        self.set_hover(None)

    def on_drag_update(self, _gesture, dx, dy):
        if self.drag_from is None:
            return
        yaw, pitch = self.drag_from
        # the near edge follows the pointer
        self.scene.yaw = min(max(yaw + dx * 0.006, math.radians(-55)), math.radians(55))
        self.scene.pitch = min(max(pitch + dy * 0.006, math.radians(18)), math.radians(80))
        self.area.queue_draw()

    def on_drag_end(self, _gesture, _dx, _dy):
        self.drag_from = None

    def on_key(self, _controller, keyval, _code, _state):
        if keyval == Gdk.KEY_Escape:
            self.window.close()
        # everything else is swallowed too, so held keys do not beep or leak
        return True

    def on_click(self, _gesture, presses, _x, _y):
        if presses == 2:
            self.swing = None
            self.scene.yaw, self.scene.pitch = VIEW_YAW, VIEW_PITCH
            self.area.queue_draw()

    def on_close(self, _window):
        if self.keyboard:
            self.keyboard.stopped.set()
        return False


def main():
    parser = argparse.ArgumentParser(description="Floating 3D heatmap of the uniCorne's key presses.")
    parser.add_argument("--demo", action="store_true", help="show made-up counts instead of the keyboard's")
    parser.add_argument("--name", default="uniCorne", help="Bluetooth name of the keyboard")
    parser.add_argument("--address", help="Bluetooth address of the keyboard, instead of --name")
    args = parser.parse_args()

    # waybar passes on the startup token it was launched with; GTK would spend
    # it and open the popup on the workspace that token belongs to
    for name in ("DESKTOP_STARTUP_ID", "XDG_ACTIVATION_TOKEN"):
        os.environ.pop(name, None)
    # everything is drawn with cairo anyway; without the GL renderer the popup
    # starts sooner and takes about a third less memory
    os.environ.setdefault("GSK_RENDERER", "cairo")
    return Popup(args).run(None)


if __name__ == "__main__":
    raise SystemExit(main())
