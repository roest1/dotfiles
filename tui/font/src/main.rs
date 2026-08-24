//! The `font` binary — a thin entry point.
//!
//! Everything of substance is in the library beside this, so the `make it`
//! console can push the same screens rather than growing its own copy. What is
//! left here is argument handling and the one process-level concern below.

use font::{lanes, show, FontScreen};
use reticle::app;

fn main() -> std::io::Result<()> {
    // Rust ignores SIGPIPE and turns the resulting write error into a PANIC, so
    // `font inspect x.ttf | head` printed a backtrace instead of stopping. Every
    // other command-line tool on the machine dies quietly there; restoring the
    // default handler is what makes this one behave the same.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    match std::env::args().nth(1).as_deref() {
        Some("show") => {
            // Exits non-zero when a lane names a family this machine does not
            // have. status_fonts (lib/status.sh) counts drift on that and on
            // nothing else here -- see the note on the exit code in show.rs.
            std::process::exit(show::run());
        }
        Some("reset") => {
            let _ = std::fs::remove_file(lanes::state_path());
            println!("Fonts reset to the defaults in wezterm/wezterm.lua");
        }
        // Undocumented, for the CI check that the Rust list matches the bash
        // one it replaces. Not in --help: it is a test hook, not a feature.
        Some("-h") | Some("--help") => {
            println!("font           pick the font for each of wezterm's lanes");
            println!("font show      what is set now, and whether wezterm honors it");
            println!("font reset     back to the defaults wezterm.lua ships");
            println!();
            println!("Browsing Google's fonts is inside the picker: open a lane,");
            println!("then the last row under it. The screen explains its own keys.");
            println!();
            println!("in the picker: j/k move · h/l close/open · gg/G ends");
            println!("               ctrl-d/u page · enter set · q quit");
        }
        _ => {
            app::run(Box::new(FontScreen::new()))?;
        }
    }
    Ok(())
}
