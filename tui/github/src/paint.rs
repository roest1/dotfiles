//! The eight colours, in one place.
//!
//! The same indices `_gh_palette` uses in `bash/bash_github_tui`, which are the
//! ones this repo's prompt uses (`bash/bash_theme`) -- so the screens read as
//! part of the shell rather than as a visitor in it. Keeping them identical is
//! also what makes the port a move rather than a reskin: a run that was red
//! before is the same red now.
//!
//! `font` absorbs its colours from the terminal instead (`OSC 4`, see
//! `font::theme`), which is right for a program whose job is rendering type
//! faithfully. Here the colours carry MEANING -- failed, running, skipped --
//! and a meaning should not change because a theme did.

pub const OFF: &str = "\x1b[0m";
pub const BOLD: &str = "\x1b[1m";
pub const RED: &str = "\x1b[38;5;203m";
pub const GRN: &str = "\x1b[38;5;150m";
pub const YEL: &str = "\x1b[38;5;214m";
pub const ORG: &str = "\x1b[38;5;215m";
pub const PUR: &str = "\x1b[38;5;141m";
pub const BLU: &str = "\x1b[38;5;110m";
pub const GRY: &str = "\x1b[38;5;245m";
pub const DIM: &str = "\x1b[38;5;240m";

/// The 256-colour INDEX of each, for `Row::badge` -- which takes a `u8` and
/// writes the escape itself, so a badge cannot leave the row unterminated.
pub mod idx {
    pub const RED: u8 = 203;
    pub const GRN: u8 = 150;
    pub const YEL: u8 = 214;
    pub const GRY: u8 = 245;
    pub const DIM: u8 = 240;
}

/// A horizontal rule the width of the pane, as `_ghw_rule` drew one.
pub fn rule(cols: u16) -> String {
    let w = (cols as usize).clamp(8, 72);
    format!("{DIM}{}{OFF}", "\u{2500}".repeat(w))
}
