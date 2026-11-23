# Linked into ~/.config/dotfiles/bashrc.d/ by deps.conf [git-autofetch]; bashrc
# sources it last. Says, once per new shell, when this dotfiles clone or a plugin
# is behind what the timer last fetched. Reads local refs only, so no network.
command -v git-autofetch >/dev/null 2>&1 && git-autofetch --report
