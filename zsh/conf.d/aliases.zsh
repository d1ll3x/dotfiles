# ~/.config/zsh/conf.d/aliases.zsh

# fancy ls 
alias ls='eza --icons'
alias ll='eza -lh --icons --git'
alias la='eza -lah --icons --git'
alias tree='eza --tree --icons'

# zoxide
alias cd='z'
alias zi='__zoxide_zi'

# utility
alias cat='bat'
alias htop='btop'
alias top='btop'
alias grep='rg --color=auto'
alias diff='diff --color=auto'
alias df='df -h'

# neovim btw
alias vim='nvim'
alias vi='nvim'
alias nano='nvim'

# update everything (mise/conf.d/tasks.toml)
alias up='mise run update'
