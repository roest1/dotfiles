//! `github` — GitHub for the machine you are on.
//!
//! The Rust port of `bash/bash_github_tui`, built root-first and then by the
//! screen that stresses the most machinery. What exists today:
//!
//!   * the USER level — your repos, orgs, account and keys. Always the bottom
//!     of the stack, so standing in a repo seeds the SELECTION rather than
//!     making a second root that could not connect to the first;
//!   * the ROOT screen — every clone under `~/github`, grouped by where you
//!     filed it, read from disk with no API call in front of the first frame;
//!   * one repo as five tabs — BRANCHES (a full-width table, local git
//!     first), PULL REQUESTS (filters in a sidebar), ACTIONS (workflow runs
//!     with the failing step's log already in the pane, refreshing itself
//!     while a run is live), SECRETS (the repo's and each environment's) and
//!     ENVIRONMENTS (the deployment gates, with a picker for the reviewers);
//!   * the JOBS & STEPS screen — one run as a tree, with a pager on any log.
//!
//! What is left before the bash implementation can be deleted is one row and
//! one decision, both named in `docs/decisions/github-parity.md`. That file is
//! the gate, not a wish list: CI refuses to let `github` into `tui/deps.sh`'s
//! `crates=()` while any row says `todo` or `partial`.
//!
//! Until then the two live side by side, and this crate is deliberately absent
//! from `deps.conf` and `tui/deps.sh` — a bash function beats PATH and
//! `github()` is still defined, so nothing installs a binary that could not
//! win anyway. The commit that deletes the bash function is the one that adds
//! this to both. A `github` that dispatches to both halves is the drift this
//! repo keeps deleting.
//!
//! See `docs/decisions/github-tui.md` for the port's shape and what is
//! deliberately not being carried over.

pub mod branches;
pub mod envs;
pub mod gh;
pub mod index;
pub mod logs;
pub mod menu;
pub mod model;
pub mod orgs;
pub mod paint;
pub mod prs;
pub mod render;
pub mod root;
pub mod rules;
pub mod runs;
pub mod scopes;
pub mod secrets;
pub mod steps;
pub mod time;
pub mod user;

/// Hand a URL to the desktop's browser, and say what happened.
///
/// `xdg-open` on Linux, `open` on macOS -- the same pair `_open_url` in
/// `bash_github` picks between. Spawned and forgotten: waiting on it would
/// block the loop for as long as the browser takes to start, which on a cold
/// Firefox is seconds.
///
/// One copy, because there were four and the fifth would have been in a screen
/// that had no other reason to know what an operating system is. The return
/// value is a status line rather than a `Result` because every caller does the
/// same thing with it -- puts it in the footer.
pub fn browse(url: &str) -> String {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    match std::process::Command::new(opener).arg(url).spawn() {
        Ok(_) => format!("opened {url}"),
        Err(e) => format!("could not run {opener}: {e}"),
    }
}

/// The tab mark: `gh_tui`, an OSC 1337 user var that wezterm reads.
///
/// `wezterm/shared.lua`'s `format-tab-title` puts GitHub's Octicons mark on
/// the tab while a github session is running, and it learns that a session is
/// running from this variable and nothing else. The bash implementation set it
/// in `_gh_tab_var`, which is NOT one of `_ghw_main`'s verbs -- so the parity
/// table, derived from that dispatcher, could not see it. It was found by
/// grepping for every mention of the file about to be deleted.
///
/// Two things make this worth a type rather than two calls. The variable is
/// process-scoped state inside somebody else's program: a mark left set
/// leaves the pane wearing the GitHub glyph for the life of the shell, which
/// is why the bash version hung the clear on a `RETURN` trap rather than
/// putting it at the bottom of the function. `Drop` is that trap -- it runs on
/// the way out of `main` and on an unwinding panic alike.
///
/// It writes to `/dev/tty` rather than stdout, for the same reason
/// `_gh_tab_var` did: the escape is addressed to the terminal, so it must not
/// land in a pipe when the output is redirected.
pub struct TabMark;

/// base64 of `1` and `0`. The var is a string and the Lua compares it to
/// `"1"`, so the value is encoded exactly as `_gh_tab_var` encoded it.
const MARK_ON: &str = "MQ==";
const MARK_OFF: &str = "MA==";

impl TabMark {
    pub fn set() -> Self {
        write_tty(&var_escape(MARK_ON));
        TabMark
    }
}

impl Drop for TabMark {
    fn drop(&mut self) {
        write_tty(&var_escape(MARK_OFF));
    }
}

/// The wire format wezterm parses, split out so a test can pin it.
fn var_escape(value: &str) -> String {
    format!("\u{1b}]1337;SetUserVar=gh_tui={value}\u{7}")
}

/// Best-effort: no tty, or one that cannot be opened for writing, means no
/// mark. There is nothing to report and nobody to report it to.
fn write_tty(s: &str) {
    use std::io::Write;
    if let Ok(mut tty) = std::fs::OpenOptions::new().write(true).open("/dev/tty") {
        let _ = tty.write_all(s.as_bytes());
        let _ = tty.flush();
    }
}

pub use root::Root;
pub use runs::Actions;
pub use steps::Steps;

#[cfg(test)]
mod tests {
    use super::*;

    /// The wire format, pinned. `wezterm/shared.lua` reads it on the WINDOWS
    /// host, out of a different clone than the one that writes it, so a change
    /// here goes dark rather than failing: the config still loads, the tab
    /// still draws, and there is simply no icon with nothing to say why. The
    /// var is still named after the command's old name for that same reason.
    #[test]
    fn the_tab_mark_is_the_escape_wezterm_reads() {
        assert_eq!(
            var_escape(MARK_ON),
            "\u{1b}]1337;SetUserVar=gh_tui=MQ==\u{7}"
        );
        assert_eq!(
            var_escape(MARK_OFF),
            "\u{1b}]1337;SetUserVar=gh_tui=MA==\u{7}"
        );
    }
}
