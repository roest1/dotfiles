//! `font` — pick the font for each of wezterm's lanes.
//!
//! A LIBRARY as well as a binary, and the library half is the point. `reticle`
//! takes a `Box<dyn Screen>` from anywhere, so a screen is reusable across
//! binaries: `font` runs the picker as its root, and the `make it` console will
//! push this same `FontScreen` as a row in its tree. One implementation, two
//! doors — the alternative was a second font screen inside the console, which
//! is how the two would drift.
//!
//! This does NOT make the binaries modes of one program. `font` still starts in
//! ~1ms and links only what a picker needs; the console is a separate binary
//! that happens to depend on this one. See tui/CLAUDE.md.

pub mod browse;
pub mod fetch;
pub mod fonts;
pub mod lanes;
pub mod render;
pub mod show;
pub mod theme;

mod picker;

// Re-exported at the crate ROOT because that is where they already lived when
// this was one file, and `browse` reaches for them as `crate::specimen` and
// `crate::Preview`. Keeping the paths identical is what makes this split a
// move rather than a rewrite.
pub use picker::{specimen, FontScreen, Preview};
