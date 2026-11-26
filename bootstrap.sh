#!/bin/sh
# bootstrap: install mise, then let it set up the machine from this repo.
# Everything else (packages, signing key, dotfiles, login shell, tools) is declared in
# home/.config/mise/config.toml. Safe to re-run; extra arguments go to `mise bootstrap`.
# Usage: sh -c "$(curl -fsSL https://raw.githubusercontent.com/d1ll3x/dotfiles/main/bootstrap.sh)"
set -eu

export PATH="$HOME/.local/bin:$PATH"
command -v mise >/dev/null || curl -fsSL https://mise.run | sh

# Clone into ghq's layout, link ~/.config/mise to the repo's mise config, then apply it.
exec mise bootstrap \
  --from https://github.com/d1ll3x/dotfiles.git \
  --from-dir "$HOME/projects/github.com/d1ll3x/dotfiles" \
  --config-dir home/.config/mise \
  --prompt-vars "$@"
