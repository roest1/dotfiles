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
    /// `/` — start narrowing this list.
    Find,
    /// A character typed while a text field has the keyboard.
    ///
    /// The mode is HERE rather than in `app` for the reason this file exists:
    /// it is the one place a key is given a meaning. A second table in the
    /// loop would be a second place to look when `b` stops toggling the branch
    /// scope because something is listening for text.
    Type(char),
    Backspace,
    /// Clear the whole field — ctrl-u, which is `PageUp` when not typing.
    Clear,
    /// Enter, while typing: take it.
    Accept,
    /// Esc, while typing: abandon it.
    Cancel,
    /// Anything a screen wants to bind for itself. Kept as a single variant so
    /// adding one is a screen-local change and never an edit to this table.
    Key(char),
}

/// `g` is the only prefix, so "pending" is a bool rather than a state machine.
#[derive(Default)]
pub struct Keymap {
    pending_g: bool,
    typing: bool,
}

impl Keymap {
    /// Switch between the two tables.
    ///
    /// There are exactly two and the difference is total: while a text field
    /// has the keyboard, a bare character is TEXT, and the single-key actions
    /// that make these screens quick -- `o`, `r`, `b`, `e` -- would otherwise
    /// fire on the first letter of anything you typed. That is the whole
    /// reason filtering needed a framework change rather than a screen one.
    pub fn typing(&mut self, on: bool) {
        self.typing = on;
        if on {
            // A half-typed `g` must not survive into a text field and swallow
            // the next keystroke.
            self.pending_g = false;
        }
    }

    pub fn resolve(&mut self, ev: KeyEvent) -> Option<Action> {
        let ctrl = ev.modifiers.contains(KeyModifiers::CONTROL);

        if self.typing {
            return match (ev.code, ctrl) {
                // ctrl-c still leaves, from anywhere. A text field you cannot
                // get out of is the one way this could trap someone.
                (KeyCode::Char('c'), true) => Some(Action::Quit),
                (KeyCode::Char('u'), true) => Some(Action::Clear),
                (KeyCode::Char(c), false) => Some(Action::Type(c)),
                (KeyCode::Backspace, _) => Some(Action::Backspace),
                (KeyCode::Enter, _) => Some(Action::Accept),
                (KeyCode::Esc, _) => Some(Action::Cancel),
                // Arrows keep working, so the cursor can move through a
                // filtered list without leaving the field.
                (KeyCode::Down, _) => Some(Action::Down),
                (KeyCode::Up, _) => Some(Action::Up),
                _ => None,
            };
        }

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
            (KeyCode::Char('/'), false) => Action::Find,
            (KeyCode::Char('?'), false) => Action::Help,
            (KeyCode::Char('q'), false) | (KeyCode::Esc, _) => Action::Quit,
            (KeyCode::Char(c), false) => Action::Key(c),
            _ => return None,
        };
        Some(action)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn key(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)
    }
    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    /// The whole point of the mode. Out of it, `o` opens a browser; in it, `o`
    /// is the letter o -- and a screen full of single-key actions is why
    /// filtering could not be done without this.
    #[test]
    fn the_same_letter_means_two_different_things() {
        let mut k = Keymap::default();
        assert_eq!(k.resolve(key('o')), Some(Action::Key('o')));
        k.typing(true);
        assert_eq!(k.resolve(key('o')), Some(Action::Type('o')));
        k.typing(false);
        assert_eq!(k.resolve(key('o')), Some(Action::Key('o')));
    }

    /// `/` starts it, and is not a screen key.
    #[test]
    fn slash_starts_a_search() {
        let mut k = Keymap::default();
        assert_eq!(k.resolve(key('/')), Some(Action::Find));
    }

    /// A text field you cannot leave is the one way this traps someone, so
    /// three keys get you out and one of them works everywhere.
    #[test]
    fn there_are_three_ways_out_of_a_field() {
        let mut k = Keymap::default();
        k.typing(true);
        assert_eq!(
            k.resolve(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)),
            Some(Action::Cancel)
        );
        assert_eq!(
            k.resolve(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)),
            Some(Action::Accept)
        );
        assert_eq!(k.resolve(ctrl('c')), Some(Action::Quit));
    }

    /// Moving the cursor without leaving the field, which is what makes
    /// "type a bit, arrow down, enter" work.
    #[test]
    fn arrows_still_navigate_while_typing() {
        let mut k = Keymap::default();
        k.typing(true);
        assert_eq!(
            k.resolve(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)),
            Some(Action::Down)
        );
        // But `j` is a letter now.
        assert_eq!(k.resolve(key('j')), Some(Action::Type('j')));
    }

    /// A pending `g` must not survive into a field and eat the next key.
    #[test]
    fn a_half_typed_prefix_does_not_cross_the_boundary() {
        let mut k = Keymap::default();
        assert_eq!(k.resolve(key('g')), None, "g is a prefix");
        k.typing(true);
        assert_eq!(k.resolve(key('g')), Some(Action::Type('g')));
    }

    /// ctrl-u is PageUp out of a field and "clear it" inside one, which is the
    /// readline meaning and the only overload here.
    #[test]
    fn ctrl_u_changes_meaning_with_the_mode() {
        let mut k = Keymap::default();
        assert_eq!(k.resolve(ctrl('u')), Some(Action::PageUp));
        k.typing(true);
        assert_eq!(k.resolve(ctrl('u')), Some(Action::Clear));
    }
}
