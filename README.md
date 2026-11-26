# 🏠 dotfiles

My dotfiles, deployed with [mise](https://mise.jdx.dev/dotfiles/).

- `home/` mirrors `~`: every file in it is linked to the same path in your home directory.
- `home/.config/mise/config.toml` declares the rest: the per-machine git identity, the shared `~/.ssh/config` block, `~/.zshenv` and the tools.
- `bootstrap.sh` sets up a new machine (Arch, Debian/Ubuntu, Fedora; WSL too).

## 🚀 New machine

> ⚠️ These are my personal dotfiles. Read `bootstrap.sh` before running it: it installs packages with `sudo` and changes your login shell to zsh.

Needs `git`. Clone anywhere, then run the script from the clone:

```sh
git clone https://github.com/d1ll3x/dotfiles.git
dotfiles/bootstrap.sh
```

`~/.dotfiles` becomes a link to your clone, unless you cloned straight to `~/.dotfiles`.

It installs the packages and mise, creates a signing key, links everything into place, asks for your git name and email, and switches your shell to zsh. Existing files are never overwritten: mise lists them as conflicts instead.

## 🔧 Day to day

Your files are links into the repo, so just edit them where they are. Then save the change:

```sh
cd ~/.dotfiles
git add -A && git commit -m "what changed" && git push
```

**Add a new file:** move it into `home/` at the same path (`~/.config/foo` → `home/.config/foo`), then run `mise dot apply`.

**Update another machine:**

```sh
cd ~/.dotfiles
git pull && mise dot apply
```
