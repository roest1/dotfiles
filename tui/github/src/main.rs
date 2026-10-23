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
            println!("The repo list reads the disk, not the API: it opens instantly");
            println!("and works offline. Set GITHUB_DIR if your clones live");
            println!("elsewhere.");
            println!();
            println!("Enter on a repo opens it as five tabs: branches, pull");
            println!("requests, workflow runs, secrets and environments. The runs");
            println!("open with the failing step's log already in the pane; a run");
            println!("still going refreshes itself until it stops, and completed");
            println!("runs are cached, so last week's failure opens instantly in a");
            println!("shell that has never seen it.");
            println!();
            println!("hjkl everywhere, including between the tab strip, a sidebar");
            println!("and the list. There is no key that jumps to the tabs: k off");
            println!("the top row reaches them.");
            println!();
            println!("  j/k move · h/l close/open, or across · gg/G ends");
            println!("  ctrl-d/u page · enter open · / filter · q back, out at the top");
            println!();
            println!("  o browser · r refresh, on every screen that fetches");
            println!("  on the runs list: b the other scope · e rerun · x cancel · L log");
        }
        _ => {
            let dir = index::root_dir();
            let root = Root::rooted(dir.clone());
            // Standing in a repo seeds the SELECTION, not the root. There is
            // one root -- the user level -- and being in a repo opens its
            // Repos tab on that repo, so `q` walks up from a workflow run to
            // the repo list to the account rather than quitting out of
            // context. Two roots could not connect, which is the whole reason
            // this is built this way.
            let here = std::env::current_dir()
                .ok()
                .and_then(|cwd| index::current(&cwd, &dir));
            let root = match &here {
                Some(repo) => root.focused_on(repo),
                None => root,
            };
            let fetch = std::sync::Arc::new(github::gh::Fetcher::new(""));
            let me = github::user::login();
            let user = github::user::screen(fetch, root.as_me(&me), &me);
            app::run_stack(vec![Box::new(user)])?
        }
    }
    Ok(())
}
