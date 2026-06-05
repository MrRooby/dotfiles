# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Directory for zinit and plugins
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Download zinit, if it's not present
if [ ! -d "$ZINIT_HOME" ]; then
    mkdir -p "$(dirname $ZINIT_HOME)"
    git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

# Source/Load zinit
source "${ZINIT_HOME}/zinit.zsh"

# Set theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Add in zsh plugins
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-completions
zinit light zsh-users/zsh-autosuggestions
zinit light Aloxaf/fzf-tab

# Load completions
autoload -U compinit && compinit

# Paths configurations
export GRADLE_HOME=/usr/local/gradle/gradle-8.12.1
export BUN_INSTALL="$HOME/.bun"

# Combine PATH modifications into a single line to reduce overhead
export PATH="$GRADLE_HOME/bin:$HOME/.cargo/bin:$HOME/.local/bin:$BUN_INSTALL/bin:$HOME/matlab/bin:/home/bartek/ghidra/ghidra_12.0.4_PUBLIC:/home/bartek/.spicetify:$PATH"

plugins=(git)
source $ZSH/oh-my-zsh.sh

# Keybindings
bindkey -e
bindkey '^p' history-search-backward
bindkey '^n' history-search-forward

# History Settings
HISTSIZE=5000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Completions styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completino:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'

# Aliases
alias ls='ls --color'

# Shell integrations (Statically source fzf features if possible, or keep eval)
eval "$(fzf --zsh)"

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Stop screaming at my cow 
typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

# Default editors
export VISUAL=nvim
export EDITOR=nvim

# Bun completions
[ -s "/home/bartek/.bun/_bun" ] && source "/home/bartek/.bun/_bun"


# --- OPTIMIZED LAZY-LOADING FOR NVM ---
export NVM_DIR="$HOME/.nvm"
declare -a __node_commands=('nvm' 'node' 'npm' 'yarn' 'npx' 'corepack')

function __load_nvm() {
    for cmd in "${__node_commands[@]}"; do
        unfunction "$cmd"
    done
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
}

for cmd in "${__node_commands[@]}"; do
    eval "function $cmd() { __load_nvm; $cmd \"\$@\"; }"
done
# --------------------------------------


# Cow at the beginning of shell (Runs asynchronously or after instant prompt completes)
if [[ -x $(command -v fortune) && -x $(command -v cowsay) ]]; then
    fortune | cowsay
fi
