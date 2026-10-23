//! The navigation contract, in one place.
//!
//! This exists as its own module for the reason `__fzf_menu` exists in
//! bash_productivity: the last time these bindings lived at each call site
//! there were eighteen copies of them, and they drifted. A screen does not get
//! to invent its own spelling of "go down" — it receives an `Action`.
//!
//! The bindings are nvim's, deliberately and completely: hjkl, gg/G, ctrl-d/u.
//! `github` reads as *nearly* nvim and that is worse than not trying, because
//! the keys you reach for by reflex are the ones it gets wrong.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Up,
    Down,
    /// `l`: expand the thing under the cursor, or -- if there is nothing to
    /// expand -- move RIGHT, into the pane.
    ///
    /// Not a synonym for `Activate`. It was, in the first few screens, and
    /// that made directional navigation impossible: `l` on a run drilled into
    /// its jobs, so the pane beside it could never be reached. A screen that
    /// does nothing with `Open` returns `Flow::Continue`, which `app` reads as
    /// "the cursor may move on".
    Open,
    /// `h`: collapse, or move LEFT out of the region.
    Close,
    Top,
    Bottom,
    PageDown,
    PageUp,
    Activate,
    /// Move to the next/previous sibling in a `Tabs` strip.
    ///
    /// `Tab` and shift-`Tab`, which were both unbound and are what a header
    /// strip trains your fingers to reach for. NOT `h`/`l`: those close and
    /// open a tree, and a screen with both a strip and a tree needs them to
    /// keep meaning that.
    NextTab,
    PrevTab,
    Help,
    Quit,
    /// Anything a screen wants to bind for itself. Kept as a single variant so
    /// adding one is a screen-local change and never an edit to this table.
    Key(char),
}

/// `g` is the only prefix, so "pending" is a bool rather than a state machine.
#[derive(Default)]
pub struct Keymap {
    pending_g: bool,
}

impl Keymap {
    pub fn resolve(&mut self, ev: KeyEvent) -> Option<Action> {
        let ctrl = ev.modifiers.contains(KeyModifiers::CONTROL);

        // `gg` goes to the top; a `g` followed by anything else is that
        // something else, not a swallowed keystroke.
        if self.pending_g {
            self.pending_g = false;
            if matches!(ev.code, KeyCode::Char('g')) {
                return Some(Action::Top);
            }
        }

        let action = match (ev.code, ctrl) {
            (KeyCode::Char('d'), true) => Action::PageDown,
            (KeyCode::Char('u'), true) => Action::PageUp,
            (KeyCode::Char('c'), true) => Action::Quit,
            (KeyCode::Char('j'), false) | (KeyCode::Down, _) => Action::Down,
            (KeyCode::Char('k'), false) | (KeyCode::Up, _) => Action::Up,
            (KeyCode::Char('l'), false) | (KeyCode::Right, _) => Action::Open,
            (KeyCode::Char('h'), false) | (KeyCode::Left, _) => Action::Close,
            (KeyCode::Char('G'), false) => Action::Bottom,
            (KeyCode::Char('g'), false) => {
                self.pending_g = true;
                return None;
            }
            (KeyCode::Enter, _) => Action::Activate,
            (KeyCode::Tab, _) => Action::NextTab,
            (KeyCode::BackTab, _) => Action::PrevTab,
            (KeyCode::Char('?'), false) => Action::Help,
            (KeyCode::Char('q'), false) | (KeyCode::Esc, _) => Action::Quit,
            (KeyCode::Char(c), false) => Action::Key(c),
            _ => return None,
        };
        Some(action)
    }
}
