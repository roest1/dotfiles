-- render-markdown.nvim
-- In-buffer markdown rendering, off until asked for. :Render toggles it for the
-- current buffer. While it is on, normal mode shows the rendered view and insert
-- mode shows the raw source (the default render_modes), so motions in normal
-- mode land on text you can actually see the cursor over.
--   :Render → toggle rendering for this buffer
-- enabled = false keeps it from rendering on load; :Render is the only switch.
-- lazy = false on purpose: lazy-loading on ft or cmd skips attaching the buffer
-- that triggered the load, so the first :Render in a file would silently do
-- nothing.
return {
  'MeanderingProgrammer/render-markdown.nvim',
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
  lazy = false,
  opts = { enabled = false },
  config = function(_, opts)
    require('render-markdown').setup(opts)
    vim.api.nvim_create_user_command('Render', function()
      require('render-markdown').buf_toggle()
    end, { desc = 'Toggle markdown rendering for this buffer' })
  end,
}
