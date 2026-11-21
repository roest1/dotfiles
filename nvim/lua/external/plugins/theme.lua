-- The colorschemes on offer. Which one each lane uses is machine-local, read
-- from ~/.config/dotfiles/theme.conf by external/theme.lua; the repo default
-- is rose-pine-moon, transparent.
return {
  {
    'rose-pine/neovim',
    name = 'rose-pine',
    -- Eager and first: it is the fallback, so it must always be there.
    priority = 1000,
    config = function()
      require('external.theme').setup()
    end,
  },
  -- The alternatives load on demand. lazy.nvim intercepts `:colorscheme <name>`
  -- for a lazy plugin, which is also what lets theme.conf name one at startup.
  --
  -- Dracula: both opaque and transparent were tried and kept.
  {
    'Mofiqul/dracula.nvim',
    lazy = true,
  },
  -- Atom One Dark: opaque only. Its transparent mode was tried and rejected --
  -- One Dark over the rose-pine base reads badly, unlike Dracula. The reader
  -- does not enforce that; it is a taste the TUI should encode, not a rule.
  {
    'navarasu/onedark.nvim',
    lazy = true,
  },
}
