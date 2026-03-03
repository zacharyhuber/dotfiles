#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
eval "$(starship init bash)"

if command -v tmux &> /dev/null && [ -z "$TMUX" ]; then
	tmux attach-session -t default || tmux new-session -s default
fi

# Clean up stale Chromium locks
rm -f ~/.config/chromium/Default/SingletonLock
rm -f ~/.config/chromium/Singleton*

export PATH="/opt/brew/bin:$PATH"
. "/home/development/.deno/env"
