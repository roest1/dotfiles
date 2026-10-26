//! The `dots` binary — a thin entry point.

use dots::Console;
use reticle::app;

fn main() -> std::io::Result<()> {
    // Same reasoning as font's: Rust ignores SIGPIPE and turns the write error
    // into a panic, so `dots --help | head` would print a backtrace where every
    // other command on the machine dies quietly.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    match std::env::args().nth(1).as_deref() {
        Some("-h") | Some("--help") => {
            println!("dots           the dotfiles console — targets, sections, fonts");
            println!();
            println!("Everything is inside the TUI; it states its own keys in the");
            println!("footer. Targets run on the real terminal, so sudo can prompt.");
            println!("space picks which sections THIS machine sweeps, written to");
            println!("~/.config/dotfiles/sections — never to deps.conf.");
            println!();
            println!("  j/k move · h/l close/open · gg/G ends");
            println!("  ctrl-d/u page · enter run or open · space toggle · q quit");
        }
        _ => app::run(Box::new(Console::new()))?,
    }
    Ok(())
}
