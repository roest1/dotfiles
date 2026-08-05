local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Attach a GUI window to the Jarvis sidecar's mux server so you can watch the
-- worker + brain Claude Code panes live:  wezterm connect mux
-- socket_path points at the SAME default socket the sidecar's `wezterm cli`
-- and `wezterm-mux-server` use, so the GUI shares their panes.
local runtime = os.getenv 'XDG_RUNTIME_DIR' or '/run/user/1000'
config.unix_domains = {
  { name = 'mux', socket_path = runtime .. '/wezterm/sock' },
}

-- The sidecar names each session's TAB ("WORKER · <repo>", "BRAIN · <date>")
-- via `set-tab-title`. Claude Code emits OSC title sequences that overwrite the
-- OS window title, so mirror the stable tab name into the window title here
-- (with the live status appended) — that's what shows in the GNOME window
-- switcher, keeping multiple Jarvis terminals tellable apart.
wezterm.on('format-window-title', function(tab)
  local name = tab.tab_title
  local status = tab.active_pane and tab.active_pane.title or ''
  if name and #name > 0 then
    return status ~= '' and (name .. '  —  ' .. status) or name
  end
  return status ~= '' and status or 'wezterm'
end)

return config
