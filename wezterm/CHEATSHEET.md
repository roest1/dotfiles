# Wezterm Cheatsheet

Need to start multiplex sessions, close them, list open ones, delete them, and create panes vertically and horizontally, moving between them, and closing panes.

---

# From Claude:

# WezTerm mux cheat sheet

## Mental model

| WezTerm                             | tmux equivalent              |
| ----------------------------------- | ---------------------------- |
| mux server (`wezterm-mux-server`)   | tmux server                  |
| domain (`unix`, `SSHMUX:host`, TLS) | — (connection to the server) |
| **workspace**                       | **session**                  |
| window                              | — (real OS window)           |
| tab                                 | window                       |
| pane                                | pane                         |

Panes live in tabs, tabs in windows, windows in workspaces. Workspaces are what you want for "sessions".

## Setup (required for persistence)

Without a unix domain, everything dies with the GUI. Add to `~/.wezterm.lua`:

```lua
local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

config.unix_domains = { { name = 'unix' } }
-- act as though started with `wezterm connect unix`
config.default_gui_startup_args = { 'connect', 'unix' }
```

If you prefer to connect manually, omit `default_gui_startup_args` and run `wezterm connect unix` yourself.

## Sessions (workspaces)

| Task                      | How                                                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Start / attach to the mux | `wezterm connect unix` (spawns the server if not running)                                                           |
| List workspaces           | `wezterm cli list --format json \| jq -r '.[].workspace' \| sort -u`                                                |
| List clients attached     | `wezterm cli list-clients`                                                                                          |
| Switch workspace          | `CTRL+SHIFT+P` → "Switch to workspace", or bind `SwitchToWorkspace` / `ShowLauncherArgs{flags='FUZZY\|WORKSPACES'}` |
| New named workspace       | `SwitchToWorkspace{name='foo'}` — creating one is just switching to a name that doesn't exist                       |
| Rename                    | `wezterm cli rename-workspace --workspace old new`                                                                  |
| Detach                    | bind `DetachDomain{DomainName='unix'}` — no default key                                                             |
| Kill a workspace          | kill its panes: `wezterm cli kill-pane --pane-id N` for each                                                        |
| Kill the whole server     | `pkill -f wezterm-mux-server` — there's no `cli kill-server` subcommand                                             |

The CLI can't switch workspaces directly; that's a GUI/Lua-side action only.

## Panes — defaults

`CTRL+SHIFT+ALT+"` → `SplitVertical` (new pane **below**), `CTRL+SHIFT+ALT+%` → `SplitHorizontal` (new pane **right**), `CTRL+SHIFT+Arrow` → `ActivatePaneDirection`, `CTRL+SHIFT+ALT+Arrow` → `AdjustPaneSize`, `CTRL+SHIFT+Z` → `TogglePaneZoomState`, `CTRL+SHIFT+W` → `CloseCurrentTab{confirm=true}`.

Gotcha: the naming is split-_direction_, not divider-orientation. `SplitVertical` gives you a horizontal divider. Opposite of tmux's `-v`/`-h` intuition.

Second gotcha: **there is no default binding for `CloseCurrentPane`**. `CTRL+SHIFT+W` closes the whole tab. Bind it yourself.

## Panes — CLI

```bash
wezterm cli list                        # windows/tabs/panes with ids + workspace
wezterm cli split-pane --right          # or --left --top --bottom
wezterm cli split-pane --bottom --percent 30
wezterm cli split-pane --right -- htop  # run a program in the new pane
wezterm cli activate-pane --pane-id 3
wezterm cli activate-pane-direction Left
wezterm cli zoom-pane --zoom             # --unzoom / --toggle
wezterm cli kill-pane --pane-id 3        # no prompt
wezterm cli spawn                        # new tab
wezterm cli move-pane-to-new-tab --pane-id 3
```

`--horizontal` is equivalent to `--right`; with no direction given the default is `--bottom`. If `--pane-id` is omitted it uses `$WEZTERM_PANE`, so inside a pane you can just run `wezterm cli split-pane --right`.

## Recommended leader bindings

Fills the gaps (close pane, detach, workspace switching):

```lua
config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }

config.keys = {
  -- splits
  { key = '|', mods = 'LEADER|SHIFT', action = act.SplitHorizontal{ domain = 'CurrentPaneDomain' } },
  { key = '-', mods = 'LEADER',       action = act.SplitVertical{ domain = 'CurrentPaneDomain' } },

  -- navigate
  { key = 'h', mods = 'LEADER', action = act.ActivatePaneDirection 'Left' },
  { key = 'j', mods = 'LEADER', action = act.ActivatePaneDirection 'Down' },
  { key = 'k', mods = 'LEADER', action = act.ActivatePaneDirection 'Up' },
  { key = 'l', mods = 'LEADER', action = act.ActivatePaneDirection 'Right' },
  { key = 'z', mods = 'LEADER', action = act.TogglePaneZoomState },
  { key = 'p', mods = 'LEADER', action = act.PaneSelect },  -- visual pane picker

  -- close
  { key = 'x', mods = 'LEADER', action = act.CloseCurrentPane{ confirm = true } },
  { key = '&', mods = 'LEADER|SHIFT', action = act.CloseCurrentTab{ confirm = true } },

  -- workspaces
  { key = 's', mods = 'LEADER', action = act.ShowLauncherArgs{ flags = 'FUZZY|WORKSPACES' } },
  { key = 'n', mods = 'LEADER', action = act.SwitchWorkspaceRelative(1) },
  { key = 'N', mods = 'LEADER|SHIFT', action = act.SwitchWorkspaceRelative(-1) },
  { key = 'd', mods = 'LEADER', action = act.DetachDomain{ DomainName = 'unix' } },

  -- prompt for a new workspace name
  { key = 'C', mods = 'LEADER|SHIFT', action = act.PromptInputLine {
      description = 'workspace name',
      action = wezterm.action_callback(function(win, pane, line)
        if line and line ~= '' then
          win:perform_action(act.SwitchToWorkspace{ name = line }, pane)
        end
      end),
  }},
}

return config
```

Add a workspace indicator so you know where you are:

```lua
wezterm.on('update-right-status', function(window)
  window:set_right_status(window:active_workspace())
end)
```

Run `wezterm show-keys --lua` to dump your effective bindings in copy-pasteable form.
