# dconf

Each file is a dump of one subtree and must be loaded into that exact path —
`dconf dump` always writes `[/]` as its section header, so the path cannot be
inferred from the file itself.

| File | Load into |
|---|---|
| `gnome-interface.ini` | `/org/gnome/desktop/interface/` |
| `cinnamon-interface.ini` | `/org/cinnamon/desktop/interface/` |
| `nemo.ini` | `/org/nemo/` |

```bash
dconf load /org/gnome/desktop/interface/ < gnome-interface.ini
```

`gnome-interface.ini` is the important one: under Wayland, GTK3 reads its theme,
icon theme and cursor theme from here (via xdg-desktop-portal), **not** from
`~/.config/gtk-3.0/settings.ini`.
