#!/usr/bin/env bash
# ==============================================================================
#  bootstrap.sh — rebuild the whole desktop (sway + ly + waybar + wofi)
#  on a fresh Fedora install.
#
#  Usage:
#     ./bootstrap.sh              # full install (asks to confirm first)
#     ./bootstrap.sh --dry-run    # print what it would do, change nothing
#     ./bootstrap.sh --only configs,themes
#     ./bootstrap.sh --skip packages,fonts
#
#  Stages: repos packages fonts autotiling configs themes wallpapers system dconf caches
#
#  Idempotent — safe to run repeatedly.
#  Anything it overwrites is copied first to ~/.local/share/dotfiles-manager/backups/
# ==============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles-manager/backups/bootstrap-$STAMP"
NERD_FONT_VER="v3.4.0"
DRY=0
FAILED=()

ALL_STAGES=(repos packages fonts autotiling configs themes wallpapers system dconf caches)
STAGES=("${ALL_STAGES[@]}")

# ─── output styling ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
    OK=$'\e[38;5;71m'; WARN=$'\e[38;5;214m'; ERR=$'\e[38;5;167m'; ACC=$'\e[38;5;173m'
else
    B=""; DIM=""; R=""; OK=""; WARN=""; ERR=""; ACC=""
fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s┌─ %s%s\n' "$ACC" "$*" "$R"; }
step()  { printf '%s│%s  %s\n' "$ACC" "$R" "$*"; }
good()  { printf '%s│%s  %s✓%s %s\n' "$ACC" "$R" "$OK" "$R" "$*"; }
warn()  { printf '%s│%s  %s!%s %s\n' "$ACC" "$R" "$WARN" "$R" "$*"; }
die()   { printf '\n%s✗ %s%s\n' "$ERR" "$*" "$R" >&2; exit 1; }
run()   { if (( DRY )); then printf '%s│%s  %s$ %s%s\n' "$ACC" "$R" "$DIM" "$*" "$R"; else "$@"; fi; }

has_stage() { [[ " ${STAGES[*]} " == *" $1 "* ]]; }

# ─── arguments ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --only)  IFS=',' read -ra STAGES <<< "$2"; shift 2 ;;
        --skip)  IFS=',' read -ra SK <<< "$2"
                 TMP=(); for s in "${STAGES[@]}"; do
                     [[ " ${SK[*]} " == *" $s "* ]] || TMP+=("$s")
                 done; STAGES=("${TMP[@]}"); shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1  (try --help)" ;;
    esac
done

# ─── sanity checks ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "don't run as root — the script calls sudo where it needs to."
command -v dnf >/dev/null || die "no dnf found; this script targets Fedora."
[[ -f "$REPO/packages/dnf.txt" ]] || die "can't find $REPO/packages — run this from the repo directory."

printf '%s\n' "${B}bootstrap — sway + ly + waybar + wofi${R}"
printf '%s\n' "${DIM}repo:    $REPO${R}"
printf '%s\n' "${DIM}stages:  ${STAGES[*]}${R}"
printf '%s\n' "${DIM}backups: $BACKUP${R}"
(( DRY )) && printf '%s\n' "${WARN}DRY RUN — nothing will be changed${R}"

if (( ! DRY )); then
    read -rp $'\nContinue? [y/N] ' a
    [[ "$a" =~ ^[yY]$ ]] || { say "aborted."; exit 0; }
    mkdir -p "$BACKUP"
    sudo -v || die "sudo is required"
    # keep sudo alive for the duration of the install
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
    SUDO_KEEP=$!
    trap 'kill $SUDO_KEEP 2>/dev/null' EXIT
fi

# copy a file/dir into place, backing up whatever was there
install_to() {           # install_to <repo-source> <absolute-target> [excludes...]
    local src="$1" dst="$2"; shift 2
    local ex=(--exclude '.git'); local e
    for e in "$@"; do ex+=(--exclude "$e"); done
    [[ -e "$src" ]] || { warn "not in repo: ${src#$REPO/}"; return 1; }
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        if (( ! DRY )); then
            mkdir -p "$BACKUP/$(dirname "${dst#$HOME/}")"
            cp -a "$dst" "$BACKUP/${dst#$HOME/}" 2>/dev/null || true
        fi
    fi
    run mkdir -p "$(dirname "$dst")"
    if [[ -d "$src" ]]; then
        run rsync -a --delete "${ex[@]}" "$src/" "$dst/"
    else
        run cp -a "$src" "$dst"
    fi
    good "${dst/#$HOME/\~}"
}

# ═══ 1. repositories ══════════════════════════════════════════════════════════
if has_stage repos; then
    head2 "COPR repositories"
    while read -r line; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        step "copr enable $line"
        run sudo dnf copr enable -y "$line" || warn "could not enable $line"
    done < "$REPO/packages/copr.txt"
fi

# ═══ 2. packages ══════════════════════════════════════════════════════════════
if has_stage packages; then
    head2 "Packages"
    mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$REPO/packages/dnf.txt")
    step "${#PKGS[@]} packages from packages/dnf.txt"
    if (( DRY )); then
        run sudo dnf install -y "${PKGS[@]}"
    else
        # --skip-unavailable so one renamed package doesn't abort the whole run
        sudo dnf install -y --skip-unavailable "${PKGS[@]}" || FAILED+=("dnf install")
        good "packages installed"
    fi
fi

# ═══ 3. fonts ═════════════════════════════════════════════════════════════════
if has_stage fonts; then
    head2 "Fonts (JetBrainsMono Nerd Font $NERD_FONT_VER)"
    FD="$HOME/.local/share/fonts"
    if compgen -G "$FD/JetBrainsMonoNerdFont*" >/dev/null; then
        good "already installed — skipping"
    else
        URL="https://github.com/ryanoasis/nerd-fonts/releases/download/$NERD_FONT_VER/JetBrainsMono.zip"
        step "downloading $URL"
        run mkdir -p "$FD"
        if (( ! DRY )); then
            TMPZ="$(mktemp -d)"
            if curl -fSL --retry 3 -o "$TMPZ/jb.zip" "$URL"; then
                unzip -qo "$TMPZ/jb.zip" -d "$FD" -x 'README*' 'LICENSE*' 'OFL*'
                good "unpacked into ~/.local/share/fonts"
            else
                FAILED+=("Nerd Font download — grab it manually from nerdfonts.com")
                warn "download failed"
            fi
            rm -rf "$TMPZ"
        fi
    fi
fi

# ═══ 4. autotiling ════════════════════════════════════════════════════════════
if has_stage autotiling; then
    head2 "autotiling"
    if command -v autotiling >/dev/null; then
        good "already on PATH"
    else
        step "pip install --user autotiling"
        run python3 -m pip install --user --break-system-packages autotiling \
            || { warn "pip failed"; FAILED+=("autotiling"); }
    fi
fi

# ═══ 5. user configs ══════════════════════════════════════════════════════════
if has_stage configs; then
    head2 "Configs → ~/.config"
    # output.conf is monitor-specific — never carry it over from the old machine
    install_to "$REPO/sway"    "$HOME/.config/sway" 'output.conf' 'output.conf.example'
    install_to "$REPO/waybar"  "$HOME/.config/waybar"
    install_to "$REPO/wofi"    "$HOME/.config/wofi"
    install_to "$REPO/kitty"   "$HOME/.config/kitty"
    install_to "$REPO/hypr"    "$HOME/.config/hypr"
    install_to "$REPO/mako"    "$HOME/.config/mako"
    install_to "$REPO/dunst"   "$HOME/.config/dunst"
    install_to "$REPO/gtk-3.0" "$HOME/.config/gtk-3.0"
    install_to "$REPO/gtk-4.0" "$HOME/.config/gtk-4.0"
    install_to "$REPO/qt6ct"   "$HOME/.config/qt6ct"
    install_to "$REPO/Kvantum" "$HOME/.config/Kvantum"
    [[ -d "$REPO/nvim" ]] && install_to "$REPO/nvim" "$HOME/.config/nvim"
    [[ -f "$REPO/zshrc" ]] && install_to "$REPO/zshrc" "$HOME/.zshrc"

    if [[ -f "$HOME/.config/sway/output.conf" ]]; then
        good "~/.config/sway/output.conf left untouched (monitor-specific)"
    else
        run cp "$REPO/sway/output.conf.example" "$HOME/.config/sway/output.conf"
        warn "output.conf seeded from the example — EDIT IT for the new monitors (see below)"
    fi
fi

# ═══ 6. icon and cursor themes ════════════════════════════════════════════════
if has_stage themes; then
    head2 "Icon and cursor themes"
    for t in nostromo RetroismIcons gtk_theme; do
        [[ -d "$REPO/icons/$t" ]] && install_to "$REPO/icons/$t" "$HOME/.local/share/icons/$t"
    done
    install_to "$REPO/icons/retro-cursor" "$HOME/.icons/retro-cursor"
fi

# ═══ 7. wallpapers ════════════════════════════════════════════════════════════
if has_stage wallpapers; then
    head2 "Wallpapers"
    install_to "$REPO/wallpapers" "$HOME/Pictures/wallpapers"
fi

# ═══ 8. system files + services ═══════════════════════════════════════════════
if has_stage system; then
    head2 "System files (/etc) and services"
    if [[ -f "$REPO/system/ly/config.ini" ]]; then
        run sudo mkdir -p /etc/ly
        (( DRY )) || sudo cp /etc/ly/config.ini "/etc/ly/config.ini.bak-$STAMP" 2>/dev/null || true
        run sudo cp "$REPO/system/ly/config.ini" /etc/ly/config.ini
        [[ -f "$REPO/system/ly/startup.sh" ]] && run sudo cp "$REPO/system/ly/startup.sh" /etc/ly/startup.sh
        good "/etc/ly"
    fi
    if [[ -f "$REPO/system/keyd/default.conf" ]]; then
        run sudo mkdir -p /etc/keyd
        run sudo cp "$REPO/system/keyd/default.conf" /etc/keyd/default.conf
        good "/etc/keyd"
    fi
    step "enabling ly and keyd"
    run sudo systemctl enable ly.service    || warn "ly.service — check the unit name"
    run sudo systemctl enable --now keyd    || warn "keyd.service"
    # ly takes over the TTY — disable any competing display manager
    for dm in gdm sddm lightdm; do
        if systemctl is-enabled "$dm" &>/dev/null; then
            warn "$dm is enabled and will fight ly — disabling it"
            run sudo systemctl disable "$dm"
        fi
    done
fi

# ═══ 9. dconf ═════════════════════════════════════════════════════════════════
if has_stage dconf; then
    head2 "dconf (GTK/icon/cursor theme + nemo preferences)"
    load_dconf() {
        [[ -s "$2" ]] || return 0
        if (( DRY )); then step "dconf load $1 < ${2#$REPO/}"; return 0; fi
        dconf load "$1" < "$2" && good "$1" || warn "failed to load $1"
    }
    load_dconf /org/gnome/desktop/interface/    "$REPO/dconf/gnome-interface.ini"
    load_dconf /org/cinnamon/desktop/interface/ "$REPO/dconf/cinnamon-interface.ini"
    load_dconf /org/nemo/                       "$REPO/dconf/nemo.ini"
fi

# ═══ 10. caches ═══════════════════════════════════════════════════════════════
if has_stage caches; then
    head2 "Rebuilding caches"
    run fc-cache -f >/dev/null 2>&1 && good "font cache"
    for t in "$HOME/.local/share/icons"/*/; do
        [[ -f "$t/index.theme" ]] && run gtk-update-icon-cache -qf "$t" 2>/dev/null
    done
    good "icon caches"
fi

# ═══ summary ══════════════════════════════════════════════════════════════════
printf '\n%s%s%s\n' "$B" "─────────── done ───────────" "$R"

if (( ${#FAILED[@]} )); then
    printf '\n%sFailed:%s\n' "$ERR" "$R"
    printf '  • %s\n' "${FAILED[@]}"
fi

printf '\n%sCheck these before you log in:%s\n\n' "$B" "$R"

printf '  %s1. Monitors%s\n' "$B" "$R"
printf '     ~/.config/sway/output.conf came from the old machine\n'
printf '     (eDP-1 + HDMI-A-1). Output names on the new PC will differ.\n'
printf '     Find the real ones: %sswaymsg -t get_outputs%s   (or wlr-randr)\n\n' "$ACC" "$R"

if [[ -n "$(ls /sys/class/power_supply/BAT* 2>/dev/null)" ]]; then
    printf '  %s2. Battery: detected%s — battery/backlight modules stay as they are.\n\n' "$B" "$R"
else
    printf '  %s2. Battery: NONE (this is a desktop)%s\n' "$B" "$R"
    printf '     This config came from a laptop. Remove from waybar config.jsonc:\n'
    printf '     %scustom/battery, backlight, custom/fan%s — and from the sway config\n' "$ACC" "$R"
    printf '     the bindswitch lid:on line and the input "type:touchpad" block.\n\n'
fi

printf '  %s3. Waybar%s\n' "$B" "$R"
printf '     The config lives in your own repo %sgithub.com/MrRooby/nostromo-waybar%s,\n' "$ACC" "$R"
printf '     but what ships here is a SNAPSHOT of it. If you changed anything locally\n'
printf '     and never pushed, push it before relying on this copy.\n\n'

printf '  %s4. Keyboard%s\n' "$B" "$R"
printf '     /etc/keyd/default.conf maps 102nd/nonusbackslash to leftshift.\n'
printf '     Probably unnecessary on a different keyboard.\n\n'

printf '  Then: %ssudo systemctl reboot%s — ly comes up and you pick the Sway session.\n\n' "$ACC" "$R"

(( DRY )) && printf '%s(that was a dry run — nothing changed)%s\n\n' "$WARN" "$R"
exit 0
