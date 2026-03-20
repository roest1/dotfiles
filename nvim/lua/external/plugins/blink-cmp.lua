-- blink.cmp — autocompletion
--
-- Keymaps (insert mode, when completion menu is visible):
--   <C-Space>   Trigger completion manually
--   <C-y>       Confirm selection
--   <C-e>       Dismiss menu (no conflict with Harpoon — different mode)
--   <C-n>/<C-p> Navigate items
--   <C-b>/<C-f> Scroll documentation
--   <Tab>       Next item (or snippet jump forward)
--   <S-Tab>     Previous item (or snippet jump backward)
--   <CR>        Confirm selection

return {
  'saghen/blink.cmp',
  version = '1.*',

  ---@module 'blink.cmp'
  ---@type blink.cmp.Config
  opts = {
    keymap = {
      preset = 'default',
      ['<Tab>'] = { 'select_next', 'snippet_forward', 'fallback' },
      ['<S-Tab>'] = { 'select_prev', 'snippet_backward', 'fallback' },
      ['<CR>'] = { 'accept', 'fallback' },
    },

    appearance = {
      nerd_font_variant = 'mono',
    },

    completion = {
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 200,
      },
      ghost_text = {
        enabled = true,
      },
    },

    sources = {
      default = { 'lsp', 'path', 'snippets', 'buffer' },
    },

    snippets = {
      preset = 'default',
    },

    signature = {
      enabled = true,
    },
  },
}
