# 🏠 dotfiles
 
My dotfiles, deployed with [mise](https://mise.jdx.dev).
Works on Arch, Debian, Fedora and WSL2.
 
> ⚠️ These are personal dotfiles: read `mise/` before running anything. Bootstrap installs
> packages with `sudo` and changes your login shell to zsh.
 

## 📦 Tool versions

All tools are version controlled by [Renovate](https://docs.renovatebot.com/modules/manager/mise/)
(`.github/renovate.json5`), except AI tools (`claude`, `copilot`): they release too rapidly, so they
stay on `latest` and mise updates them automatically, after updating itself.
`mise/mise.lock` locks the exact versions and checksums of the pinned tools.
Minor and patch bumps merge automatically once CI (`.github/workflows/ci.yml`) installs and runs every
tool; majors wait for review.

## 🧩 How it works
 
- **mise config files.** `config.toml` holds only settings and tools. `bootstrap.toml` and `dotfiles.toml` live in `mise/conf.d/`, which mise loads automatically in alphabetical order.
- **Bootstrap hooks** (`conf.d/bootstrap.toml`):
  - `pre-dotfiles` → `scripts/ssh-setup.sh`: links `~/.ssh` to Windows on WSL and creates a signing key
    if missing. It runs before the dotfiles step, which edits `~/.ssh/config`.
  - `post-dotfiles` → `scripts/git-identity.sh`: writes the untracked git identity once.
  - `final` → `zsh -i -c true`: the first interactive start clones antidote and builds the zsh plugin bundle.
- **Shell activation** of mise belongs in the tracked zsh config (`zsh/.zshrc`, e.g.
  `eval "$(mise activate zsh)"` with `~/.local/bin` on `PATH`).

## 🚀 Instructions: set up a new machine
 
### 1. WSL only: share `~/.ssh` with Windows
 
`~/.ssh` is linked to Windows' `%USERPROFILE%\.ssh`, and ssh only accepts those keys when `/mnt/c`
keeps Linux permissions. Add this to `/etc/wsl.conf`, then run `wsl.exe --shutdown` from Windows and
reopen WSL:
 
```ini
[automount]
options = "metadata,umask=22,fmask=11"
```
 
### 2. Run the installer
 
```sh
bash <(curl -fsSL https://raw.githubusercontent.com/d1ll3x/dotfiles/main/install.sh)
```
 
No curl yet (some minimal Debian installs)? Use `wget -qO-` instead of `curl -fsSL`.
 
[`install.sh`](install.sh):
 
1. installs `git` if missing (pacman, apt or dnf);
2. installs mise with `curl -fsSL https://mise.run | sh` and puts `~/.local/bin` on `PATH`;
3. asks whether this is a **personal** or **work** machine
4. runs `mise bootstrap`, which clones this repo to `~/projects/github.com/d1ll3x/dotfiles` (ghq layout)
   and links `~/.config/mise` to its `mise/` folder. The profile is saved, so later runs need no `-E`.
Bootstrap then:
 
1. installs zsh, git, openssh and curl with the distro's package manager;
2. prepares `~/.ssh` (linked to Windows on WSL) and creates a signing key if none exists;
3. links every app into place. Existing files are never overwritten: mise lists them as conflicts;
4. asks once for your git name and email (stored outside the repo, see [Personal data](#-personal-data));
5. switches your login shell to zsh and installs the tools.
If no terminal was available for the git questions, run `bash ~/.config/mise/scripts/git-identity.sh`.
 
### 3. Wrapping-up
 
1. Add the public key that bootstrap printed (`~/.ssh/id_ed25519.pub`) to GitHub, as both an
   authentication and a signing key. The repo is pulled over SSH from then on.
2. Open a new terminal: your login shell is now zsh.

## 📁 Layout
 
```text
~/projects/github.com/d1ll3x/dotfiles   # ghq layout
├── .github/renovate.json5    #   Renovate: PRs that bump the pinned mise tools
├── install.sh                #   new machine: curl + mise + bootstrap
├── mise/                     #   global mise config, linked as ~/.config/mise
│   ├── config.toml           #   every machine: settings + tools
│   ├── mise.lock             #   locked versions + checksums of config.toml
│   ├── conf.d/
│   │   ├── bootstrap.toml    #   host packages, login shell, hooks
│   │   ├── dotfiles.toml     #   app groups + edits to ~/.ssh/config and ~/.zshenv
│   │   └── tasks.toml        #   global tasks, e.g. `mise run update`
│   ├── config.personal.toml  #   personal tools (e.g. claude)
│   ├── config.work.toml      #   work tools (e.g. GitHub Copilot CLI)
│   └── scripts/              #   bootstrap hooks
├── agents/                   # -> ~/.agents
├── gh/                       # -> ~/.config/gh
├── git/                      # -> ~/.config/git
├── herdr/                    # -> ~/.config/herdr
├── lazygit/                  # -> ~/.config/lazygit
├── nvim/                     # -> ~/.config/nvim
└── zsh/                      # -> ~/.config/zsh
```
 
Each app folder holds the app's files flat. mise links them, file by file, into the app's target.
 
## 🔧 FAQ
 
| Task | Command |
|---|---|
| Add a file to an existing app | `mise dot add --group nvim ~/.config/nvim/lua/plugins/foo.lua` |
| Add a new app | `mkdir <repo>/foo`, add `foo = { target = "~/.config/foo" }` to `mise/conf.d/dotfiles.toml`, then `mise dot add --group foo ~/.config/foo/config` |
| Add a tool for every machine | `mise use -g --pin <tool>` (writes the exact version to `mise/config.toml`) |
| Add a profile-only tool | add it to `mise/config.<profile>.toml` (exact version, or `latest` for AI tools) |
| Update tool versions | merge the Renovate PRs, then `up` |
| Update this machine | `up` (alias for `mise run update`, see `mise/conf.d/tasks.toml`) |
| See what's out of sync | `mise dot status` |
 

