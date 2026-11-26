#!/usr/bin/env bash
# post-dotfiles hook: per-machine git identity, untracked and created once.
set -euo pipefail

dir=${XDG_CONFIG_HOME:-$HOME/.config}/git
local=$dir/config.local
signers=$dir/allowed_signers
pub=$HOME/.ssh/id_ed25519.pub
mkdir -p "$dir"

if [[ ! -f $local ]]; then
  if [[ ! -t 0 ]]; then
    echo "git identity not set: run  bash ~/.config/mise/scripts/git-identity.sh" >&2
    exit 0
  fi
  read -rp "Git author name for this machine: " name
  read -rp "Git email for this machine: " email
  git config --file "$local" user.name "$name"
  git config --file "$local" user.email "$email"
  echo "Wrote $local"
fi

if [[ ! -f $signers && -f $pub ]]; then
  email=$(git config --file "$local" user.email || true)
  if [[ -n $email ]]; then
    printf '%s %s\n' "$email" "$(cat "$pub")" >"$signers"
    echo "Wrote $signers"
  fi
fi
