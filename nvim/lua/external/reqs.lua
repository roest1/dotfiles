-- External tools :checkhealth external verifies are on PATH.
--
-- Keep this in sync with the [nvim] section of ../../../deps.conf — that file
-- installs them, this one notices when they're absent. Listing something that
-- nothing installs turns :checkhealth into a source of false errors, which is
-- what happened with prettierd/prettier: they were npm globals, they left with
-- node, and this list kept asking for them.
return {
  'git',
  'make',
  'unzip',
  'rg', -- ripgrep
  'fd', -- fast file search
  'stylua', -- Lua formatter (mise||cargo)
  'bun', -- runs the JS language servers; without it six of them don't start
}
