//! `dots` — the dotfiles console.
//!
//! A tree of everything this repo can do, on the left; what the thing under the
//! cursor actually is, on the right. The value is not saved keystrokes — `make
//! status` is nine characters — it is not having to already know that `make
//! status` exists, what it answers, and how it differs from `make check`.
//!
//! Nothing here is authored twice. Targets and their summaries come from the
//! `##` markers `make help` already renders, the long form of a target is the
//! comment block above its rule, and sections come from `deps.conf`. See
//! `repo.rs`, which is the only file that reads any of it.
//!
//! A library as well as a binary, for the same reason `font` is: a screen is
//! reusable, and this one will eventually be pushed from somewhere else too.

pub mod console;
pub mod repo;

pub use console::Console;
