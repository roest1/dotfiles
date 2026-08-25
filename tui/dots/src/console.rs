//! The root screen: everything this repo can do, in one tree.
//!
//! The point is not to save typing — `make status` is nine characters. It is to
//! remove the requirement that you already KNOW `make status` exists, and what
//! it answers, and how it differs from `make check`. A tree you can walk
//! answers all three without you having asked a question.
//!
//! Three kinds of row, and they behave differently on Enter for a reason:
//!
//!   targets    run, on the real tty (see Flow::Detach)
//!   sections   open, because a section is an ARGUMENT and not a target --
//!              `make nvim` is a no-op stub, and running `make install nvim`
//!              off one keystroke is more than the keystroke said
//!   fonts      push font's own picker, the same type its binary runs

use std::path::PathBuf;

use reticle::{nav::Action, Flow, Pane, Row, Screen, Tick};

use crate::repo::{self, Section, Target};
use crate::run::Run;

pub struct Console {
    root: PathBuf,
    targets: Vec<Target>,
    sections: Vec<Section>,
    open: Option<usize>,
    status: String,
    run: Option<Run>,
    /// `footer()` takes no selection, so the last focused row is remembered
    /// here. Keeping the footer in step with what the cursor is actually on is
    /// the whole reason it exists -- a static footer offering `enter run` over
    /// a section row is worse than no footer.
    focus_sel: usize,
}

/// What the cursor is sitting on, resolved once so `pane`, `on_action` and
/// `footer` cannot disagree about it. They used to each re-derive it, and the
/// footer offering `enter run` on a section row was the bug that produced.
enum At {
    TargetsHeader,
    Target(usize),
    SectionsHeader,
    Section(usize),
    SectionVerb(usize, &'static str),
    Fonts,
    Nothing,
}

const VERBS: [&str; 3] = ["install", "link", "check"];

/// The targets that can reach `sudo`, and therefore the only ones that are NOT
/// streamed into the pane.
///
///   install   lib/pkg.sh's pkg_install -> `sudo apt|dnf install`
///   shell     the Makefile's own recipe -> `sudo tee -a /etc/shells`
///
/// They detach instead: the terminal goes back, the real sudo prompts in the
/// open, and this process never sees a password. Every alternative — an askpass
/// helper, `sudo -S`, a NOPASSWD drop-in — ends with a dotfiles repo handling
/// credentials, and a feel-good feature does not buy that.
///
/// `repo::escalating_targets` re-derives this from the tree and a test asserts
/// the two agree, so a new sudo call site anywhere breaks the build rather than
/// silently arriving inside a streamed pane.
pub const ESCALATES: [&str; 2] = ["install", "shell"];

fn plural(n: usize, word: &str) -> String {
    if n == 1 {
        format!("{n} {word}")
    } else {
        format!("{n} {word}s")
    }
}

impl Default for Console {
    fn default() -> Self {
        Self::new()
    }
}

impl Console {
    pub fn new() -> Self {
        let root = repo::root().unwrap_or_else(|| PathBuf::from("."));
        Self {
            targets: repo::targets(&root),
            sections: repo::sections(&root),
            root,
            open: None,
            status: String::new(),
            run: None,
            focus_sel: 0,
        }
    }

    fn at(&self, sel: usize) -> At {
        let mut i = 0;
        if sel == i {
            return At::TargetsHeader;
        }
        i += 1;
        for t in 0..self.targets.len() {
            if sel == i {
                return At::Target(t);
            }
            i += 1;
        }
        i += 1; // spacer
        if sel == i {
            return At::SectionsHeader;
        }
        i += 1;
        for s in 0..self.sections.len() {
            if sel == i {
                return At::Section(s);
            }
            i += 1;
            if self.open == Some(s) {
                for v in VERBS {
                    if sel == i {
                        return At::SectionVerb(s, v);
                    }
                    i += 1;
                }
            }
        }
        i += 1; // spacer
        if sel == i {
            return At::Fonts;
        }
        At::Nothing
    }

    /// Stream it, unless it can escalate — then hand the terminal over.
    ///
    /// -C rather than a chdir either way, so the child's cwd is the repo
    /// without this process ever moving: `dots` may be running from anywhere
    /// under it, and a later screen reading a relative path would inherit it.
    fn make(&mut self, args: &[&str], label: &str) -> Flow {
        if ESCALATES.contains(&label) {
            let mut argv = vec![
                "make".to_string(),
                "-C".to_string(),
                self.root.display().to_string(),
                "--no-print-directory".to_string(),
            ];
            argv.extend(args.iter().map(|s| s.to_string()));
            return Flow::Detach(argv);
        }
        let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        match Run::start(&self.root, &owned, label) {
            Ok(run) => self.run = Some(run),
            Err(e) => self.status = format!("could not start make {label}: {e}"),
        }
        Flow::Dirty
    }
}

impl Screen for Console {
    fn title(&self) -> String {
        "dots".into()
    }

    fn focus(&mut self, sel: usize) {
        self.focus_sel = sel;
    }

    fn rows(&mut self) -> Vec<Row> {
        let mut rows = Vec::new();

        let mut header = Row::leaf("targets");
        header.group = true;
        header.expanded = true;
        rows.push(header.detail("what make can do"));
        for t in &self.targets {
            rows.push(Row::leaf(&t.name).detail(&t.summary));
        }

        rows.push(Row::spacer());
        let mut header = Row::leaf("sections");
        header.group = true;
        header.expanded = true;
        rows.push(header.detail("declared in deps.conf"));
        for (i, s) in self.sections.iter().enumerate() {
            let mut r = Row::leaf(&s.name);
            r.depth = 0;
            r.group = true;
            r.expanded = self.open == Some(i);
            rows.push(r.detail(format!(
                "{} · {}",
                plural(s.links, "link"),
                plural(s.tools, "tool")
            )));
            if self.open == Some(i) {
                for v in VERBS {
                    let mut r = Row::leaf(format!("make {v} {}", s.name));
                    r.depth = 1;
                    rows.push(r);
                }
            }
        }

        rows.push(Row::spacer());
        rows.push(Row::leaf("fonts").detail("pick the font for each wezterm lane"));

        rows
    }

    fn pane(&mut self, sel: usize, _cols: u16, rows: u16) -> Pane {
        // A run owns the pane while it exists. Showing whatever the cursor
        // happens to be over while an install scrolls past would be the wrong
        // thing on both counts -- you cannot read the install, and the page you
        // are "looking at" is one you did not ask for.
        if let Some(r) = self.run.as_ref() {
            return Pane {
                image: None,
                lines: r.tail(rows as usize),
            };
        }
        let mut lines: Vec<String> = Vec::new();
        match self.at(sel) {
            At::Target(i) => {
                let t = &self.targets[i];
                lines.push(format!("make {}", t.name));
                lines.push(String::new());
                lines.push(t.summary.clone());
                if ESCALATES.contains(&t.name.as_str()) {
                    lines.push(String::new());
                    lines.push("Runs on the real terminal rather than in this".into());
                    lines.push("pane: it can need sudo, and a password prompt".into());
                    lines.push("cannot be shown in here.".into());
                }
                if !t.page.is_empty() {
                    lines.push(String::new());
                    lines.extend(t.page.iter().cloned());
                }
            }
            At::Section(i) => {
                let s = &self.sections[i];
                lines.push(format!("[{}]", s.name));
                lines.push(String::new());
                lines.push(format!(
                    "{} link(s), {} tool(s) declared.",
                    s.links, s.tools
                ));
                lines.push(String::new());
                lines.push("A section is an argument, not a target: `make nvim`".into());
                lines.push("is a no-op stub rule. Open it for the three verbs".into());
                lines.push("that do take it.".into());
                lines.push(String::new());
                lines.push("To skip this section on THIS machine only, comment".into());
                lines.push("it out in ~/.config/dotfiles/sections — never in".into());
                lines.push("deps.conf, which every machine reads.".into());
            }
            At::SectionVerb(i, v) => {
                let name = &self.sections[i].name;
                lines.push(format!("make {v} {name}"));
                lines.push(String::new());
                lines.push(match v {
                    "install" => "Link this section's config and install its tools.".into(),
                    "link" => "Symlink its config only — no sudo, no network.".into(),
                    _ => "Report whether its tools are present.".into(),
                });
            }
            At::Fonts => {
                lines.push("fonts".into());
                lines.push(String::new());
                lines.push("The four wezterm lanes — shell, nvim.ui, nvim.editor".into());
                lines.push("and claude — and which family each is set to.".into());
                lines.push(String::new());
                lines.push("This is `font`'s own picker, not a copy of it: the".into());
                lines.push("same screen its binary runs, pushed here.".into());
            }
            At::TargetsHeader => {
                lines.push("Every target `make help` lists, with the comment".into());
                lines.push("block above its rule as the page.".into());
                lines.push(String::new());
                lines.push("enter runs one on the real terminal, so sudo can".into());
                lines.push("prompt and the output is exactly what you would".into());
                lines.push("have seen typing it.".into());
            }
            At::SectionsHeader => {
                lines.push("Every section declared in deps.conf.".into());
                lines.push(String::new());
                lines.push("Absent from ~/.config/dotfiles/sections means every".into());
                lines.push("section, so that file only ever narrows this list.".into());
            }
            At::Nothing => {}
        }
        if !self.status.is_empty() {
            lines.push(String::new());
            lines.push(self.status.clone());
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        self.status.clear();
        match (action, self.at(sel)) {
            (Action::Activate, At::Target(i)) => {
                let name = self.targets[i].name.clone();
                self.make(&[&name], &name)
            }
            // The VERB decides, not the section: `make install nvim` reaches
            // pkg_install exactly as `make install` does.
            (Action::Activate, At::SectionVerb(i, v)) => {
                let name = self.sections[i].name.clone();
                self.make(&[v, &name], v)
            }
            (Action::Activate | Action::Open, At::Section(i)) => {
                self.open = if self.open == Some(i) { None } else { Some(i) };
                Flow::Dirty
            }
            (Action::Close, At::SectionVerb(i, _)) => {
                self.open = (self.open != Some(i)).then_some(i).and(None);
                Flow::Dirty
            }
            (Action::Activate, At::Fonts) => Flow::Push(Box::new(font::FontScreen::new())),
            // One key, two states, both named in the footer: stop it if it is
            // going, clear it if it is not.
            (Action::Key('x'), _) => match self.run.as_mut() {
                Some(r) if r.running() => {
                    r.stop();
                    Flow::Dirty
                }
                Some(_) => {
                    self.run = None;
                    Flow::Dirty
                }
                None => Flow::Continue,
            },
            _ => Flow::Continue,
        }
    }

    fn tick(&mut self) -> Tick {
        match self.run.as_mut() {
            Some(r) => r.tick(),
            None => Tick::Idle,
        }
    }

    fn footer(&self) -> String {
        if let Some(r) = self.run.as_ref() {
            return if r.running() {
                "x stop".into()
            } else {
                "x clear".into()
            };
        }
        match self.at(self.focus_sel) {
            // No `q` hint here: app appends it from the stack depth, because
            // only the stack knows whether q quits or goes back one screen.
            At::Target(_) | At::SectionVerb(..) => "enter run".into(),
            At::Section(_) => "enter open".into(),
            At::Fonts => "enter the font picker".into(),
            _ => "j/k move · h/l close/open · enter run".into(),
        }
    }
}
