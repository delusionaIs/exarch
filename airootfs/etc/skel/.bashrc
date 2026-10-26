# ~/.bashrc  ::  Exarch
# shellcheck disable=SC1090,SC1091,SC2016  # sourced files only exist on the target system
# Violet bash: ble.sh (fish-style autosuggestions + syntax highlighting),
# starship prompt, fzf, zoxide, eza, bat. Every piece is optional: if a tool
# is missing, its section is skipped and plain bash still looks right.
# Your own additions go in ~/.bashrc.local (sourced at the end).

[[ $- == *i* ]] || return

# --- ble.sh: load first, attach last (as its docs require) ---------------------
if [[ -z "${EXARCH_NO_BLE-}" && -f /usr/share/blesh/ble.sh ]]; then
  source /usr/share/blesh/ble.sh --noattach
fi

# --- environment --------------------------------------------------------------
export EDITOR=nvim VISUAL=nvim
export BAT_THEME=ansi                       # uses the terminal's violet palette
export LESS='-R --mouse --use-color -Dd+m$Du+c$DP+kM -i -j.3'
if command -v bat >/dev/null; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
  export MANROFFOPT='-c'
fi

# --- history ------------------------------------------------------------------
HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth:erasedups
HISTIGNORE='ls:ll:la:cd:pwd:exit:clear:history'
HISTTIMEFORMAT='%F %T  '
shopt -s histappend cmdhist
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# --- shell behaviour ----------------------------------------------------------
shopt -s autocd cdspell dirspell globstar extglob checkwinsize no_empty_cmd_completion
stty -ixon 2>/dev/null                      # free Ctrl-S for forward history search

# --- completion ---------------------------------------------------------------
[[ -r /usr/share/bash-completion/bash_completion ]] && source /usr/share/bash-completion/bash_completion
# "command not found" -> which package has it
[[ -r /usr/share/doc/pkgfile/command-not-found.bash ]] && source /usr/share/doc/pkgfile/command-not-found.bash

# --- colours: eza / grep / ip / diff ------------------------------------------
# di=directories, ex=executables, ln=links: Exarch violet family
export EZA_COLORS='di=1;38;2;154;92;255:ex=38;2;91;227;160:ln=38;2;77;217;255:uu=38;2;200;160;255:gu=38;2;122;47;224:da=38;2;154;154;162:hd=4;38;2;154;92;255'
export GREP_COLORS='mt=1;38;2;200;160;255:fn=38;2;154;92;255:ln=38;2;106;106;112:se=38;2;74;68;88'

if command -v eza >/dev/null; then
  alias ls='eza --icons --group-directories-first'
  alias ll='eza -l --icons --git --group-directories-first --time-style=relative'
  alias la='eza -la --icons --git --group-directories-first --time-style=relative'
  alias lt='eza --tree --level=2 --icons --group-directories-first'
else
  alias ls='ls --color=auto --group-directories-first'
  alias ll='ls -lh'
  alias la='ls -lAh'
fi
command -v bat >/dev/null && alias cat='bat --paging=never --style=plain'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias k=kubectl
alias tf=tofu
alias please='sudo $(fc -ln -1)'
# Same completions for the short aliases
if command -v kubectl >/dev/null && declare -F __start_kubectl >/dev/null 2>&1; then
  complete -o default -F __start_kubectl k
fi

# --- fzf: violet, with previews -----------------------------------------------
export FZF_DEFAULT_OPTS="--layout=reverse --height=45% --border=rounded --info=inline-right \
--prompt='❯ ' --pointer='▌' --marker='┃' \
--color=fg:#c8c6d0,fg+:#ffffff,bg+:#2a1450,hl:#c8a0ff,hl+:#c8a0ff,info:#6a6a70 \
--color=prompt:#9a5cff,pointer:#9a5cff,marker:#5be3a0,spinner:#9a5cff,header:#6a6a70,border:#5a28aa"
if command -v fd >/dev/null; then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
fi
export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=numbers --line-range=:200 {} 2>/dev/null'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --icons --color=always {} 2>/dev/null'"

if [[ -d /usr/share/fzf ]]; then
  if [[ ${BLE_VERSION-} ]]; then
    _ble_contrib_fzf_base=/usr/share/fzf
    ble-import -d integration/fzf-completion
    ble-import -d integration/fzf-key-bindings
  else
    source /usr/share/fzf/key-bindings.bash
    source /usr/share/fzf/completion.bash
  fi
fi

# --- zoxide: z <part of a dir>, zi to pick ------------------------------------
command -v zoxide >/dev/null && eval "$(zoxide init bash)"

# --- prompt -------------------------------------------------------------------
if command -v starship >/dev/null; then
  eval "$(starship init bash)"
else
  # Fallback with the same shape as the starship prompt
  __exarch_ps1() {
    local s=$? v='\[\e[1;38;2;154;92;255m\]' d='\[\e[38;2;106;106;112m\]' w='\[\e[1;38;2;222;222;226m\]'
    local r='\[\e[0m\]' arrow='\[\e[1;38;2;154;92;255m\]'
    (( s )) && arrow='\[\e[1;38;2;255;77;109m\]'
    local br; br="$(git branch --show-current 2>/dev/null)"
    PS1="${v}┌─\u${d}@\h ${w}\w${br:+ ${v} $br}${r}\n${arrow}└─▶${r} "
  }
  PROMPT_COMMAND="__exarch_ps1${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi

# --- ble.sh: violet theme ------------------------------------------------------
if [[ ${BLE_VERSION-} ]]; then
  {
    bleopt complete_auto_delay=80
    bleopt exec_errexit_mark=          # starship already shows failures
    bleopt exec_elapsed_mark=          # ...and command duration
    bleopt prompt_eol_mark=$'\e[38;2;74;68;88m⏎\e[m'

    ble-face -s auto_complete           fg=#4a4458,italic
    ble-face -s syntax_default          fg=#dedee2
    ble-face -s command_builtin         fg=#9a5cff,bold
    ble-face -s command_alias           fg=#9a5cff,bold
    ble-face -s command_function        fg=#9a5cff,bold
    ble-face -s command_file            fg=#c8a0ff,bold
    ble-face -s command_keyword         fg=#7aa2ff,bold
    ble-face -s command_directory       fg=#c8a0ff,underline
    ble-face -s syntax_error            fg=#ff4d6d,bold
    ble-face -s syntax_quoted           fg=#5be3a0
    ble-face -s syntax_quotation        fg=#5be3a0,bold
    ble-face -s syntax_escape           fg=#ffcf5c
    ble-face -s syntax_varname          fg=#ffcf5c
    ble-face -s syntax_param_expansion  fg=#ffcf5c
    ble-face -s syntax_comment          fg=#4a4458,italic
    ble-face -s syntax_delimiter        fg=#9a9aa2
    ble-face -s syntax_glob             fg=#4dd9ff
    ble-face -s syntax_tilde            fg=#4dd9ff
    ble-face -s filename_directory      fg=#7aa2ff,underline
    ble-face -s filename_executable     fg=#5be3a0,underline
    ble-face -s filename_link           fg=#4dd9ff,underline
    ble-face -s region                  bg=#2a1450
    ble-face -s region_insert           fg=#4a4458
    ble-face -s region_match            bg=#5a28aa,fg=#ffffff
    ble-face -s disabled                fg=#4a4458
  } 2>/dev/null
fi

alias ff=fastfetch                          # the classic info dump, with the Exarch art

[[ -r ~/.bashrc.local ]] && source ~/.bashrc.local

# --- banner: the 3D logo when a terminal opens ----------------------------------
# Set EXARCH_SPLASH in ~/.bashrc.local:
#   spin (default)  keeps rotating slowly until you start typing (your keys go
#                   to the prompt). EXARCH_SPLASH_TIMEOUT=SECONDS settles it by
#                   itself (default 0 = never; the Rust renderer costs ~1% CPU)
#   intro           one spin-in, then stops    static | fastfetch | off
if [[ -z "${EXARCH_BANNER_SHOWN-}" ]]; then
  export EXARCH_BANNER_SHOWN=1
  case "${EXARCH_SPLASH:-spin}" in
    off) ;;
    fastfetch) command -v fastfetch >/dev/null && fastfetch ;;
    static) command -v exarch >/dev/null && exarch splash --static ;;
    intro) command -v exarch >/dev/null && exarch splash ;;
    *) command -v exarch >/dev/null && exarch splash --banner --timeout "${EXARCH_SPLASH_TIMEOUT:-0}" ;;
  esac
fi

[[ ! ${BLE_VERSION-} ]] || ble-attach
