//! `github` — GitHub for the machine you are on.
//!
//! The Rust port of `bash/bash_github_tui`, built root-first. What exists today
//! is the root screen: every clone under `~/github`, grouped by where you filed
//! it, read from disk with no API call in front of the first frame. The repo's
//! own screens — Actions, PRs, Branches, Secrets, Environments — are the port
//! proper and are still the bash implementation.
//!
//! The two live side by side ONLY until the port covers what is actually used.
//! This crate is deliberately absent from `deps.conf` and `tui/deps.sh` until
//! then, because a bash function beats PATH and `github()` is still defined —
//! so nothing installs a binary that could not win anyway. The commit that
//! deletes the bash function is the one that adds this to both. A `github` that
//! dispatches to both halves is the drift this repo keeps deleting.
//!
//! See `docs/decisions/github-tui.md` for the port's shape and what is
//! deliberately not being carried over.

pub mod index;
pub mod root;

pub use root::Root;
