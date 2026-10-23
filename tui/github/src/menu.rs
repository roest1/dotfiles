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
    /// Ask for one line, then run `argv` with the answer appended.
    ///
    /// For the handful of actions `gh` cannot prompt for itself: it will ask
    /// for a PR's title and body, but `gh api -X POST .../rename` wants a
    /// `new_name` as an argument. The template holds everything up to it.
    Prompt {
        label: String,
        initial: String,
        /// The command, with `{}` standing for the answer.
        argv: Vec<String>,
    },
}

pub struct Item {
    pub label: String,
    /// Dim text beside the label: what it is about to do, in the tool's own
    /// terms. `gh pr merge --squash` rather than "squashes the commits".
    pub detail: String,
    /// Said in the pane, for anything whose consequences are worth a sentence
    /// before you press enter.
    pub note: Vec<String>,
    /// True for anything that cannot be undone: red, a `!` badge, and the
    /// pane says so. Implies `asks`.
    pub destructive: bool,
    /// Require a `y` before this runs.
    ///
    /// This used to be absent, on the reasoning that the tool being run does
    /// the confirming and two confirms is one too many. That premise was
    /// false and the distinction it missed is the whole point: `git push
    /// --delete` REPORTS afterwards, it does not ASK beforehand, and `gh api
    /// -X POST .../rename` does neither. So deleting a remote branch was one
    /// `enter` from a menu row, which is not a price anyone agreed to.
    ///
    /// Reporting is not confirming. Where the tool genuinely does ask -- `gh
    /// pr create` stopping for a title, `gh auth refresh` printing a code and
    /// waiting -- this stays false, and there is still only one prompt.
    pub asks: bool,
    pub act: Act,
}

impl Item {
    pub fn new(label: impl Into<String>, detail: impl Into<String>, act: Act) -> Self {
        Self {
            label: label.into(),
            detail: detail.into(),
            note: Vec::new(),
            destructive: false,
            asks: false,
            act,
        }
    }

    pub fn note(mut self, lines: &[&str]) -> Self {
        self.note = lines.iter().map(|s| s.to_string()).collect();
        self
    }

    /// Ask before running. For anything that changes a shared thing --
    /// a default branch, a branch everyone has tracked.
    pub fn confirm(mut self) -> Self {
        self.asks = true;
        self
    }

    /// Cannot be undone. Implies `confirm`, because the one thing worse than
    /// an unconfirmed change is an unconfirmed irreversible one.
    pub fn danger(mut self) -> Self {
        self.destructive = true;
        self.asks = true;
        self
    }
}

/// An argv broken over lines that fit, at argument boundaries.
///
/// `argv.join(" ")` was fine while every command was `gh pr merge 86 --repo
/// x`. An environment's PUT carries the whole environment -- a wait timer,
/// four reviewers, a branch policy -- and came to three hundred characters,
/// which the pane truncated. A confirm you cannot read all of is not a
/// confirm, so this wraps instead.
///
/// A flag keeps the value after it, because `-F` on one line and
/// `reviewers[][id]=7` on the next reads as two things.
fn wrap_argv(argv: &[String], width: usize) -> Vec<String> {
    let width = width.max(12);
    let mut out: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut i = 0;
    while i < argv.len() {
        let mut piece = argv[i].clone();
        if piece.starts_with('-') && argv.get(i + 1).is_some_and(|n| !n.starts_with('-')) {
            piece.push(' ');
            piece.push_str(&argv[i + 1]);
            i += 1;
        }
        i += 1;
        if line.is_empty() {
            line = piece;
        } else if reticle::width::width(&line) + 1 + reticle::width::width(&piece) <= width {
            line.push(' ');
            line.push_str(&piece);
        } else {
            out.push(std::mem::take(&mut line));
            line = piece;
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    out
}

pub struct Menu {
    subject: String,
    kind: String,
    items: Vec<Item>,
    sel: usize,
    /// Set once something has run, so leaving the menu tells the screen
    /// underneath that its data is stale.
    ran: bool,
    /// The item whose question is outstanding. The screen has to remember
    /// what it asked -- `app` carries the text and nothing else.
    asking: Option<usize>,
    /// An item waiting on a `y`, with the command already resolved -- so the
    /// prompt can show exactly what is about to run, including whatever was
    /// typed into a field a moment ago.
    pending: Option<(usize, Vec<String>)>,
}

impl Menu {
    pub fn new(kind: impl Into<String>, subject: impl Into<String>, items: Vec<Item>) -> Self {
        Self {
            subject: subject.into(),
            kind: kind.into(),
            items,
            sel: 0,
            ran: false,
            asking: None,
            pending: None,
        }
    }

    /// Either run it, or ask first.
    fn go(&mut self, i: usize, argv: Vec<String>) -> Flow {
        if self.items.get(i).is_some_and(|it| it.asks) {
            self.pending = Some((i, argv));
            return Flow::Dirty;
        }
        self.ran = true;
        Flow::Detach(argv)
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
        // Any focus call withdraws a pending confirm, not only one that moves.
        // `app` calls this only when the cursor actually changed, so the
        // unconditional version is equivalent and has no guard to reason
        // about -- and the guarded version's subtlety is exactly the sort of
        // thing that leaves a delete armed.
        self.pending = None;
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
        if let Some((_, argv)) = &self.pending {
            lines.push(format!("{ORG}About to run:{OFF}"));
            lines.push(String::new());
            for line in wrap_argv(argv, cols as usize - 4) {
                lines.push(format!("  {BOLD}{line}{OFF}"));
            }
            lines.push(String::new());
            if item.destructive {
                lines.push(format!("{RED}This cannot be undone.{OFF}"));
                lines.push(String::new());
            }
            lines.push(format!(
                "{ORG}y{OFF} to go ahead \u{b7} any other key leaves it"
            ));
            return Pane { image: None, lines };
        }
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
                for line in wrap_argv(argv, cols as usize - 4) {
                    lines.push(format!("  {ORG}{line}{OFF}"));
                }
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}on the real terminal, so it can prompt and you see{OFF}"
                ));
                lines.push(format!("{DIM}its own output.{OFF}"));
            }
            Act::Open(_) => lines.push(format!("{DIM}opens a screen{OFF}")),
            Act::Back => lines.push(format!("{DIM}closes this menu{OFF}")),
            Act::Prompt { argv, label, .. } => {
                lines.push(format!("{GRY}asks:{OFF}"));
                lines.push(format!("  {ORG}{label}{OFF}"));
                lines.push(String::new());
                lines.push(format!("{GRY}then runs:{OFF}"));
                for line in wrap_argv(argv, cols as usize - 4) {
                    lines.push(format!("  {ORG}{line}{OFF}"));
                }
            }
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        // A pending confirm consumes the very next key, whatever it is. Only
        // `y` acts; everything else withdraws. Safe by construction rather
        // than by bookkeeping -- a stale prompt cannot turn a later keystroke
        // into a delete, because the later keystroke is not a `y`.
        if let Some((_, argv)) = self.pending.take() {
            return match action {
                Action::Key('y') | Action::Key('Y') => {
                    self.ran = true;
                    Flow::Detach(argv)
                }
                _ => Flow::Dirty,
            };
        }
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
                let argv = argv.clone();
                self.go(sel, argv)
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
            Act::Prompt { label, initial, .. } => {
                let (label, initial) = (label.clone(), initial.clone());
                self.asking = Some(sel);
                Flow::Ask { label, initial }
            }
        }
    }

    /// The answer to the one question a menu can ask.
    fn answered(&mut self, text: Option<String>) -> Flow {
        let Some(i) = self.asking.take() else {
            return Flow::Continue;
        };
        // Abandoned, or typed nothing. An empty answer is a cancel rather than
        // a command run with an empty argument -- `--delete ""` is not
        // something to find out about afterwards.
        let Some(text) = text.filter(|t| !t.trim().is_empty()) else {
            return Flow::Dirty;
        };
        let Some(Act::Prompt { argv, .. }) = self.items.get(i).map(|it| &it.act) else {
            return Flow::Continue;
        };
        let filled: Vec<String> = argv.iter().map(|a| a.replace("{}", text.trim())).collect();
        // The confirm comes AFTER the field, so what it shows is the command
        // that will actually run, with the name just typed in it. Asking first
        // would be confirming a template.
        self.go(i, filled)
    }

    fn footer(&self) -> String {
        if self.pending.is_some() {
            return "y to go ahead \u{b7} any other key leaves it".into();
        }
        match self.items.get(self.sel) {
            Some(i) if i.destructive => "enter asks, then y \u{b7} cannot be undone".into(),
            Some(i) if i.asks => "enter asks, then y".into(),
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

    /// A long command wraps at argument boundaries rather than being cut, and
    /// a flag keeps the value that belongs to it. An environment PUT is three
    /// hundred characters, and a confirm you cannot read all of is not one.
    #[test]
    fn a_long_command_wraps_instead_of_being_truncated() {
        let argv: Vec<String> = [
            "gh",
            "api",
            "-X",
            "PUT",
            "repos/vercel/next.js/environments/bot-approved",
            "--silent",
            "-F",
            "wait_timer=5",
            "-F",
            "reviewers[][type]=Team",
            "-F",
            "reviewers[][id]=7",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let lines = wrap_argv(&argv, 44);
        assert!(lines.len() > 1, "{lines:?}");
        for l in &lines {
            assert!(reticle::width::width(l) <= 44 || !l.contains(' '), "{l:?}");
        }
        // Nothing lost, and the flags kept their values.
        assert_eq!(lines.join(" "), argv.join(" "));
        assert!(
            lines.iter().any(|l| l.contains("-F wait_timer=5")),
            "{lines:?}"
        );
        assert!(
            !lines.iter().any(|l| l.trim_end().ends_with("-F")),
            "a flag was orphaned: {lines:?}"
        );
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
        assert!(m.footer().contains("cannot be undone"), "{}", m.footer());
        assert!(m
            .pane(1, 60, 40)
            .lines
            .join("\n")
            .contains("cannot be undone"));
    }

    /// The hole Riley spotted, and it was wider than rename: deleting a remote
    /// branch was ONE `enter` from a menu row. The note claimed the tool does
    /// the confirming, but `git push --delete` only REPORTS afterwards and
    /// `gh api -X POST` does neither. Reporting is not confirming.
    #[test]
    fn a_destructive_item_cannot_run_on_one_keypress() {
        let mut m = menu();
        // Item 1 is the delete. Enter asks rather than acting.
        assert!(matches!(m.on_action(Action::Activate, 1), Flow::Dirty));
        assert!(!m.ran(), "it ran on the first enter");
        assert!(m.footer().contains("y to go ahead"));
        // The pane shows the command about to run, which IS the confirmation.
        assert!(m.pane(1, 60, 40).lines.join("\n").contains("About to run"));
        assert!(matches!(m.on_action(Action::Key('y'), 1), Flow::Detach(_)));
        assert!(m.ran());
    }

    /// Anything that is not `y` withdraws -- including a second `enter`, which
    /// is the key most likely to be leaned on.
    #[test]
    fn only_y_goes_ahead() {
        for a in [
            Action::Activate,
            Action::Key('n'),
            Action::Key('d'),
            Action::Down,
            Action::Close,
        ] {
            let mut m = menu();
            m.on_action(Action::Activate, 1);
            assert!(
                !matches!(m.on_action(a, 1), Flow::Detach(_)),
                "{a:?} ran it"
            );
            assert!(!m.ran(), "{a:?} ran it");
        }
        // And moving the cursor withdraws it.
        let mut m = menu();
        m.focus(1);
        m.on_action(Action::Activate, 1);
        assert!(m.pending.is_some());
        m.focus(0);
        assert!(m.pending.is_none());
    }

    /// A prompt confirms AFTER the field, so what gets approved is the command
    /// with the name just typed in it rather than a template.
    #[test]
    fn a_prompt_that_confirms_shows_the_filled_command() {
        let mut m = Menu::new(
            "branch",
            "feat/x",
            vec![Item::new(
                "Rename",
                "gh api",
                Act::Prompt {
                    label: "to".into(),
                    initial: "feat/x".into(),
                    argv: vec!["gh".into(), "-f".into(), "new_name={}".into()],
                },
            )
            .confirm()],
        );
        assert!(matches!(m.on_action(Action::Activate, 0), Flow::Ask { .. }));
        // The answer does not run it -- it asks.
        assert!(matches!(m.answered(Some("feat/y".into())), Flow::Dirty));
        assert!(!m.ran());
        let pane = m.pane(0, 60, 40).lines.join("\n");
        assert!(pane.contains("new_name=feat/y"), "{pane}");
        match m.on_action(Action::Key('y'), 0) {
            Flow::Detach(argv) => assert_eq!(argv.last().unwrap(), "new_name=feat/y"),
            _ => panic!("y must run it"),
        }
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

    /// A prompt asks before it runs, and runs with the answer substituted.
    #[test]
    fn a_prompt_fills_the_template_with_what_was_typed() {
        let mut m = Menu::new(
            "branch",
            "feat/x",
            vec![Item::new(
                "Rename",
                "gh api",
                Act::Prompt {
                    label: "rename feat/x to".into(),
                    initial: "feat/x".into(),
                    argv: vec!["gh".into(), "api".into(), "-f".into(), "new_name={}".into()],
                },
            )],
        );
        // Enter asks rather than acting.
        match m.on_action(Action::Activate, 0) {
            Flow::Ask { label, initial } => {
                assert_eq!(label, "rename feat/x to");
                assert_eq!(initial, "feat/x", "a rename starts from the old name");
            }
            _ => panic!("a prompt must ask first"),
        }
        assert!(!m.ran(), "nothing has run yet");
        match m.answered(Some("  feat/y  ".into())) {
            // Trimmed: a trailing space from a paste must not become part of
            // the branch name.
            Flow::Detach(argv) => assert_eq!(argv.last().unwrap(), "new_name=feat/y"),
            _ => panic!("an answer must run the command"),
        }
        assert!(m.ran());
    }

    /// An abandoned or empty answer runs NOTHING. `--delete ""` is not
    /// something to find out about afterwards.
    #[test]
    fn an_empty_answer_is_a_cancel_rather_than_an_empty_argument() {
        let make = || {
            Menu::new(
                "branch",
                "feat/x",
                vec![Item::new(
                    "Rename",
                    "gh api",
                    Act::Prompt {
                        label: "to".into(),
                        initial: String::new(),
                        argv: vec!["gh".into(), "-f".into(), "new_name={}".into()],
                    },
                )],
            )
        };
        for answer in [None, Some(String::new()), Some("   ".into())] {
            let mut m = make();
            m.on_action(Action::Activate, 0);
            assert!(
                !matches!(m.answered(answer.clone()), Flow::Detach(_)),
                "{answer:?} ran a command"
            );
            assert!(!m.ran(), "{answer:?} marked the menu as having run");
        }
    }

    /// An answer arriving when nothing was asked must not run the row the
    /// cursor happens to be on.
    #[test]
    fn an_unexpected_answer_does_nothing() {
        let mut m = menu();
        assert!(matches!(m.answered(Some("yes".into())), Flow::Continue));
        assert!(!m.ran());
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
