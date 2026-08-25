//! `~/.config/dotfiles/sections` — which sections THIS machine sweeps.
//!
//! The first thing in this repo that `dots` OWNS rather than reads. Everything
//! else the console shows is derived from the tree — targets from the Makefile,
//! sections from `deps.conf` — and is the same on every machine by definition.
//! This file is the opposite: it exists to differ per machine, which is why it
//! lives in `$XDG_CONFIG_HOME` and never in the work tree. Commenting a line in
//! `deps.conf` would be a tracked edit, so a machine-local preference would
//! become a diff you carry forever or commit by accident.
//!
//! `font`'s `lanes.rs` is the same shape for the same reason, and this follows
//! it deliberately: read-with-defaults, write-the-whole-file, no format anyone
//! has to learn.
//!
//! ## Absent is not the same as everything-on
//!
//! This is the distinction the console exists to make visible, because it is
//! invisible in `$EDITOR` and it changes what a `git pull` does to you.
//!
//! `manifest_enabled` in `lib/manifest.sh` prints the names it FINDS in the
//! file. So a machine with no file gets whatever `deps.conf` declares, now and
//! forever — a section added upstream arrives switched ON. A machine with a
//! file gets exactly the names written in it, so the same new section arrives
//! switched OFF, silently, and stays that way until someone notices.
//!
//! Neither is wrong. They are two different answers to "what should happen when
//! the catalogue grows", and a checklist that renders them identically — nine
//! ticked boxes either way — is lying about the more consequential half. Hence
//! [`Mode`], hence the header row saying which one is in force, and hence
//! [`follow`] being reachable as a row rather than only by knowing to `rm` a
//! path you would first have to know the name of.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Which of the two contracts is in force. See the module header — the
/// difference only shows up later, when `deps.conf` grows a section.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// No file. Every section in `deps.conf`, including ones added after today.
    Following,
    /// A file exists. Exactly the names in it; a section added upstream arrives
    /// off.
    Pinned,
}

/// This machine's answer, resolved against the catalogue it was read with.
pub struct Local {
    pub mode: Mode,
    /// Declared sections this machine has switched on, in `deps.conf` order.
    pub on: Vec<String>,
    /// Names in the file that `deps.conf` does not declare. `manifest_enabled`
    /// warns about these on stderr and carries on, which is the right call for
    /// an install and the wrong one for a console: a warning printed during a
    /// sweep you were not watching is a warning nobody read. Surfaced as state
    /// so the pane can show it.
    pub unknown: Vec<String>,
}

impl Local {
    pub fn is_on(&self, name: &str) -> bool {
        match self.mode {
            Mode::Following => true,
            Mode::Pinned => self.on.iter().any(|n| n == name),
        }
    }

    /// True when a written file has every section commented out.
    ///
    /// `manifest_scope_into` refuses this rather than falling through to "no
    /// arguments means all", so it fails safe and says what to do. Worth
    /// showing anyway: the refusal happens at `make install` time, which may be
    /// days after the toggle that caused it.
    pub fn is_empty(&self) -> bool {
        self.mode == Mode::Pinned && self.on.is_empty()
    }
}

/// Honours `DOTFILES_SECTIONS_FILE` first, exactly as `lib/manifest.sh` does.
///
/// Not a nicety — the override is how the shell side is tested, and a console
/// that ignored it would edit the real file out from under a machine that had
/// deliberately pointed the sweep somewhere else.
pub fn state_path() -> PathBuf {
    fn var(name: &str) -> Option<String> {
        std::env::var(name).ok().filter(|s| !s.is_empty())
    }
    resolve_path(
        var("DOTFILES_SECTIONS_FILE").as_deref(),
        var("XDG_CONFIG_HOME").as_deref(),
        &std::env::var("HOME").unwrap_or_default(),
    )
}

/// The precedence, split out from reading the environment so it can be tested.
///
/// Same reason `theme::parse_ps1` is split from the file read in `font`: the
/// alternative is a test that sets a process-global env var while other tests
/// are threads in the same process.
fn resolve_path(over: Option<&str>, xdg: Option<&str>, home: &str) -> PathBuf {
    if let Some(p) = over {
        return PathBuf::from(p);
    }
    match xdg {
        Some(x) => PathBuf::from(x),
        None => PathBuf::from(home).join(".config"),
    }
    .join("dotfiles")
    .join("sections")
}

/// Read the file at `path` and resolve it against `catalogue`.
///
/// Takes the path rather than calling [`state_path`] for the reason `repo`'s
/// functions take a root: it makes the thing testable without an env var, and
/// env vars are process-global while tests are threads.
///
/// The line parse is `lib/manifest.sh`'s, deliberately down to the order of
/// operations: strip from `#`, trim, skip empty. Anything else is a second
/// implementation of a format whose first implementation decides whether your
/// machine installs nvim.
pub fn load(path: &Path, catalogue: &[String]) -> Local {
    let Ok(text) = fs::read_to_string(path) else {
        return Local {
            mode: Mode::Following,
            on: catalogue.to_vec(),
            unknown: Vec::new(),
        };
    };
    let mut named: Vec<String> = Vec::new();
    let mut unknown: Vec<String> = Vec::new();
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if catalogue.iter().any(|c| c == line) {
            if !named.iter().any(|n| n == line) {
                named.push(line.to_string());
            }
        } else if !unknown.iter().any(|n| n == line) {
            unknown.push(line.to_string());
        }
    }
    // Emitted in CATALOGUE order, not file order. The shell reads the file in
    // its own order and that order is the install order, so a hand-edited file
    // could sweep [tui] before [bash]; the console has no business rendering
    // that as the section list's order, and `write` normalises it away the
    // first time anything is toggled.
    let on = catalogue
        .iter()
        .filter(|c| named.iter().any(|n| n == *c))
        .cloned()
        .collect();
    Local {
        mode: Mode::Pinned,
        on,
        unknown,
    }
}

/// Write the whole file: every declared section, with the off ones commented.
///
/// Every section is named on every write, present-but-commented rather than
/// absent, because that is what makes the file legible as a checklist when you
/// do open it in an editor — and because "which sections exist" is then a
/// question the file answers on a machine whose clone is a `git pull` behind.
///
/// Truncate-and-write rather than write-temp-and-rename, matching `lanes.rs`.
/// The reason there was wezterm's inode watch; here it is simply that nothing
/// reads this file concurrently — `make` reads it once at startup — so the
/// atomicity would buy nothing and the rename would drop the mode of a file the
/// user may have made their own.
pub fn write(path: &Path, catalogue: &[String], on: &[String]) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut body = String::from(
        "# Which sections `make` sweeps on THIS machine. Written by `dots`.\n\
         # Machine-local: not in git, not linked, not in deps.conf — same\n\
         # footing as ~/.bash_local.\n\
         #\n\
         # A commented line is a section this machine skips. Naming one\n\
         # explicitly still wins: `make install claude` installs it whether or\n\
         # not it is ticked here, which is what makes this a preference rather\n\
         # than a wall.\n\
         #\n\
         # DELETE THIS FILE to go back to following deps.conf, which is not the\n\
         # same as ticking everything: with the file present, a section added\n\
         # to deps.conf later arrives switched OFF, because this file lists the\n\
         # sections it knew about. Without it, every section is always in.\n",
    );
    for name in catalogue {
        if on.iter().any(|n| n == name) {
            body.push_str(name);
        } else {
            body.push('#');
            body.push_str(name);
        }
        body.push('\n');
    }
    fs::write(path, body)
}

/// Go back to following the catalogue, by removing the file.
///
/// A missing file is the success case, not an error — that is the state being
/// asked for, and reporting `NotFound` for it would make the row fail on a
/// second press for having already worked.
pub fn follow(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalogue() -> Vec<String> {
        ["bash", "nvim", "wezterm", "tui", "claude"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    /// A named directory per test rather than a random one: tests are threads
    /// in one process, so a shared path would race, and a fixed name per test
    /// is reproducible where a random one is not.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("dots-sections-{name}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("scratch dir");
        dir.join("sections")
    }

    #[test]
    fn absent_means_every_section() {
        let path = scratch("absent");
        let local = load(&path, &catalogue());
        assert_eq!(local.mode, Mode::Following);
        assert_eq!(local.on, catalogue());
        assert!(local.is_on("tui"));
    }

    /// The distinction the console exists to show: with a file present, a
    /// section that appears in deps.conf LATER is off. Without one it is on.
    /// If this ever stops being true the header row is lying and `follow`
    /// stops being worth a row.
    #[test]
    fn a_new_section_arrives_off_when_pinned_and_on_when_following() {
        let path = scratch("newcomer");
        write(&path, &catalogue(), &catalogue()).expect("write");

        let mut grown = catalogue();
        grown.push("podman".to_string());

        let pinned = load(&path, &grown);
        assert!(!pinned.is_on("podman"), "pinned machines must not gain it");
        assert!(pinned.is_on("bash"));

        follow(&path).expect("follow");
        let following = load(&path, &grown);
        assert_eq!(following.mode, Mode::Following);
        assert!(following.is_on("podman"), "following machines must gain it");
    }

    #[test]
    fn a_commented_section_is_off_and_survives_a_round_trip() {
        let path = scratch("roundtrip");
        let on: Vec<String> = catalogue().into_iter().filter(|n| n != "tui").collect();
        write(&path, &catalogue(), &on).expect("write");

        let local = load(&path, &catalogue());
        assert_eq!(local.mode, Mode::Pinned);
        assert!(!local.is_on("tui"));
        assert!(local.is_on("bash") && local.is_on("claude"));
        assert_eq!(local.on, on);
    }

    /// Every section is named on every write, off ones commented — that is what
    /// makes the file readable as a checklist rather than as a list of survivors.
    #[test]
    fn the_file_names_every_section_even_the_off_ones() {
        let path = scratch("names-all");
        let on: Vec<String> = catalogue().into_iter().filter(|n| n != "nvim").collect();
        write(&path, &catalogue(), &on).expect("write");

        let text = fs::read_to_string(&path).expect("read");
        for name in catalogue() {
            assert!(
                text.lines()
                    .any(|l| l.trim_start_matches('#').trim() == name),
                "{name} is missing from the written file"
            );
        }
        assert!(text.lines().any(|l| l.trim() == "#nvim"));
        assert!(
            text.contains("DELETE THIS FILE"),
            "the way back must be in it"
        );
    }

    /// Hand-edited files are the normal case for this path — it predates the
    /// console — so the parse has to match the shell's, comments and all.
    #[test]
    fn it_parses_a_hand_written_file_the_way_the_shell_does() {
        let path = scratch("handwritten");
        fs::write(
            &path,
            "# a comment\n\n  bash  \nnvim # trailing note\n#wezterm\n\tclaude\nbash\n",
        )
        .expect("write");

        let local = load(&path, &catalogue());
        assert_eq!(local.on, vec!["bash", "nvim", "claude"]);
        assert!(local.unknown.is_empty());
    }

    /// `manifest_enabled` warns on stderr and carries on. During an unattended
    /// sweep nobody reads that, so the console keeps it as state instead.
    #[test]
    fn a_name_deps_conf_does_not_declare_is_reported_not_dropped() {
        let path = scratch("unknown");
        fs::write(&path, "bash\nnvimm\n").expect("write");

        let local = load(&path, &catalogue());
        assert_eq!(local.on, vec!["bash"]);
        assert_eq!(local.unknown, vec!["nvimm"]);
    }

    /// Allowed, not prevented: `manifest_scope_into` refuses an all-off file and
    /// says how to fix it, so the failure is safe. But it happens at install
    /// time, which can be long after the toggle, so the console flags it now.
    #[test]
    fn everything_off_is_writable_and_flagged() {
        let path = scratch("empty");
        write(&path, &catalogue(), &[]).expect("write");

        let local = load(&path, &catalogue());
        assert!(local.is_empty());
        assert!(!local.is_on("bash"));
    }

    #[test]
    fn following_is_idempotent_and_not_an_error_when_already_absent() {
        let path = scratch("idempotent");
        write(&path, &catalogue(), &catalogue()).expect("write");
        follow(&path).expect("first");
        follow(&path).expect("second must not fail for having worked");
        assert_eq!(load(&path, &catalogue()).mode, Mode::Following);
    }

    /// `DOTFILES_SECTIONS_FILE` is how the shell side is tested, so a console
    /// that ignored it would edit the real file out from under a run that had
    /// deliberately pointed the sweep somewhere else.
    #[test]
    fn the_override_wins_and_xdg_wins_over_home() {
        assert_eq!(
            resolve_path(Some("/elsewhere/sections"), Some("/xdg"), "/home/r"),
            PathBuf::from("/elsewhere/sections")
        );
        assert_eq!(
            resolve_path(None, Some("/xdg"), "/home/r"),
            PathBuf::from("/xdg/dotfiles/sections")
        );
        assert_eq!(
            resolve_path(None, None, "/home/r"),
            PathBuf::from("/home/r/.config/dotfiles/sections")
        );
    }
}
