-- Hand the plugin list (lua/external/plugins/init.lua) to lazy.nvim.
-- :Lazy shows status; `make -C nvim sync` installs and updates from a terminal.
require('lazy').setup(require 'external/plugins')
