#!/usr/bin/env bash
#
# Dotfiles Manager — a gum-powered TUI
#
# Tracks folder pairs:  system path  ←→  repo subfolder
# Pairs are stored in:  .tracked_folders  (same dir as this script)
#
# Usage: ./update_dotfiles.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKS_FILE="$SCRIPT_DIR/.tracked_folders"
BACKUP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles-manager/backups"

# ─── Global arrays (populated by load_tracks) ──────────────────────────────────
TRACK_LABELS=()     # "~/.config/hypr → hypr"  (shown in menus)
TRACK_SYS=()        # expanded system path  (for filesystem ops)
TRACK_SYS_RAW=()    # as stored in file     (for grep/removal)
TRACK_REPO=()       # full repo path        (for filesystem ops)
TRACK_REPO_REL=()   # relative repo path    (for grep/removal)

# ─── Styled output ─────────────────────────────────────────────────────────────

title() {
    gum style \
        --border double \
        --border-foreground 212 \
        --foreground 212 \
        --bold \
        --align center \
        --width 56 \
        --padding "1 2" \
        "$1"
}

section() {
    gum style \
        --border rounded \
        --border-foreground 99 \
        --foreground 99 \
        --bold \
        --padding "0 1" \
        "$1"
}

info()  { gum style --foreground 82  " ✓ $*"; }
warn()  { gum style --foreground 214 " ⚠ $*"; }
error() { gum style --foreground 196 " ✗ $*"; }
step()  { gum style --foreground 75  " → $*"; }

pause() {
    echo ""
    read -rsp $'\033[38;5;99m  Press ENTER to continue...\033[0m'
    echo ""
}

# ─── Dependencies ──────────────────────────────────────────────────────────────

check_deps() {
    local missing=()
    for cmd in gum diff rsync; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing required tools: ${missing[*]}"
        echo "  gum:   https://github.com/charmbracelet/gum"
        echo "  rsync: install via your package manager"
        exit 1
    fi
}

# ─── Track file helpers ────────────────────────────────────────────────────────

ensure_tracks_file() {
    [[ -f "$TRACKS_FILE" ]] || touch "$TRACKS_FILE"
}

# Trim leading and trailing whitespace from a string
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# Populate global parallel arrays from the tracks file
load_tracks() {
    ensure_tracks_file
    TRACK_LABELS=()
    TRACK_SYS=()
    TRACK_SYS_RAW=()
    TRACK_REPO=()
    TRACK_REPO_REL=()

    while IFS='|' read -r sys_raw repo_rel; do
        # Skip blank lines and comments
        [[ -z "${sys_raw// }" ]] && continue
        [[ "$sys_raw" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${repo_rel// }" ]] && continue

        sys_raw="$(trim "$sys_raw")"
        repo_rel="$(trim "$repo_rel")"

        TRACK_LABELS+=("$sys_raw → $repo_rel")
        TRACK_SYS+=("${sys_raw/#\~/$HOME}")
        TRACK_SYS_RAW+=("$sys_raw")
        TRACK_REPO+=("$SCRIPT_DIR/$repo_rel")
        TRACK_REPO_REL+=("$repo_rel")
    done < "$TRACKS_FILE"
}

# Return the array index matching a label string, or -1 if not found
find_idx() {
    local target="$1"
    local i=0
    for label in "${TRACK_LABELS[@]}"; do
        [[ "$label" == "$target" ]] && { echo "$i"; return 0; }
        i=$((i + 1))
    done
    echo -1
    return 1
}

# ─── Backup ────────────────────────────────────────────────────────────────────

do_backup() {
    local src="$1"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local dest="$BACKUP_DIR/$ts/$(basename "$src")"
    mkdir -p "$(dirname "$dest")"

    if [[ -d "$src" ]]; then
        cp -r "$src" "$dest" && step "Backed up → $dest"
    elif [[ -f "$src" ]]; then
        cp "$src" "$dest" && step "Backed up → $dest"
    else
        warn "Nothing to backup at $src"
    fi
}

# ─── Action: Diff ──────────────────────────────────────────────────────────────

action_diff() {
    section "View Diff"
    echo ""
    load_tracks

    if [[ ${#TRACK_LABELS[@]} -eq 0 ]]; then
        warn "No tracked folders configured. Add some first."
        pause; return
    fi

    local selected
    selected=$(gum choose --header "Select a folder pair to diff:" "${TRACK_LABELS[@]}") || return
    [[ -z "$selected" ]] && return

    local idx
    idx=$(find_idx "$selected")
    [[ "$idx" -lt 0 ]] && error "Could not resolve selection." && pause && return

    local sys="${TRACK_SYS[$idx]}"
    local repo="${TRACK_REPO[$idx]}"

    echo ""
    gum style --bold "Comparing:"
    gum style --foreground 75  "  System : $sys"
    gum style --foreground 212 "  Repo   : $repo"
    echo ""

    if [[ ! -e "$sys" ]]; then
        error "System path not found: $sys"
        pause; return
    fi
    if [[ ! -e "$repo" ]]; then
        error "Repo path not found: $repo"
        pause; return
    fi

    local diff_out
    diff_out=$(diff -r --color=always "$sys" "$repo" 2>&1) || true

    if [[ -z "$diff_out" ]]; then
        info "No differences — paths are in sync."
        pause
    else
        echo "$diff_out" | gum pager
    fi
}

# ─── Action: Push (System → Repo) ──────────────────────────────────────────────

action_push() {
    section "Push to Repo  (System → Repo)"
    echo ""
    load_tracks

    if [[ ${#TRACK_LABELS[@]} -eq 0 ]]; then
        warn "No tracked folders configured."
        pause; return
    fi

    local selections
    selections=$(gum choose --no-limit \
        --header "SPACE to select, ENTER to confirm — push system → repo:" \
        "${TRACK_LABELS[@]}") || return
    [[ -z "$selections" ]] && return

    local backup=no
    gum confirm "Create a backup of existing repo folders before pushing?" \
        && backup=yes || true

    echo ""
    local ok=0 fail=0

    while IFS= read -r selected; do
        [[ -z "$selected" ]] && continue
        local idx
        idx=$(find_idx "$selected")
        [[ "$idx" -lt 0 ]] && continue

        local sys="${TRACK_SYS[$idx]}"
        local repo="${TRACK_REPO[$idx]}"

        if [[ ! -e "$sys" ]]; then
            error "Source not found: $sys"
            fail=$((fail + 1))
            continue
        fi

        [[ "$backup" == yes ]] && [[ -e "$repo" ]] && do_backup "$repo"

        mkdir -p "$repo"
        if gum spin --spinner dot --title " Pushing $(basename "$sys")..." -- \
                rsync -a --delete "$sys/" "$repo/"; then
            info "Pushed: $sys → $repo"
            ok=$((ok + 1))
        else
            error "Failed: $sys → $repo"
            fail=$((fail + 1))
        fi
    done <<< "$selections"

    echo ""
    info "Done — $ok pushed, $fail failed."
    pause
}

# ─── Action: Update (Repo → System) ────────────────────────────────────────────

action_update() {
    section "Update from Repo  (Repo → System)"
    echo ""
    load_tracks

    if [[ ${#TRACK_LABELS[@]} -eq 0 ]]; then
        warn "No tracked folders configured."
        pause; return
    fi

    local selections
    selections=$(gum choose --no-limit \
        --header "SPACE to select, ENTER to confirm — update repo → system:" \
        "${TRACK_LABELS[@]}") || return
    [[ -z "$selections" ]] && return

    local backup=no
    gum confirm "Create a backup of existing system folders before updating?" \
        && backup=yes || true

    echo ""
    local ok=0 fail=0

    while IFS= read -r selected; do
        [[ -z "$selected" ]] && continue
        local idx
        idx=$(find_idx "$selected")
        [[ "$idx" -lt 0 ]] && continue

        local sys="${TRACK_SYS[$idx]}"
        local repo="${TRACK_REPO[$idx]}"

        if [[ ! -e "$repo" ]]; then
            error "Repo source not found: $repo"
            fail=$((fail + 1))
            continue
        fi

        [[ "$backup" == yes ]] && [[ -e "$sys" ]] && do_backup "$sys"

        mkdir -p "$sys"
        if gum spin --spinner dot --title " Updating $(basename "$sys")..." -- \
                rsync -a --delete "$repo/" "$sys/"; then
            info "Updated: $repo → $sys"
            ok=$((ok + 1))
        else
            error "Failed: $repo → $sys"
            fail=$((fail + 1))
        fi
    done <<< "$selections"

    echo ""
    info "Done — $ok updated, $fail failed."
    pause
}

# ─── Action: Manage Tracked Folders ────────────────────────────────────────────

action_manage() {
    while true; do
        clear
        echo ""
        section "Manage Tracked Folders"
        echo ""

        local choice
        choice=$(gum choose \
            "➕  Add folder pair" \
            "➖  Remove folder pair" \
            "📋  List tracked folders" \
            "← Back") || return

        echo ""
        case "$choice" in

            "➕  Add folder pair")
                # ── Pick system path via file browser ──────────────────────
                gum style --foreground 75 "  Navigate to the system folder and press ENTER to select:"
                local sys_path
                sys_path=$(gum file --all --directory "$HOME") || continue
                [[ -z "$sys_path" ]] && warn "Cancelled." && continue

                # Shrink $HOME → ~ for storage
                local sys_raw="${sys_path/#$HOME/\~}"

                # ── Pick repo subfolder ────────────────────────────────────
                local repo_pick
                repo_pick=$(gum choose \
                    "📂  Browse repo for existing folder" \
                    "✏️  Type a new subfolder name") || continue

                local repo_rel
                if [[ "$repo_pick" == "📂  Browse repo for existing folder" ]]; then
                    gum style --foreground 75 "  Navigate to the repo subfolder and press ENTER:"
                    local repo_path
                    repo_path=$(gum file --all --directory "$SCRIPT_DIR") || continue
                    [[ -z "$repo_path" ]] && warn "Cancelled." && continue
                    repo_rel="${repo_path#$SCRIPT_DIR/}"
                else
                    repo_rel=$(gum input \
                        --placeholder "hypr" \
                        --prompt "Repo subfolder name › ") || continue
                fi
                [[ -z "$repo_rel" ]] && warn "Cancelled." && continue

                ensure_tracks_file
                if grep -qxF "$sys_raw|$repo_rel" "$TRACKS_FILE"; then
                    warn "Already tracked: $sys_raw → $repo_rel"
                else
                    printf '%s|%s\n' "$sys_raw" "$repo_rel" >> "$TRACKS_FILE"
                    info "Added: $sys_raw → $repo_rel"
                fi
                pause
                ;;

            "➖  Remove folder pair")
                load_tracks
                if [[ ${#TRACK_LABELS[@]} -eq 0 ]]; then
                    warn "Nothing to remove."
                    pause; continue
                fi

                local to_remove
                to_remove=$(gum choose --no-limit \
                    --header "SPACE to select, ENTER to confirm removal:" \
                    "${TRACK_LABELS[@]}") || continue
                [[ -z "$to_remove" ]] && continue

                while IFS= read -r selected; do
                    [[ -z "$selected" ]] && continue
                    local idx
                    idx=$(find_idx "$selected")
                    [[ "$idx" -lt 0 ]] && continue

                    local raw_entry="${TRACK_SYS_RAW[$idx]}|${TRACK_REPO_REL[$idx]}"
                    grep -vxF "$raw_entry" "$TRACKS_FILE" > "${TRACKS_FILE}.tmp" \
                        && mv "${TRACKS_FILE}.tmp" "$TRACKS_FILE"
                    info "Removed: $selected"
                done <<< "$to_remove"

                load_tracks
                pause
                ;;

            "📋  List tracked folders")
                load_tracks
                echo ""
                if [[ ${#TRACK_LABELS[@]} -eq 0 ]]; then
                    warn "No tracked folders configured yet."
                else
                    local i=1
                    for label in "${TRACK_LABELS[@]}"; do
                        gum style --foreground 75 "  $i.  $label"
                        i=$((i + 1))
                    done
                fi
                pause
                ;;

            "← Back" | "")
                return
                ;;
        esac
    done
}

# ─── Main menu ─────────────────────────────────────────────────────────────────

main() {
    check_deps

    while true; do
        clear
        echo ""
        title "  Dotfiles Manager"
        echo ""

        local choice
        choice=$(gum choose \
            "🔍  View Diff" \
            "⬆   Push to Repo    (System → Repo)" \
            "⬇   Update from Repo  (Repo → System)" \
            "📁  Manage Tracked Folders" \
            "❌  Quit") || break

        echo ""
        case "$choice" in
            "🔍  View Diff")                        action_diff   ;;
            "⬆   Push to Repo    (System → Repo)")  action_push   ;;
            "⬇   Update from Repo  (Repo → System)") action_update ;;
            "📁  Manage Tracked Folders")            action_manage ;;
            "❌  Quit" | "")                         break         ;;
        esac
    done

    echo ""
    gum style --foreground 212 --bold "Goodbye! 👋"
    echo ""
}

main "$@"
