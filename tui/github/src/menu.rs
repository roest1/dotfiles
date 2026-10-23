//! A row's actions, as a screen.
//!
//! The three-dots menu from the design doc, and the mechanism that makes "full
//! functionality, all in a TUI" affordable. It needs nothing from `reticle`
//! that was not already there: a menu is a list of labelled rows, `Flow::Push`
//! opens it over the screen it came from, and `q` closes it.
//!
//! ## Why a menu rather than focusable buttons on the row
//!
//! The design draws `[PR]`, a trash can and a `…` on each branch row. The
//! FUNCTIONS all belong -- this repo's own rule is that a key you have to be
//! told about is a key nobody finds, so a visible, labelled action beats a
//! hidden keybinding. What a menu avoids is the only expensive part: putting
//! the cursor ON a button inside a row needs column-wise focus, a second
//! navigation axis, and it would collide with `h`/`l` meaning close/open
//! everywhere else. A menu gets the same functionality on one axis.
//!
//! The bash implementation already worked this way -- `enter` on a PR row
//! opens thirteen actions, `enter` on a branch row opens seven -- so this is
//! the shape being ported, not a new idea.
//!
//! ## Why most items are `Flow::Detach`
//!
//! Because `gh` and `git` are already interactive. `gh pr create` prompts for a
//! title and body; `gh pr edit` prompts for what to change; `git push --delete`
//! prints what it did and fails loudly. Handing them the real terminal gets
//! text entry, confirmation and error reporting for free, in the words the
//! tools themselves use -- so "full functionality" does NOT wait on a text
//! input widget in `reticle`. That was the surprise of building this.
//!
//! An item that only reads can still do its work in-process and return
//! `Flow::Dirty`; `act` decides.

use reticle::{nav::Action, Flow, Pane, Row, Screen, Tick};

use crate::paint::{BOLD, DIM, GRY, OFF, ORG, RED};

/// What an item does when chosen.
pub enum Act {
    /// Hand over the terminal and run this, then come back. The program is
    /// first; nothing goes through a shell.
    Run(Vec<String>),
    /// Open another screen on top.
    Open(Box<dyn Screen>),
    /// Close the menu and tell the screen underneath to re-read.
    Back,
}

pub struct Item {
    pub label: String,
    /// Dim text beside the label: what it is about to do, in the tool's own
    /// terms. `gh pr merge --squash` rather than "squashes the commits".
    pub detail: String,
    /// Said in the pane, for anything whose consequences are worth a sentence
    /// before you press enter.
    pub note: Vec<String>,
    /// True for anything that cannot be undone, which draws it in red and
    /// says so in the pane. It does NOT add a prompt -- the tool being run
    /// does that, and two confirms is one too many.
    pub destructive: bool,
    pub act: Act,
}

impl Item {
    pub fn new(label: impl Into<String>, detail: impl Into<String>, act: Act) -> Self {
        Self {
            label: label.into(),
            detail: detail.into(),
            note: Vec::new(),
            destructive: false,
            act,
        }
    }

    pub fn note(mut self, lines: &[&str]) -> Self {
        self.note = lines.iter().map(|s| s.to_string()).collect();
        self
    }

    pub fn danger(mut self) -> Self {
        self.destructive = true;
        self
    }
}

pub struct Menu {
    subject: String,
    kind: String,
    items: Vec<Item>,
    sel: usize,
    /// Set once something has run, so leaving the menu tells the screen
    /// underneath that its data is stale.
    ran: bool,
}

impl Menu {
    pub fn new(kind: impl Into<String>, subject: impl Into<String>, items: Vec<Item>) -> Self {
        Self {
            subject: subject.into(),
            kind: kind.into(),
            items,
            sel: 0,
            ran: false,
        }
    }

    /// Did anything run? The screen underneath reads this after the pop to
    /// decide whether to refetch.
    pub fn ran(&self) -> bool {
        self.ran
    }
}

impl Screen for Menu {
    fn title(&self) -> String {
        format!("{} \u{b7} {}", self.kind, self.subject)
    }

    fn focus(&mut self, sel: usize) {
        self.sel = sel;
    }

    fn tick(&mut self) -> Tick {
        Tick::Idle
    }

    fn rows(&mut self) -> Vec<Row> {
        self.items
            .iter()
            .map(|i| {
                let r = Row::leaf(&i.label).detail(i.detail.clone());
                if i.destructive {
                    r.badged("!", crate::paint::idx::RED)
                } else {
                    r
                }
            })
            .collect()
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = Vec::new();
        let Some(item) = self.items.get(sel) else {
            return Pane { image: None, lines };
        };
        lines.push(format!("{BOLD}{}{OFF}", item.label));
        lines.push(format!("{GRY}{}{OFF}", self.subject));
        lines.push(crate::paint::rule(cols));
        if item.destructive {
            lines.push(format!("{RED}This cannot be undone.{OFF}"));
            lines.push(String::new());
        }
        lines.extend(item.note.iter().cloned());
        if !item.note.is_empty() {
            lines.push(String::new());
        }
        match &item.act {
            // Showing the command is the honest version of a confirmation: you
            // can see exactly what is about to run, in the words you would
            // have typed.
            Act::Run(argv) => {
                lines.push(format!("{GRY}runs:{OFF}"));
                lines.push(format!("  {ORG}{}{OFF}", argv.join(" ")));
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}on the real terminal, so it can prompt and you see{OFF}"
                ));
                lines.push(format!("{DIM}its own output.{OFF}"));
            }
            Act::Open(_) => lines.push(format!("{DIM}opens a screen{OFF}")),
            Act::Back => lines.push(format!("{DIM}closes this menu{OFF}")),
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        // Enter alone. `l` would be a second key that runs a delete, which is
        // the one place in this program where an extra way to act is a cost
        // rather than a convenience.
        if action != Action::Activate {
            return Flow::Continue;
        }
        let Some(item) = self.items.get_mut(sel) else {
            return Flow::Continue;
        };
        match &mut item.act {
            Act::Run(argv) => {
                self.ran = true;
                Flow::Detach(argv.clone())
            }
            // Taken rather than cloned, because a `Box<dyn Screen>` is not
            // cloneable and a menu item is chosen once. Re-choosing it finds
            // `Back`, which closes the menu -- the screen it opened is on top
            // by then anyway.
            Act::Open(_) => {
                let taken = std::mem::replace(&mut item.act, Act::Back);
                match taken {
                    Act::Open(screen) => Flow::Push(screen),
                    _ => Flow::Continue,
                }
            }
            Act::Back => Flow::Pop,
        }
    }

    fn footer(&self) -> String {
        match self.items.get(self.sel) {
            Some(i) if i.destructive => "enter runs it \u{b7} it will say what it did".into(),
            Some(_) => "enter runs it".into(),
            None => "nothing here".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn menu() -> Menu {
        Menu::new(
            "branch",
            "feat/x",
            vec![
                Item::new(
                    "Checkout",
                    "git switch",
                    Act::Run(vec!["git".into(), "switch".into()]),
                ),
                Item::new("Delete", "git push --delete", Act::Run(vec!["git".into()])).danger(),
            ],
        )
    }

    /// The pane SHOWS the command. That is the confirmation -- you read what is
    /// about to run in the words you would have typed, rather than answering a
    /// yes/no about a description of it.
    #[test]
    fn the_pane_names_the_command_before_you_run_it() {
        let mut m = menu();
        let text = m.pane(0, 60, 40).lines.join("\n");
        assert!(text.contains("git switch"), "{text}");
    }

    /// A destructive item is marked in the row, in the pane and in the footer.
    /// One of the three is easy to miss.
    #[test]
    fn a_destructive_item_says_so_three_times() {
        let mut m = menu();
        let rows = m.rows();
        assert!(rows[0].badges.is_empty());
        assert_eq!(rows[1].badges.first().map(|b| b.0.as_str()), Some("!"));
        m.focus(1);
        assert!(m.footer().contains("say what it did"));
        assert!(m
            .pane(1, 60, 40)
            .lines
            .join("\n")
            .contains("cannot be undone"));
    }

    /// Choosing an item detaches and records that something ran, which is how
    /// the screen underneath knows to refetch after the pop.
    #[test]
    fn running_an_item_marks_the_menu_dirty() {
        let mut m = menu();
        assert!(!m.ran());
        assert!(matches!(m.on_action(Action::Activate, 0), Flow::Detach(_)));
        assert!(m.ran());
    }

    /// Only enter acts. Every other key has to fall through, or a stray
    /// keystroke in a menu holding a delete would run it.
    #[test]
    fn no_other_key_can_trigger_an_item() {
        let mut m = menu();
        for a in [
            Action::Down,
            Action::Key('d'),
            Action::Key('y'),
            Action::Close,
        ] {
            assert!(matches!(m.on_action(a, 1), Flow::Continue), "{a:?} acted");
        }
        assert!(!m.ran());
    }
}
