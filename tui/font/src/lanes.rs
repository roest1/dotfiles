//! The four lanes, and the machine-local file that records them.
//!
//! Kept in step with DEFAULT_FONTS in wezterm/wezterm.lua by hand. They are two
//! spellings of one fact and nothing holds them together, which is affordable
//! only because disagreeing is harmless: the lua side ignores keys it does not
//! know and falls back to its own defaults for keys it does not get.

use std::fs;
use std::path::PathBuf;

pub const LANES: [&str; 4] = ["shell", "nvim.ui", "nvim.editor", "claude"];

pub fn covers(lane: &str) -> &'static str {
    match lane {
        "shell" => "the shell — any pane that is not nvim or Claude",
        // Named for the whole of nvim's chrome, not for oil. Oil is the most
        // visible thing it draws; it is also telescope, the statusline, the
        // gutter and every float, because it is the window's base font while
        // nvim holds focus.
        "nvim.ui" => "nvim's chrome — oil, telescope, statusline, gutter",
        "nvim.editor" => "the file you are editing in nvim",
        _ => "Claude Code panes (pinned)",
    }
}

pub fn default_for(lane: &str) -> &'static str {
    if lane == "nvim.editor" {
        "JetBrainsMono Nerd Font"
    } else {
        "0xProto Nerd Font"
    }
}

pub fn state_path() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config")
        });
    base.join("wezterm").join("fonts.conf")
}

pub fn read() -> Vec<(String, String)> {
    let text = fs::read_to_string(state_path()).unwrap_or_default();
    LANES
        .iter()
        .map(|lane| {
            let found = text.lines().rev().find_map(|line| {
                let (k, v) = line.trim().split_once('=')?;
                (k.trim() == *lane).then(|| v.trim().to_string())
            });
            let value = found
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| default_for(lane).into());
            ((*lane).to_string(), value)
        })
        .collect()
}

/// Truncate-and-write, deliberately, NOT write-to-temp-and-rename.
///
/// wezterm watches this path via add_to_config_reload_watch_list. An atomic
/// rename swaps the inode out from under that watch and the repaint may simply
/// never happen; rewriting in place keeps the inode the watcher is holding.
/// The torn-write window that buys back is harmless — wezterm.lua reads this
/// with a line-at-a-time parser that skips anything malformed.
pub fn write(state: &[(String, String)]) -> std::io::Result<()> {
    let path = state_path();
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut body = String::from(
        "# Written by `font`. Machine-local: not in git, not linked, not in\n\
         # deps.conf — same footing as ~/.bash_local.\n\
         # Read by wezterm/wezterm.lua. Delete this file to get the defaults.\n",
    );
    for (lane, value) in state {
        body.push_str(&format!("{lane} = {value}\n"));
    }
    fs::write(path, body)
}
