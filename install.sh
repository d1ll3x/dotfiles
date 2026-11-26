#!/usr/bin/env bash
set -euo pipefail

repo=https://github.com/d1ll3x/dotfiles.git
dir=$HOME/projects/github.com/d1ll3x/dotfiles

if ! command -v curl >/dev/null; then
  if command -v pacman >/dev/null; then
    sudo pacman -Syu --needed --noconfirm curl
  elif command -v apt-get >/dev/null; then
    sudo apt-get update && sudo apt-get install -y curl
  elif command -v dnf >/dev/null; then
    sudo dnf install -y curl
  else
    echo "No pacman, apt-get or dnf found: install curl yourself" >&2
    exit 1
  fi
fi

export PATH="$HOME/.local/bin:$PATH"
command -v mise >/dev/null || curl -fsSL https://mise.run | sh

profile=${1:-}
if [[ $profile != personal && $profile != work ]]; then
  PS3="Profile for this machine: "
  select profile in personal work; do
    [[ -n $profile ]] && break
  done
fi

mise -E "$profile" bootstrap --from "$repo" --from-dir "$dir" --config-dir mise --save-env
