//! Inline images, iTerm2 protocol, which wezterm implements.
//!
//! Sized in CELLS with preserveAspectRatio so the picture fits the pane it is
//! given rather than assuming a pixel geometry. Only the arguments iTerm2
//! actually defines are sent: an unrecognised key risks the whole sequence
//! being dropped, which takes the picture with it and leaves no clue why.

use base64::{engine::general_purpose::STANDARD, Engine};

/// Sized by HEIGHT in cells, deliberately, with width left to follow.
///
/// Giving both and trusting preserveAspectRatio to fit inside the box is what
/// the first version did, and wezterm binds on the WIDTH instead: a sheet asked
/// for 147x14 cells came back 147 wide and ~31 tall, painted straight over the
/// metrics below it. Height is the dimension a pane can least afford to have
/// guessed, so it is the one that gets stated.
///
/// The caller still clears the region below afterwards — see `app::draw_pane`.
/// Belt and braces, because this is a negotiation with a terminal rather than
/// an API, and the failure mode is an unreadable screen.
pub fn inline(png: &[u8], rows: u16) -> Vec<u8> {
    let b64 = STANDARD.encode(png);
    format!(
        "\x1b]1337;File=inline=1;size={};height={};preserveAspectRatio=1:{}\x07",
        png.len(),
        rows,
        b64
    )
    .into_bytes()
}

/// Whether inline images will be drawn rather than dumped as base64 text.
///
/// The same question `lib/sgr.sh` asks before emitting SGR 6 and
/// `altfont.lua` asks before emitting SGR 5, and it has the same shape: an
/// escape the terminal does not implement is not ignored, it is PRINTED. Over
/// ssh, in GNOME Terminal, inside `script`, an unguarded contact sheet is
/// eighty kilobytes of base64 across the screen.
pub fn supported() -> bool {
    std::env::var("TERM_PROGRAM").as_deref() == Ok("WezTerm")
}
