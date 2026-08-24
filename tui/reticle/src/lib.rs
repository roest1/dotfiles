//! A terminal UI core: an animated reticle, nvim navigation, a redraw loop.
//!
//! Built for the font browser and shaped so `make it` and `github` can follow
//! it without a rewrite. Each of those stays its OWN binary and its own command
//! -- `font`, `github`, `make it` -- sharing this crate rather than becoming
//! modes of one program. The nav contract is the thing worth sharing; the
//! screens have nothing else in common.
//!
//! `lib/tui.sh` on feat/make-console is the reference for the feel, and is
//! deliberately not deleted by this: it opens on a machine that has no cargo
//! and no binary, which is the machine `make it` exists for.

pub mod app;
pub mod image;
pub mod nav;
pub mod probe;
pub mod reticle;
pub mod screen;
pub mod term;

use std::sync::OnceLock;

static TERM_INFO: OnceLock<probe::TermInfo> = OnceLock::new();

/// What the terminal said about itself — cell size, foreground, background,
/// palette. Probed once by `app::run`; defaults until then.
///
/// A global rather than an argument threaded through every `pane()` because it
/// is a property of the process's terminal, not of any screen, and it cannot
/// change while the program runs.
pub fn term_info() -> &'static probe::TermInfo {
    TERM_INFO.get_or_init(probe::TermInfo::default)
}

pub(crate) fn set_term_info(info: probe::TermInfo) {
    let _ = TERM_INFO.set(info);
}

pub use nav::Action;
pub use screen::{Flow, Image, Pane, Row, Screen, Tick};
