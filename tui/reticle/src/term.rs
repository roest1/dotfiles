//! Owning the terminal, and giving it back.
//!
//! The whole reason a hand-written TUI costs more than fzf is this file: raw
//! mode, the alternate screen and a hidden cursor are three pieces of global
//! state borrowed from the user's shell, and every exit path has to return all
//! three. `lib/tui.sh` does it with a trap; here it is a guard whose `Drop`
//! runs on normal return, on `?` propagation, and on unwind.
//!
//! The panic hook is not belt-and-braces. Without it a panic unwinds straight
//! past `Drop` ordering guarantees you would rather not reason about and leaves
//! a shell in raw mode with no echo — a terminal the user has to blind-type
//! `reset` into. Restoring first, then printing the panic, means the message is
//! readable when it arrives.

use std::io::{self, Write};
use std::panic;

use crossterm::{
    cursor,
    event::{DisableMouseCapture, EnableMouseCapture},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};

pub struct Terminal {
    restored: bool,
}

impl Terminal {
    /// Take the terminal. Fails on a pipe rather than corrupting it — the
    /// caller is expected to fall back to plain output, the way `make it`
    /// prints its index when it cannot open.
    pub fn take() -> io::Result<Self> {
        enable_raw_mode()?;
        let mut out = io::stdout();
        execute!(out, EnterAlternateScreen, EnableMouseCapture, cursor::Hide)?;
        out.flush()?;

        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            let _ = restore_now();
            previous(info);
        }));

        Ok(Self { restored: false })
    }

    pub fn size() -> io::Result<(u16, u16)> {
        crossterm::terminal::size()
    }

    /// Give the terminal back for the duration of a child process, then take
    /// it again. This is how `dots` runs a make target: the child inherits the
    /// REAL tty, so `sudo` can prompt, colour works, and the output is exactly
    /// what you would have seen typing the command yourself.
    ///
    /// Deliberately not `restore()` followed by `take()`. `take()` installs a
    /// panic hook that wraps the previous one, so re-taking once per run would
    /// stack a hook per invocation for the life of the process. These two touch
    /// only the three pieces of state that actually need to move.
    pub fn suspend(&mut self) -> io::Result<()> {
        if self.restored {
            return Ok(());
        }
        let mut out = io::stdout();
        execute!(out, DisableMouseCapture, cursor::Show, LeaveAlternateScreen)?;
        disable_raw_mode()?;
        out.flush()
    }

    pub fn resume(&mut self) -> io::Result<()> {
        if self.restored {
            return Ok(());
        }
        enable_raw_mode()?;
        let mut out = io::stdout();
        execute!(out, EnterAlternateScreen, EnableMouseCapture, cursor::Hide)?;
        out.flush()
    }

    /// Idempotent, because `Drop` and an explicit call must not double-restore.
    pub fn restore(&mut self) -> io::Result<()> {
        if self.restored {
            return Ok(());
        }
        self.restored = true;
        restore_now()
    }
}

fn restore_now() -> io::Result<()> {
    let mut out = io::stdout();
    let _ = execute!(out, DisableMouseCapture, cursor::Show, LeaveAlternateScreen);
    let _ = disable_raw_mode();
    out.flush()
}

impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}
