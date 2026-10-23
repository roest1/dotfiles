//! `github` — GitHub for the machine you are on.
//!
//! The Rust port of `bash/bash_github_tui`, built root-first and then by the
//! screen that stresses the most machinery. What exists today:
//!
//!   * the ROOT screen — every clone under `~/github`, grouped by where you
//!     filed it, read from disk with no API call in front of the first frame;
//!   * the ACTIONS screen — workflow runs with the failing step's log already
//!     open in the pane, refreshing itself while a run is live;
//!   * the JOBS & STEPS screen — one run as a tree, with a pager on any log.
//!
//! Still the bash implementation: PRs, Branches, Secrets, Environments. The two
//! live side by side ONLY until the port covers what is actually used. This
//! crate is deliberately absent from `deps.conf` and `tui/deps.sh` until then,
//! because a bash function beats PATH and `github()` is still defined — so
//! nothing installs a binary that could not win anyway. The commit that deletes
//! the bash function is the one that adds this to both. A `github` that
//! dispatches to both halves is the drift this repo keeps deleting.
//!
//! See `docs/decisions/github-tui.md` for the port's shape and what is
//! deliberately not being carried over.

pub mod branches;
pub mod gh;
pub mod index;
pub mod logs;
pub mod menu;
pub mod model;
pub mod orgs;
pub mod paint;
pub mod render;
pub mod root;
pub mod runs;
pub mod scopes;
pub mod steps;
pub mod time;
pub mod user;

pub use root::Root;
pub use runs::Actions;
pub use steps::Steps;
