# === boot ===

# p10k instant prompt. keep first.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi


# === omz core ===
ZSH=/usr/share/oh-my-zsh/


# === theme ===

# alt path:
# ZSH_THEME="powerlevel10k/powerlevel10k"

# hard source p10k
source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme

# tune prompt:
# p10k configure

# docs:
# https://github.com/romkatv/powerlevel10k


# === random theme pool ===
# live only if ZSH_THEME=random
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )


# === shell mode ===

# strict completion case
CASE_SENSITIVE="true"

# dash/_ blur
# HYPHEN_INSENSITIVE="true"


# === omz updates ===

# off
# zstyle ':omz:update' mode disabled

# auto
# zstyle ':omz:update' mode auto

# remind
# zstyle ':omz:update' mode reminder

# cadence
# zstyle ':omz:update' frequency 13


# === misc toggles ===

# paste safety off
# DISABLE_MAGIC_FUNCTIONS="true"

# no ls color
# DISABLE_LS_COLORS="true"

# no title writes
# DISABLE_AUTO_TITLE="true"

# typo repair
# ENABLE_CORRECTION="true"   # redundant with manual setopt below

# kill risky prompts
SPROMPT=""

# completion spinner
# COMPLETION_WAITING_DOTS="true"
# COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"

# faster big git repos
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# history date skin
# HIST_STAMPS="mm/dd/yyyy"


# === custom omz path ===
# ZSH_CUSTOM=/path/to/custom-folder


# === plugin rack ===
plugins=(
  # core
  git                              # git aliases
  # git-prompt                     # redundant with p10k git status
  aliases                          # inspect aliases
  common-aliases                   # common shorthand
  # sudo                           # ESC ESC -> sudo
  safe-paste                       # tame multiline paste
  command-not-found                # suggest package
  zsh-diff-so-fancy                # pretty git diff

  # nav
  # zoxide                         # redundant with manual zoxide init below
  zsh-navigation-tools             # fuzzy nav
  zsh-interactive-cd               # interactive cd
  wd                               # dir bookmarks
  fzf                              # fuzzy finder

  # env
  #conda                           # conda init
  #conda-env                       # conda helpers

  # platform
  archlinux                        # arch helpers

  # visuals
  colored-man-pages                # color man pages
  # fast-syntax-highlighting       # syntax glow
  zsh-autosuggestions              # inline history hints

  # misc
  # extract                        # unpack archives
  copybuffer                       # CTRL+O -> clipboard
  # zsh-you-should-use             # alias nags
)


# === zoxide ===
# smart jump engine
eval "$(zoxide init zsh)"


# === shell opts ===
setopt AUTO_CD                    # type dir -> cd
setopt AUTO_PUSHD                 # push on cd
setopt PUSHD_TO_HOME              # pushd -> ~
setopt PUSHD_SILENT               # mute stack print
setopt EXTENDED_GLOB              # richer globs
setopt NO_CASE_GLOB               # case-blind glob
setopt NO_BEEP                    # no bell
# setopt CORRECT                  # redundant once CORRECT_ALL is on
setopt CORRECT_ALL                # full-line correction
setopt NOTIFY                     # instant job notice
setopt PROMPT_SUBST               # dynamic prompt
setopt AUTO_LIST                  # list matches
setopt MENU_COMPLETE              # menu completion
setopt COMPLETE_IN_WORD           # mid-word complete
setopt ALWAYS_TO_END              # jump to word end
setopt INTERACTIVE_COMMENTS       # comments in shell
setopt MULTIOS                    # multi redirect
setopt LONG_LIST_JOBS             # verbose jobs


# === locale ===
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# === editor ===
# ssh -> vim / local -> subl
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='subl'
fi


# === omz cache ===
ZSH_CACHE_DIR=$HOME/.cache/oh-my-zsh
# bootstrapped once
# if [[ ! -d $ZSH_CACHE_DIR ]]; then
#   mkdir -p $ZSH_CACHE_DIR
# fi


# === completions ===
# extra completion path
fpath+=${ZSH_CUSTOM:-${ZSH:-~/.oh-my-zsh}/custom}/plugins/zsh-completions/src

# load compinit if absent
# if ! type compinit &>/dev/null; then   # redundant: omz handles compinit
#   autoload -Uz compinit && compinit
# fi


# === load omz ===
source $ZSH/oh-my-zsh.sh


# === manual plugins ===

# autopair
source /usr/share/zsh/plugins/zsh-autopair/autopair.zsh

# history substring search
source /usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.plugin.zsh

# arrows = substring search
bindkey "$terminfo[kcuu1]" history-substring-search-up
bindkey "$terminfo[kcud1]" history-substring-search-down

# thefuck bridge
# source /usr/share/zsh/plugins/zsh-thefuck-git/zsh-thefuck.plugin.zsh

# pay-respects
eval "$(pay-respects zsh --alias)"

# fzf-tab
source /usr/share/zsh/plugins/fzf-tab-git/fzf-tab.plugin.zsh


# === p10k config ===
# local prompt skin
# [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
source ~/.p10k.zsh


# === history ===
export HISTSIZE=50000000                        # mem cap
export SAVEHIST=10000000                        # disk cap
export HISTFILE=~/.zsh_history                  # vault

# write/share behavior
setopt INC_APPEND_HISTORY                       # write live
setopt APPEND_HISTORY                           # append only
setopt SHARE_HISTORY                            # cross-shell share
setopt EXTENDED_HISTORY                         # timestamps + duration
setopt HIST_VERIFY                              # confirm expansion

# dedupe / hygiene
setopt HIST_IGNORE_DUPS                         # skip adjacent dupes
setopt HIST_IGNORE_ALL_DUPS                     # skip all dupes
setopt HIST_SAVE_NO_DUPS                        # no dupes on save
setopt HIST_IGNORE_SPACE                        # leading-space = no log
setopt HIST_REDUCE_BLANKS                       # trim blanks
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_SUBST_PATTERN

# === path ===
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:/opt/anaconda/bin:$PATH"


# === lazy conda ===

: "${CONDA_BASE:=/opt/miniforge}"
typeset -g __CONDA_LAZY_INITIALIZED=0

__conda_lazy_init() {
  emulate -L zsh
  setopt local_options no_aliases

  (( __CONDA_LAZY_INITIALIZED )) && return 0

  local base="$CONDA_BASE"
  local conda_bin="$base/bin/conda"
  local conda_sh="$base/etc/profile.d/conda.sh"

  if [[ ! -x "$conda_bin" ]]; then
    print -u2 "conda: $conda_bin not found/executable (set CONDA_BASE correctly)"
    return 127
  fi

  # keep conda off prompt
  export CONDA_CHANGEPS1=no
  local __OLD_PROMPT="$PROMPT" __OLD_RPROMPT="$RPROMPT"

  # drop wrapper before real hook lands
  unalias conda 2>/dev/null
  unset -f conda 2>/dev/null

  local __conda_setup
  __conda_setup="$("$conda_bin" shell.zsh hook 2>/dev/null)" || __conda_setup=""
  if [[ -n "$__conda_setup" ]]; then
    eval "$__conda_setup"
  elif [[ -r "$conda_sh" ]]; then
    source "$conda_sh"
  else
    export PATH="$base/bin:$PATH"
  fi

  PROMPT="$__OLD_PROMPT"
  RPROMPT="$__OLD_RPROMPT"
  setopt PROMPT_SUBST

  __CONDA_LAZY_INITIALIZED=1
  return 0
}

__conda_lazy_wrapper() {
  emulate -L zsh
  setopt local_options

  __conda_lazy_init || return $?

  # hand off to real conda
  conda "$@"
}

# first-hit conda trap
alias conda='__conda_lazy_wrapper'

# openssl compat
export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1
