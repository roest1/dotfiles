-- mini.nvim (surround + pairs)
--
-- Surround: manipulate surrounding characters
--   sa"   → add " around selection (visual) or motion
--   sd"   → delete surrounding "
--   sr"'  → replace surrounding " with '
--
-- Pairs: auto-close brackets, quotes, etc.
return {
  {
    'echasnovski/mini.surround',
    version = '*',
    opts = {
      -- sa = surround add
      -- sd = surround delete
      -- sr = surround replace
      -- sf = surround find (next)
      -- sF = surround find (prev)
      -- sh = surround highlight
      mappings = {
        add = 'sa',
        delete = 'sd',
        replace = 'sr',
        find = 'sf',
        find_left = 'sF',
        highlight = 'sh',
        update_n_lines = 'sn',
      },
    },
  },
  {
    'echasnovski/mini.pairs',
    version = '*',
    event = 'InsertEnter',
    opts = {},
  },
}
