-- Fuzzy finder: <leader>sf (files) and <leader>sg (text in files).
--
-- Three defaults differ from stock telescope, each because the stock one
-- returned nothing without saying why:
--
--   * Grep is PLAIN TEXT. Stock live_grep reads the prompt as a regex, so
--     `setup(` is a syntax error (an empty list) and `[nvim]` is a character
--     class (every line with an n, v, i or m). <C-e> in the picker switches to
--     regex and back, keeping what you typed. The prompt title says which.
--   * Hidden files are searched, .git/ is not. Half of a dotfiles repo starts
--     with a dot.
--   * The search starts at the repo containing what you are looking at (the
--     oil directory or the current file), not at wherever nvim was launched.
--     Outside a repo it is that directory itself. The prompt title shows it.

-- rg does both jobs so there is one set of rules for what is visible.
local VISIBLE = { '--hidden', '--glob', '!**/.git/*' }

local function search_root()
  local dir
  local ok, oil = pcall(require, 'oil')
  if ok then
    dir = oil.get_current_dir()
  end
  if not dir then
    local name = vim.api.nvim_buf_get_name(0)
    if vim.bo.buftype == '' and name ~= '' then
      dir = vim.fs.dirname(name)
    end
  end
  dir = dir or vim.uv.cwd()
  return vim.fs.root(dir, '.git') or dir
end

local function title(what, root)
  return ('%s in %s'):format(what, vim.fn.fnamemodify(root, ':~'))
end

local function find_files()
  local root = search_root()
  require('telescope.builtin').find_files {
    cwd = root,
    prompt_title = title('Files', root),
    find_command = vim.list_extend({ 'rg', '--files', '--color', 'never' }, VISIBLE),
  }
end

local function grep(opts)
  opts = opts or {}
  local root = opts.root or search_root()
  local regex = opts.regex or false
  require('telescope.builtin').live_grep {
    cwd = root,
    default_text = opts.text,
    prompt_title = title(regex and 'Grep REGEX (<C-e>: plain text)' or 'Grep plain text (<C-e>: regex)', root),
    additional_args = regex and {} or { '--fixed-strings' },
    attach_mappings = function(prompt_bufnr, map)
      map({ 'i', 'n' }, '<C-e>', function()
        local text = require('telescope.actions.state').get_current_line()
        require('telescope.actions').close(prompt_bufnr)
        vim.schedule(function()
          grep { root = root, regex = not regex, text = text }
        end)
      end)
      return true
    end,
  }
end

return {
  'nvim-telescope/telescope.nvim',
  event = 'VimEnter',
  dependencies = {
    'nvim-lua/plenary.nvim',
    {
      'nvim-telescope/telescope-fzf-native.nvim',
      build = 'make',
      cond = function()
        return vim.fn.executable 'make' == 1
      end,
    },
    'nvim-telescope/telescope-ui-select.nvim',
    'nvim-tree/nvim-web-devicons',
  },
  config = function()
    local telescope = require 'telescope'
    local vimgrep = vim.list_extend(vim.deepcopy(require('telescope.config').values.vimgrep_arguments), VISIBLE)
    telescope.setup {
      defaults = { vimgrep_arguments = vimgrep },
      extensions = {
        ['ui-select'] = { require('telescope.themes').get_dropdown() },
      },
    }
    pcall(telescope.load_extension, 'fzf')
    pcall(telescope.load_extension, 'ui-select')

    vim.keymap.set('n', '<leader>sf', find_files, { desc = '[S]earch [F]iles' })
    vim.keymap.set('n', '<leader>sg', grep, { desc = '[S]earch by [G]rep (plain text)' })
  end,
}
