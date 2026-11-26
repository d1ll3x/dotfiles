#!/usr/bin/env bash
# bootstrap: set up any new machine (Arch, Debian/Ubuntu, Fedora; WSL too) from my dotfiles.
# Everything after the clone (links, ~/.zshenv, git identity, tools) is declared in
# home/.config/mise/config.toml; this script only covers what has to happen around it:
# packages, mise, a signing key, the dotfiles, then zsh.
# Every step checks first, so the script is safe to re-run after a failure.
# Usage: clone this repo anywhere, then run its bootstrap.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
signing_key=$HOME/.ssh/id_ed25519

step() { printf '\n==> %s\n' "$*"; }

step "System packages"
if command -v pacman >/dev/null; then
  sudo pacman -Syu --needed --noconfirm zsh git openssh curl
elif command -v apt-get >/dev/null; then
  sudo apt-get update && sudo apt-get install -y zsh git openssh-client curl
elif command -v dnf >/dev/null; then
  sudo dnf install -y zsh git openssh-clients curl
else
  echo "No pacman, apt-get or dnf found: unsupported system" >&2
  exit 1
fi

step "mise"
export PATH="$HOME/.local/bin:$PATH"
command -v mise >/dev/null || curl -fsSL https://mise.run | sh
mise --version

step "Signing key"
install -d -m 700 "$HOME/.ssh"
if [[ ! -f $signing_key ]]; then
  echo "Key for signing commits on this machine; choose a passphrase:"
  ssh-keygen -t ed25519 -f "$signing_key" -C "$USER@$(uname -n)"
fi

step "Dotfiles"
# mise's global config lives in the repo; everything else follows from it: links home/
# into ~, applies the ssh block and ~/.zshenv, asks for the git identity vars, and
# installs the [tools].
# mise expects the repo at ~/.dotfiles; link it there when cloned elsewhere.
[[ -e $HOME/.dotfiles ]] || ln -s "$repo" "$HOME/.dotfiles"
mkdir -p "$HOME/.config"
[[ -e $HOME/.config/mise ]] || ln -s "$HOME/.dotfiles/home/.config/mise" "$HOME/.config/mise"
mise bootstrap --prompt-vars

step "zsh"
zsh_path=$(command -v zsh)
if [[ $(getent passwd "$USER" | cut -d: -f7) != "$zsh_path" ]]; then
  sudo usermod --shell "$zsh_path" "$USER"
fi
# First interactive start clones antidote and builds the plugin bundle.
zsh -i -c true

step "Done"
cat <<EOF
Left for you:
  1. Add this signing key to GitHub (and your work Git server, if any) as a signing key:
       $(cat "$signing_key.pub")
  2. Open a new terminal: your login shell is now zsh.
EOF
