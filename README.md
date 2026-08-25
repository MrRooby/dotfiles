# dotfiles — sway + ly + waybar + wofi

A full desktop, rebuildable on a fresh Fedora install with one script.

```bash
git clone https://github.com/MrRooby/dotfiles.git ~/dotfiles
cd ~/dotfiles
./bootstrap.sh --dry-run     # see what it would do first
./bootstrap.sh               # then for real
```

---

## Two tools, two different jobs

| | When | What it does |
|---|---|---|
| `bootstrap.sh` | **once**, on a new machine | repos → packages → fonts → configs → themes → `/etc` → dconf → services |
| `update_dotfiles` | **day to day** | two-way sync repo ↔ system for the paths in `.tracked_folders` |

`bootstrap.sh` *copies* files rather than symlinking them, so `update_dotfiles`
keeps working normally afterwards.

---

## Stages

All of them can be filtered: `--only configs,themes` or `--skip packages,fonts`.

| Stage | What happens |
|---|---|
| `repos` | enables the COPRs in `packages/copr.txt` (keyd, Hyprland-Fedora) |
| `packages` | `dnf install` of the 44 packages in `packages/dnf.txt` |
| `fonts` | downloads JetBrainsMono Nerd Font from GitHub into `~/.local/share/fonts` |
| `autotiling` | `pip install --user autotiling` |
| `configs` | copies configs into `~/.config` |
| `themes` | icons → `~/.local/share/icons`, cursors → `~/.icons` |
| `wallpapers` | → `~/Pictures/wallpapers` |
| `system` | `/etc/ly`, `/etc/keyd`, enables `ly` and `keyd`, disables a competing DM |
| `dconf` | loads GTK/icon/cursor theme settings and nemo preferences |
| `caches` | `fc-cache` + `gtk-update-icon-cache` |

The script is idempotent. Everything it overwrites is backed up first to
`~/.local/share/dotfiles-manager/backups/bootstrap-<timestamp>/`.

---

## What's in here

```
bootstrap.sh          fresh-machine installer
update_dotfiles       day-to-day sync (TUI, needs `gum`)
.tracked_folders      system ↔ repo path map

packages/dnf.txt      package list
packages/copr.txt     COPR repositories

sway/  waybar/  wofi/  kitty/  hypr/  mako/  dunst/  nvim/
gtk-3.0/              nemo theme (gtk.css) + settings.ini
gtk-4.0/  qt6ct/  Kvantum/

icons/nostromo/       icon theme (orange folders)
icons/retro-cursor/   cursors + 120 X11/CSS name aliases
icons/RetroismIcons/  icons for Qt apps
icons/gtk_theme/

wallpapers/           used by sway and hyprpaper
system/ly/            config.ini + startup.sh for the display manager
system/keyd/          keyboard remapping
dconf/                dconf dumps + how to load them
```

---

## Hardware-specific bits

These are the only things you have to touch by hand after moving.

### Monitors

`sway/output.conf.example` came from a laptop (`eDP-1` + `HDMI-A-1`).
Bootstrap **will not overwrite** an existing `~/.config/sway/output.conf`;
if there isn't one it seeds it from the example and warns you.

```bash
swaymsg -t get_outputs        # the real output names
```

Note: the file header says `managed by xwlm, do not edit manually` — if you're
no longer using xwlm you can ignore that and write it by hand.

### Laptop → desktop

The whole config came from a laptop. On a desktop with no battery, remove:

- from `waybar/config.jsonc`: `custom/battery`, `backlight`, `custom/fan`
- from `sway/config`: the `bindswitch --locked lid:on ...` line and the
  `input "type:touchpad"` block

Bootstrap detects the missing battery and prints this at the end.

### Keyboard

`system/keyd/default.conf` maps `102nd` and `nonusbackslash` to `leftshift` —
that's for a specific keyboard (uniCorne). Probably unnecessary otherwise.

---

## Waybar — read this

`~/.config/waybar` is a separate repo: **github.com/MrRooby/nostromo-waybar**.
What lives in `dotfiles/waybar/` is a *snapshot* of it, not a submodule.

So: if you change something in waybar and don't push it to `nostromo-waybar`,
that change only exists in the snapshot. Before migrating:

```bash
cd ~/.config/waybar && git status      # check for uncommitted work
cd ~/dotfiles && ./update_dotfiles     # only then refresh the snapshot
```

---

## The gotcha that's easy to forget

Under Wayland, GTK3 reads its theme, icon theme and cursor theme from
**`org.gnome.desktop.interface` via xdg-desktop-portal**, and
`~/.config/gtk-3.0/settings.ini` is **ignored**.

That's why the theme is set by the `dconf` stage rather than by `settings.ini`.
If icons look wrong after install:

```bash
dconf load /org/gnome/desktop/interface/ < dconf/gnome-interface.ini
```

`gtk.css` is unaffected — that one is always read from `~/.config/gtk-3.0/gtk.css`.

---

## Moving it without GitHub

```bash
tar -czf dotfiles.tar.gz -C ~ dotfiles      # ~36 MB
# on the new machine:
tar -xzf dotfiles.tar.gz -C ~ && ~/dotfiles/bootstrap.sh
```
