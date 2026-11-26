# ~/.config/zsh/.zshenv

# XDG base dir specification
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"

# Editor
export EDITOR="nvim"
export VISUAL="nvim"

# GPG
export GPG_TTY=$(tty)

# Starship
export STARSHIP_CONFIG="$ZDOTDIR/starship.toml"

# bitwarden agent on personal machines
[[ -z $WSL_DISTRO_NAME ]] && export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"

# Copilot CLI: read ~/.agents/AGENTS.md (skills come from ~/.agents/skills by default)
export COPILOT_CUSTOM_INSTRUCTIONS_DIRS="$HOME/.agents"

# PATH
# Ensure path arrays do not contain duplicates.
typeset -gU path fpath
export PATH="$HOME/.agents/scripts:$HOME/.local/bin:$HOME/.local/share/nvim/mason/bin:$PATH"
