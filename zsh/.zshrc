# ~/.config/zsh/.zshrc

# Tool manager
eval "$(mise activate zsh)"

# Zstyle plugin customizations
source $ZDOTDIR/.zstyles

# Antidote plugin manager
source $ZDOTDIR/antidote-fast.zsh

# Zoxide
eval "$(zoxide init zsh)"

# Fzf
eval "$(fzf --zsh)"
