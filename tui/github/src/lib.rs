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

pub use root::Root;
pub use runs::Actions;
pub use steps::Steps;
