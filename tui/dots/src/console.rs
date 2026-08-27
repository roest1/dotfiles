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
//!
//! Sections are also the one place this screen WRITES. Space toggles whether
//! this machine sweeps a section, into `~/.config/dotfiles/sections` -- see
//! `sections.rs` for why absent and everything-ticked are different states and
//! why the console goes out of its way to say which one is in force.
//!
//! Toggling is separate from Enter on purpose. Enter on a section opens it,
//! because the three verbs underneath are the thing you came for far more often
//! than the toggle is, and a key that reconfigures the machine should not be the
//! same key that expands a tree.

use std::path::PathBuf;

use reticle::{nav::Action, Flow, Pane, Row, Screen, Tick};

use crate::repo::{self, Section, Target};
use crate::run::Run;
use crate::sections::{self as local, Local, Mode};

pub struct Console {
    root: PathBuf,
    targets: Vec<Target>,
    sections: Vec<Section>,
    /// This machine's answer, and where it is written. Held rather than re-read
    /// per frame: `rows` runs every draw, and a `read_to_string` per frame for a
    /// file only this screen changes is work in the 60fps path.
    local: Local,
    local_path: PathBuf,
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
    /// The way back to following `deps.conf`. Only present while pinned.
    ///
    /// A ROW rather than a key, per the rule in tui/CLAUDE.md, and this is the
    /// case that rule was written for: nobody discovers that the way to undo a
    /// checklist is to delete a file whose path they would have to know first.
    Follow,
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
        Self::rooted(
            repo::root().unwrap_or_else(|| PathBuf::from(".")),
            local::state_path(),
        )
    }

    /// Both paths injected, for the reason `repo`'s functions take a root: the
    /// tests must not read — or write — this machine's real sections file, and
    /// what they need to pin is the walk over the rows, not where the file
    /// lives.
    fn rooted(root: PathBuf, local_path: PathBuf) -> Self {
        let sections = repo::sections(&root);
        let names: Vec<String> = sections.iter().map(|s| s.name.clone()).collect();
        Self {
            targets: repo::targets(&root),
            local: local::load(&local_path, &names),
            local_path,
            sections,
            root,
            open: None,
            status: String::new(),
            run: None,
            focus_sel: 0,
        }
    }

    /// The sections `deps.conf` declares, in its order. The catalogue every
    /// question about the local file is resolved against.
    fn catalogue(&self) -> Vec<String> {
        self.sections.iter().map(|s| s.name.clone()).collect()
    }

    /// What space would do to section `i`, for the footer.
    ///
    /// Named for the RESULT rather than the action ("skip"/"sweep", not
    /// "toggle") because a footer that says `space toggle` makes you press it to
    /// find out which way it goes, on the one key here that rewrites a file.
    fn switch_verb(&self, i: usize) -> &'static str {
        if self.local.is_on(&self.sections[i].name) {
            "skip it here"
        } else {
            "sweep it here"
        }
    }

    /// The header's second column, and the only place the two modes are named
    /// where you cannot miss them.
    ///
    /// "following deps.conf" rather than "all": they are the same list today
    /// and different lists the next time the catalogue grows, and a header that
    /// said "all" would make the row that undoes it look like a no-op.
    fn mode_line(&self) -> String {
        match self.local.mode {
            Mode::Following => "following deps.conf — every section, now and later".into(),
            Mode::Pinned => format!(
                "{} of {} on this machine",
                self.local.on.len(),
                self.sections.len()
            ),
        }
    }

    /// Write the file, then RE-READ it rather than assuming the write took.
    ///
    /// The re-read is the point: it means the rows show what `make` will
    /// actually see, so a read-only config dir or a path that is not writable
    /// shows up as the toggle not moving, with the reason in the status line —
    /// instead of a ticked box over a file that never changed.
    fn set(&mut self, on: Vec<String>) -> Flow {
        let names = self.catalogue();
        if let Err(e) = local::write(&self.local_path, &names, &on) {
            self.status = format!("could not write {}: {e}", self.local_path.display());
        }
        self.local = local::load(&self.local_path, &names);
        if self.local.is_empty() {
            self.status =
                "every section is off — `make install` will refuse until one is back on".into();
        }
        Flow::Dirty
    }

    /// Flip one section, materialising the file on the first toggle.
    ///
    /// From `Following` that first press writes every section and comments the
    /// one being turned off, which is a bigger change than it looks — the
    /// machine stops tracking the catalogue. The pane says so before you press
    /// it and the header says so after.
    fn toggle(&mut self, i: usize) -> Flow {
        let name = self.sections[i].name.clone();
        let mut on: Vec<String> = self
            .catalogue()
            .into_iter()
            .filter(|n| self.local.is_on(n))
            .collect();
        match on.iter().position(|n| *n == name) {
            Some(p) => {
                on.remove(p);
            }
            None => on.push(name),
        }
        self.set(on)
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
        // Only while pinned, which is also the only time it would do anything.
        if self.local.mode == Mode::Pinned {
            if sel == i {
                return At::Follow;
            }
            i += 1;
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
        rows.push(header.detail(self.mode_line()));
        for (i, s) in self.sections.iter().enumerate() {
            let mut r = Row::leaf(&s.name);
            r.depth = 0;
            r.group = true;
            r.expanded = self.open == Some(i);
            let mut r = r.detail(format!(
                "{} · {}",
                plural(s.links, "link"),
                plural(s.tools, "tool")
            ));
            // Only the OFF rows are badged. A badge on every row would put
            // eight `on`s down the column to mark the unremarkable, and the
            // header already says how many are on; the exception is the thing
            // worth finding when you scan this list.
            if !self.local.is_on(&s.name) {
                r = r.badged("off", 210);
            }
            rows.push(r);
            if self.open == Some(i) {
                for v in VERBS {
                    let mut r = Row::leaf(format!("make {v} {}", s.name));
                    r.depth = 1;
                    rows.push(r);
                }
            }
        }
        if self.local.mode == Mode::Pinned {
            rows.push(
                Row::leaf("follow deps.conf")
                    .detail("drop this machine's list, take the catalogue"),
            );
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
                let on = self.local.is_on(&s.name);
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
                if on {
                    lines.push("space skips it on THIS machine. It stays in".into());
                    lines.push("deps.conf, which every machine reads — the skip is".into());
                    lines.push("written outside the work tree, so it never becomes".into());
                    lines.push("a diff you carry or commit by accident.".into());
                } else {
                    lines.push("Skipped on THIS machine. space puts it back.".into());
                    lines.push(String::new());
                    lines.push("Already-linked config is NOT removed by switching".into());
                    lines.push("this off — it only drops out of the next sweep.".into());
                    lines.push("`make prune` is what removes links.".into());
                }
                lines.push(String::new());
                lines.push(format!(
                    "Either way `make install {}` still installs",
                    s.name
                ));
                lines.push("it: naming a section explicitly wins, which is what".into());
                lines.push("makes this a preference and not a wall.".into());
                if self.local.mode == Mode::Following {
                    lines.push(String::new());
                    lines.push("Nothing is written yet: this machine follows".into());
                    lines.push("deps.conf. The first toggle writes the file, and".into());
                    lines.push("from then on a section added upstream arrives OFF.".into());
                }
            }
            At::Follow => {
                lines.push("follow deps.conf".into());
                lines.push(String::new());
                lines.push(format!("Deletes {}.", self.local_path.display()));
                lines.push(String::new());
                lines.push("Not the same as switching everything on, which is the".into());
                lines.push("whole reason this is a row. With the file present,".into());
                lines.push("this machine sweeps exactly the sections named in it,".into());
                lines.push("so a section added to deps.conf later arrives OFF and".into());
                lines.push("stays off until someone notices. Without it, every".into());
                lines.push("section is in — the ones declared today and the ones".into());
                lines.push("declared next year.".into());
                lines.push(String::new());
                lines.push("Nothing installed is touched; this only changes what".into());
                lines.push("the next sweep covers.".into());
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
                lines.push("Every section declared in deps.conf, and whether".into());
                lines.push("this machine sweeps it.".into());
                lines.push(String::new());
                match self.local.mode {
                    Mode::Following => {
                        lines.push("No file at".into());
                        lines.push(format!("  {}", self.local_path.display()));
                        lines.push("so every section is in — the ones declared".into());
                        lines.push("today and the ones declared next year.".into());
                        lines.push(String::new());
                        lines.push("space on a section writes that file and turns".into());
                        lines.push("the section off. Note what else that does: from".into());
                        lines.push("then on this machine sweeps exactly the names in".into());
                        lines.push("the file, so a section added to deps.conf later".into());
                        lines.push("arrives OFF rather than on.".into());
                    }
                    Mode::Pinned => {
                        lines.push(format!(
                            "{} of {} sections are on, from",
                            self.local.on.len(),
                            self.sections.len()
                        ));
                        lines.push(format!("  {}", self.local_path.display()));
                        lines.push(String::new());
                        lines.push("Because that file exists, this machine sweeps".into());
                        lines.push("exactly the names in it — a section added to".into());
                        lines.push("deps.conf later will arrive OFF. The `follow".into());
                        lines.push("deps.conf` row below undoes that.".into());
                    }
                }
                if !self.local.unknown.is_empty() {
                    lines.push(String::new());
                    lines.push("Named in that file but not declared in deps.conf:".into());
                    for u in &self.local.unknown {
                        lines.push(format!("  {u}"));
                    }
                    lines.push("`make` warns about these on stderr and carries on,".into());
                    lines.push("which nobody reads mid-sweep. Usually a typo, or a".into());
                    lines.push("section this clone has not pulled yet.".into());
                }
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
            // Space, not Enter: Enter on a section opens it, and the key that
            // reconfigures the machine should not be the key that expands a
            // tree. On a verb row it toggles the section that verb belongs to,
            // so an open section is not a dead zone for its own switch.
            (Action::Key(' '), At::Section(i)) | (Action::Key(' '), At::SectionVerb(i, _)) => {
                self.toggle(i)
            }
            (Action::Activate, At::Follow) => {
                let names = self.catalogue();
                if let Err(e) = local::follow(&self.local_path) {
                    self.status = format!("could not remove {}: {e}", self.local_path.display());
                }
                self.local = local::load(&self.local_path, &names);
                // The row it was sitting on is gone now, and `app` clamps the
                // cursor to the row count, so this lands on `fonts` rather than
                // off the end.
                Flow::Dirty
            }
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
            At::Target(_) => "enter run".into(),
            At::SectionVerb(i, _) => {
                format!("enter run · space {}", self.switch_verb(i))
            }
            At::Section(i) => format!("enter open · space {}", self.switch_verb(i)),
            At::Follow => "enter follow deps.conf again".into(),
            At::Fonts => "enter the font picker".into(),
            _ => "j/k move · h/l close/open · enter run".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Against the REAL repo, like `repo`'s tests, but with the machine-local
    /// file redirected into a scratch dir — the one thing here that must not
    /// touch the machine running the suite.
    fn console(name: &str, write_local: Option<&[&str]>) -> Console {
        let root = repo::root().expect("tests run inside the repo");
        let dir = std::env::temp_dir().join(format!("dots-console-{name}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join("sections");
        if let Some(on) = write_local {
            let names = repo::sections(&root)
                .iter()
                .map(|s| s.name.clone())
                .collect::<Vec<_>>();
            let on: Vec<String> = on.iter().map(|s| s.to_string()).collect();
            local::write(&path, &names, &on).expect("seed");
        }
        Console::rooted(root, path)
    }

    /// The `At` enum exists because `pane`, `on_action` and `footer` used to
    /// each re-derive what the cursor was on and disagree. Both modes now add
    /// or drop a row, so the walk and the row list can drift apart in a way no
    /// individual assertion about either would catch: every selectable index
    /// must resolve to the row actually drawn at it.
    fn walk_agrees(c: &mut Console) {
        let rows = c.rows();
        for (i, row) in rows.iter().enumerate() {
            if !row.selectable {
                assert!(
                    matches!(c.at(i), At::Nothing),
                    "row {i} is a spacer but the walk resolves it to something"
                );
                continue;
            }
            let label = &row.label;
            match c.at(i) {
                At::TargetsHeader => assert_eq!(label, "targets"),
                At::Target(t) => assert_eq!(label, &c.targets[t].name),
                At::SectionsHeader => assert_eq!(label, "sections"),
                At::Section(s) => assert_eq!(label, &c.sections[s].name),
                At::SectionVerb(s, v) => {
                    assert_eq!(label, &format!("make {v} {}", c.sections[s].name))
                }
                At::Follow => assert_eq!(label, "follow deps.conf"),
                At::Fonts => assert_eq!(label, "fonts"),
                At::Nothing => panic!("selectable row {i} ({label}) resolves to nothing"),
            }
        }
    }

    #[test]
    fn the_walk_matches_the_rows_while_following() {
        let mut c = console("following", None);
        assert_eq!(c.local.mode, Mode::Following);
        walk_agrees(&mut c);
    }

    /// The pinned tree has one MORE row than the following one, and it sits
    /// between the last section and the spacer — the position most likely to be
    /// got wrong, since everything after it shifts.
    #[test]
    fn the_walk_matches_the_rows_while_pinned() {
        let mut c = console("pinned", Some(&["bash"]));
        assert_eq!(c.local.mode, Mode::Pinned);
        walk_agrees(&mut c);
    }

    /// Opening a section injects three rows mid-list, and it composes with the
    /// follow row rather than replacing the question.
    #[test]
    fn the_walk_matches_the_rows_with_a_section_open() {
        let mut c = console("open", Some(&["bash"]));
        c.open = Some(1);
        walk_agrees(&mut c);
    }

    /// The first toggle from `Following` is the one that changes the CONTRACT,
    /// not just the section: it materialises the file, so the machine stops
    /// tracking the catalogue. Everything else here is a consequence of that.
    #[test]
    fn the_first_toggle_materialises_the_file_and_pins_the_machine() {
        let mut c = console("first-toggle", None);
        assert_eq!(c.local.mode, Mode::Following);
        assert!(!c.local_path.exists());

        let target = c.sections[0].name.clone();
        c.toggle(0);

        assert_eq!(c.local.mode, Mode::Pinned);
        assert!(c.local_path.exists());
        assert!(!c.local.is_on(&target));
        // Every OTHER section survived the materialisation. Writing only the
        // survivors would be the same file; writing only the toggled one would
        // silently disable the machine.
        for s in &c.sections[1..] {
            assert!(c.local.is_on(&s.name), "{} lost", s.name);
        }
    }

    #[test]
    fn toggling_back_leaves_the_machine_pinned_not_following() {
        let mut c = console("toggle-back", None);
        c.toggle(0);
        c.toggle(0);
        assert!(c.local.is_on(&c.sections[0].name.clone()));
        // Still pinned: a file that exists is a different contract from no
        // file, and undoing a toggle is not a request to undo that.
        assert_eq!(c.local.mode, Mode::Pinned);
    }

    #[test]
    fn the_follow_row_is_the_way_back_and_only_appears_when_it_would_do_something() {
        let mut c = console("follow-row", None);
        assert!(
            !c.rows().iter().any(|r| r.label == "follow deps.conf"),
            "nothing to follow back to while already following"
        );

        c.toggle(0);
        let sel = c
            .rows()
            .iter()
            .position(|r| r.label == "follow deps.conf")
            .expect("the row appears once pinned");
        c.on_action(Action::Activate, sel);

        assert_eq!(c.local.mode, Mode::Following);
        assert!(!c.local_path.exists());
        assert!(!c.rows().iter().any(|r| r.label == "follow deps.conf"));
    }

    /// Space on a verb row toggles the section it belongs to. An open section
    /// would otherwise be a dead zone for its own switch — three rows where the
    /// key you just used stops working.
    #[test]
    fn space_works_on_a_verb_row_too() {
        let mut c = console("verb-space", Some(&["bash"]));
        c.open = Some(0);
        let rows = c.rows();
        let sel = rows
            .iter()
            .position(|r| r.label.starts_with("make link "))
            .expect("an open section shows its verbs");
        let name = c.sections[0].name.clone();
        let before = c.local.is_on(&name);
        c.on_action(Action::Key(' '), sel);
        assert_ne!(before, c.local.is_on(&name));
    }

    /// Only the off rows are badged, so the badge column stays empty on a
    /// machine that has not narrowed anything.
    #[test]
    fn only_the_skipped_sections_are_badged() {
        let mut c = console("badges", None);
        assert!(c.rows().iter().all(|r| r.badge.is_none()));

        c.toggle(0);
        let name = c.sections[0].name.clone();
        let rows = c.rows();
        let row = rows.iter().find(|r| r.label == name).expect("the section");
        assert_eq!(row.badge.as_ref().map(|(t, _)| t.as_str()), Some("off"));
        assert_eq!(rows.iter().filter(|r| r.badge.is_some()).count(), 1);
    }

    /// The footer names the RESULT of pressing space, so you do not have to
    /// press the file-writing key to find out which way it goes.
    #[test]
    fn the_footer_says_which_way_space_goes() {
        let mut c = console("footer", None);
        let sel = c
            .rows()
            .iter()
            .position(|r| r.label == c.sections[0].name)
            .expect("first section");
        c.focus(sel);
        assert!(c.footer().contains("skip it here"));

        c.toggle(0);
        c.focus(sel);
        assert!(c.footer().contains("sweep it here"));
    }
}
