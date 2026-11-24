-- The colorschemes on offer. Which one each lane uses is machine-local, read
-- from ~/.config/dotfiles/theme.conf by external/theme.lua; the repo default
-- is rose-pine-moon, transparent.
return {
  add = {
    -- The fallback, so it must always be there. Named, because the
    -- repository is called "neovim".
    { src = 'https://github.com/rose-pine/neovim', name = 'rose-pine' },
    -- Dracula: both opaque and transparent were tried and kept.
    'https://github.com/Mofiqul/dracula.nvim',
    -- Atom One Dark: opaque only. Its transparent mode was tried and rejected --
    -- One Dark over the rose-pine base reads badly, unlike Dracula. The reader
    -- does not enforce that; it is a taste the TUI should encode, not a rule.
    'https://github.com/navarasu/onedark.nvim',
  },
  setup = function()
    require('external.theme').setup()
  end,
}
