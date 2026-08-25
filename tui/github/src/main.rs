//! The `github` binary — a thin entry point.

use github::{index, Root};
use reticle::app;

fn main() -> std::io::Result<()> {
    // Same reasoning as font's and dots': Rust ignores SIGPIPE and turns the
    // write error into a panic, so `github --help | head` would print a
    // backtrace where every other command on the machine dies quietly.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    match std::env::args().nth(1).as_deref() {
        Some("-h") | Some("--help") => {
            println!("github         your repos, and everything about one");
            println!();
            println!("No flags. Run it anywhere for all your clones under ~/github,");
            println!("grouped by where you filed them; run it inside a repo and it");
            println!("opens on that one, with the list still underneath — so q walks");
            println!("up rather than quitting out of context.");
            println!();
            println!("Reads the disk, not the API: it opens instantly and works");
            println!("offline. Set GITHUB_DIR if your clones live elsewhere.");
            println!();
            println!("  j/k move · h/l close/open · gg/G ends");
            println!("  ctrl-d/u page · enter open · q quit");
        }
        _ => {
            let dir = index::root_dir();
            let root = Root::rooted(dir.clone());
            // Standing in a repo seeds the selection rather than switching
            // screens: the repo's own screens do not exist yet, and when they
            // do this becomes the stack `[root, repo]` via app::run_stack --
            // which is why the root is built the same way either way.
            let here = std::env::current_dir()
                .ok()
                .and_then(|cwd| index::current(&cwd, &dir));
            let screen = match &here {
                Some(repo) => root.focused_on(repo),
                None => root,
            };
            app::run_stack(vec![Box::new(screen)])?
        }
    }
    Ok(())
}
