#!/usr/bin/env bash
# pre-dotfiles hook: get ~/.ssh ready before mise renders allowed_signers.
#  - WSL: ~/.ssh becomes a link to Windows' %USERPROFILE%\.ssh, so keys and config are shared.
#  - Everywhere: create a signing key once if there is none.
# Safe to re-run.
set -euo pipefail

key=$HOME/.ssh/id_ed25519

is_wsl() { [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

if is_wsl; then
  win_home=$(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')
  win_ssh=$(wslpath "$win_home")/.ssh

  if [[ ! -L $HOME/.ssh ]]; then
    if [[ -d $HOME/.ssh && -n $(ls -A "$HOME/.ssh") ]]; then
      echo "$HOME/.ssh already has files. Move them to $win_ssh, remove it, then re-run." >&2
      exit 1
    fi
    rmdir "$HOME/.ssh" 2>/dev/null || true
    mkdir -p "$win_ssh"
    ln -s "$win_ssh" "$HOME/.ssh"
    echo "Linked ~/.ssh -> $win_ssh"
  fi

  # OpenSSH rejects keys and config with open permissions. Files on /mnt/c only keep
  # Linux permissions with the "metadata" mount option.
  if ! findmnt -no OPTIONS /mnt/c | grep -q metadata; then
    cat >&2 <<'EOF'
/mnt/c is mounted without "metadata", so ssh will reject the shared keys. Add to /etc/wsl.conf:

  [automount]
  options = "metadata,umask=22,fmask=11"

Then run `wsl.exe --shutdown` from Windows, reopen WSL and re-run `mise bootstrap`.
EOF
    exit 1
  fi
  chmod 700 "$HOME/.ssh/"
  find -L "$HOME/.ssh" -maxdepth 1 -type f ! -name '*.pub' -exec chmod 600 {} +
else
  install -d -m 700 "$HOME/.ssh"
fi

if [[ ! -f $key ]]; then
  echo "Creating a key to sign commits on this machine; choose a passphrase:"
  ssh-keygen -t ed25519 -f "$key" -C "$USER@$(uname -n)"
  printf '\nAdd this key to GitHub (auth + signing):\n  %s\n\n' "$(cat "$key.pub")"
fi
