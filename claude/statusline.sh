#!/usr/bin/env bash
# BARTOSZ: pasek statusu w trzech wierszach — model │ repo │ gałąź, pod spodem limit 5h i kontekst jako paski.
# ICONS=0 zamienia ikony Nerd Font na zwykłe etykiety tekstowe. Wszystkie wiersze wypełniają szerokość
# okna (COLUMNS od Claude Code); MARGIN to zapas po prawej na wbudowane odstępy interfejsu,
# BAR_WIDTH to długość zapasowa, gdy szerokości okna nie da się ustalić.
ICONS=1
MARGIN=4
BAR_WIDTH=20

input=$(cat)

IFS=$'\x1f' read -r MODEL EFFORT DIR REPO CTX_PCT CTX_TOKENS CTX_SIZE FIVE_H RESET_5H < <(
  printf '%s' "$input" | jq -r '
    [ (.model.display_name // "Claude"),
      (.effort.level // ""),
      (.workspace.current_dir // .cwd // ""),
      (.workspace.repo.name // ""),
      (.context_window.used_percentage // 0 | floor),
      (.context_window.total_input_tokens // 0),
      (.context_window.context_window_size // 0),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // "")
    ] | map(tostring) | join("\u001f")'
)

R=$'\033[0m'; BOLD=$'\033[1m'
MAUVE=$'\033[38;2;203;166;247m'; BLUE=$'\033[38;2;137;180;250m'; PEACH=$'\033[38;2;250;179;135m'
GREEN=$'\033[38;2;87;174;58m'; YELLOW=$'\033[38;2;249;226;175m'; RED=$'\033[38;2;243;139;168m'
SUB=$'\033[38;2;127;132;156m'; TRACK=$'\033[38;2;69;71;90m'

if (( ICONS )); then
  I_REPO=$' '; I_BRANCH=$' '; I_LIMIT=$' '; I_CTX=$' '
else
  I_REPO=""; I_BRANCH=""; I_LIMIT="limit "; I_CTX="ctx   "
fi

hk() { local n=${1:-0}
  if (( n >= 1000000 )); then
    local t=$(( n / 100000 ))
    if (( t % 10 == 0 )); then echo "$(( t / 10 ))M"; else echo "$(( t / 10 )).$(( t % 10 ))M"; fi
  elif (( n >= 1000 )); then echo "$(( n / 1000 ))k"
  else echo "$n"; fi; }

color() { local pct=${1:-0}
  if   (( pct >= 90 )); then printf '%s' "$RED"
  elif (( pct >= 70 )); then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi; }

# BARTOSZ: procent wyrównany do trzech znaków, żeby opisy za paskami stały w jednej kolumnie.
pct() { printf '%s%3d%%%s' "$(color "$1")" "$1" "$R"; }

# BARTOSZ: cienki pasek na ciemnym torze, z dokładnością do pół komórki (╸).
bar() { local pct=${1:-0} width=${2:-$BAR_WIDTH} i s=""
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  local halves=$(( (pct * width * 2 + 50) / 100 ))
  local full=$(( halves / 2 )) half=$(( halves % 2 ))
  s+="$(color "$pct")"
  for (( i = 0; i < full; i++ )); do s+="━"; done
  (( half )) && s+="╸"
  s+="$TRACK"
  for (( i = full + half; i < width; i++ )); do s+="━"; done
  printf '%s' "$s$R"; }

rule() { local n=$1 i s=""; for (( i = 0; i < n; i++ )); do s+="─"; done; printf '%s' "$TRACK$s$R"; }

# BARTOSZ: skraca tekst do n znaków z "…" na końcu.
clip() { local s=$1 n=$2
  (( n < 1 )) && { printf ''; return; }
  if (( ${#s} > n )); then printf '%s…' "${s:0:n-1}"; else printf '%s' "$s"; fi; }

# BARTOSZ: czas pozostały do resetu okna. Wcześniej stała była tu etykieta "5h" — czyli
# długość okna, nie odliczanie — więc wyglądało to jakby licznik stał w miejscu.
eta() { local secs=${1:-0}
  (( secs < 0 )) && secs=0
  local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
  if (( h > 0 )); then printf '%dh %02dm' "$h" "$m"
  else printf '%dm' "$m"; fi; }

# --- szerokość okna: COLUMNS od Claude Code, awaryjnie rozmiar terminala sterującego
if (( ${COLUMNS:-0} <= 0 )); then
  COLUMNS=$({ stty size < /dev/tty; } 2>/dev/null | cut -d' ' -f2)
  (( ${COLUMNS:-0} > 0 )) || COLUMNS=0
fi
TOTAL=0
(( COLUMNS > 0 )) && TOTAL=$(( COLUMNS - MARGIN ))

# --- dane do wiersza 1: repo z remote'u origin, awaryjnie nazwa katalogu repo albo bieżącego
BRANCH=""; TOPLEVEL=""
if [ -n "$DIR" ]; then
  BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$DIR" rev-parse --short HEAD 2>/dev/null)
  TOPLEVEL=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)
fi
[ -z "$REPO" ] && REPO=$(basename "${TOPLEVEL:-$DIR}" 2>/dev/null)
# BARTOSZ: poza gitem to zwykły katalog — ikona folderu zamiast repozytorium.
[ -z "$TOPLEVEL" ] && (( ICONS )) && I_REPO=$' '

HEAD_TXT="$MODEL"; [ -n "$EFFORT" ] && HEAD_TXT+=" $EFFORT"

# BARTOSZ: wiersz 1 — repo zawsze dokładnie na środku, model przy lewej krawędzi, gałąź dosunięta do
# prawej; odstępy wypełniają linie "─". Gdy miejsca brak, repo skraca się do tego, na co pozwala lewa
# strona, a gałąź do tego, co zostaje po prawej. Bez znanej szerokości zostają zwykłe separatory "│".
MIN_RULE=3
LINE="${MAUVE}${BOLD}${MODEL}${R}"; [ -n "$EFFORT" ] && LINE+=" ${SUB}${EFFORT}${R}"
W1=${#HEAD_TXT}

if (( TOTAL > 0 )) && [ -n "$REPO" ]; then
  # BARTOSZ: repo szerokości WR startuje w (TOTAL-WR)/2; po lewej musi zmieścić się model, dwie spacje,
  # linia i dwie spacje — to wyznacza, jak szerokie repo może być.
  MAX_REPO=$(( TOTAL - 2 * (W1 + 4 + MIN_RULE) - ${#I_REPO} ))
  if (( MAX_REPO >= 4 )); then
    REPO=$(clip "$REPO" "$MAX_REPO")
    WR=$(( ${#I_REPO} + ${#REPO} ))
    START=$(( (TOTAL - WR) / 2 ))
    END=$(( START + WR ))
    LINE+="  $(rule $(( START - W1 - 4 )))  ${PEACH}${I_REPO}${REPO}${R}"
    [ -n "$BRANCH" ] && BRANCH=$(clip "$BRANCH" $(( TOTAL - END - 4 - MIN_RULE - ${#I_BRANCH} )))
    if [ -n "$BRANCH" ]; then
      WB=$(( ${#I_BRANCH} + ${#BRANCH} ))
      LINE+="  $(rule $(( TOTAL - END - 4 - WB )))  ${BLUE}${I_BRANCH}${BRANCH}${R}"
    else
      LINE+="  $(rule $(( TOTAL - END - 2 )))"   # bez gałęzi linia dochodzi do prawej krawędzi
    fi
  fi
elif (( TOTAL == 0 )); then
  [ -n "$REPO" ] && LINE+="  ${TRACK}│${R}  ${PEACH}${I_REPO}${REPO}${R}"
  [ -n "$BRANCH" ] && LINE+="  ${TRACK}│${R}  ${BLUE}${I_BRANCH}${BRANCH}${R}"
fi
printf '%s\n' "$LINE"

# --- opisy za paskami (czysty tekst, żeby dało się policzyć ich szerokość)
LIMIT_DETAIL=""
if [ -n "$FIVE_H" ]; then
  PCT=$(printf '%.0f' "$FIVE_H")
  # BARTOSZ: przy limicie tylko czas do resetu ("2h 14m"); bez resets_at opis zostaje pusty.
  [[ "$RESET_5H" =~ ^[0-9]+$ ]] && LIMIT_DETAIL="$(eta $(( RESET_5H - $(date +%s) )))"
fi
CTX=${CTX_PCT:-0}
CTX_DETAIL="$(hk "$CTX_TOKENS")"
(( CTX_SIZE > 0 )) && CTX_DETAIL+=" / $(hk "$CTX_SIZE")"

# BARTOSZ: długość pasków = szerokość okna minus ikona, procent, opis i margines. Kolumna opisu ma
# stałe minimum (najdłuższe odliczanie "4h 59m"), żeby paski nie skakały, gdy czas do resetu się skraca.
if (( TOTAL > 0 )); then
  DETAIL_W=${#CTX_DETAIL}
  if [ -n "$FIVE_H" ]; then
    (( ${#LIMIT_DETAIL} > DETAIL_W )) && DETAIL_W=${#LIMIT_DETAIL}
    (( DETAIL_W < 6 )) && DETAIL_W=6
  fi
  BAR_WIDTH=$(( TOTAL - ${#I_CTX} - 1 - 4 - 2 - DETAIL_W ))
  (( BAR_WIDTH < 10 )) && BAR_WIDTH=10
fi

# --- wiersz 2: limit 5h (tylko gdy są dane)
[ -n "$FIVE_H" ] && printf '%s\n' "${SUB}${I_LIMIT}${R}$(bar "$PCT") $(pct "$PCT")${LIMIT_DETAIL:+  ${SUB}${LIMIT_DETAIL}${R}}"

# --- wiersz 3: kontekst
printf '%s\n' "${SUB}${I_CTX}${R}$(bar "$CTX") $(pct "$CTX")  ${SUB}${CTX_DETAIL}${R}"
