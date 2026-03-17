#!/usr/bin/env bash
# =============================================================================
# /etc/profile.d/99-org-env.sh
# Organization-wide shell environment — sourced for all interactive login shells
# =============================================================================

# Safety: only run in interactive shells
[ -z "${PS1:-}" ] && return

# Organization-specific PATH additions
# Uncomment and modify as needed:
# export PATH="${PATH}:/opt/myorg/bin"

# Default editor
export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-vim}"

# Terminal settings
export TERM="${TERM:-xterm-256color}"

# Useful aliases
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# Show disk usage in human-readable form
alias df='df -hT'
alias du='du -sh'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# History settings
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoredups:erasedups
HISTTIMEFORMAT="%F %T "
shopt -s histappend 2>/dev/null || true
