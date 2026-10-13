//! What the repo already says about itself.
//!
//! Nothing here is authored twice. The targets and their one-line summaries
//! come from the `##` markers `make help` already renders; the long form of a
//! target is the comment block sitting immediately above its rule; the sections
//! come from `deps.conf`, which is the manifest and therefore the only place a
//! section is ever named.
//!
//! That has one consequence worth saying out loud, because it changes how you
//! write: **a comment above a rule in the Makefile is user-facing
//! documentation now.** Write it for someone deciding whether to run the thing,
//! not only for whoever maintains it.
//!
//! A blank line ends a block. That is what keeps a file-header banner from
//! being mistaken for the first target's page, and it is how a target opts out
//! of having a long form at all.

use std::fs;
use std::path::{Path, PathBuf};

pub struct Target {
    pub name: String,
    /// The `##` text `make help` shows.
    pub summary: String,
    /// The comment block above the rule, `#` markers stripped. May be empty.
    pub page: Vec<String>,
}

pub struct Section {
    pub name: String,
    pub links: usize,
    pub tools: usize,
}

/// Walk up for the repo root, so `dots` works from anywhere inside it.
///
/// Falls back to `$DOTFILES_DIR` and then `~/dotfiles`, in that order, because
/// the console is also a thing you run from `$HOME` when something has gone
/// wrong and you are not standing in the repo.
pub fn root() -> Option<PathBuf> {
    if let Ok(d) = std::env::var("DOTFILES_DIR") {
        let p = PathBuf::from(d);
        if p.join("deps.conf").is_file() {
            return Some(p);
        }
    }
    let mut here = std::env::current_dir().ok()?;
    loop {
        if here.join("deps.conf").is_file() && here.join("Makefile").is_file() {
            return Some(here);
        }
        if !here.pop() {
            break;
        }
    }
    let home = PathBuf::from(std::env::var("HOME").ok()?).join("dotfiles");
    home.join("deps.conf").is_file().then_some(home)
}

pub fn targets(root: &Path) -> Vec<Target> {
    let Ok(text) = fs::read_to_string(root.join("Makefile")) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut block: Vec<String> = Vec::new();

    for line in text.lines() {
        let trimmed = line.trim_end();

        if let Some(rest) = trimmed.strip_prefix('#') {
            // `#####` rules and `# ─── headings ───` are decoration, not prose.
            let body = rest.trim_start_matches('#').trim();
            if body.chars().all(|c| c == '─' || c == '-' || c == '=') {
                block.push(String::new());
            } else {
                block.push(body.to_string());
            }
            continue;
        }

        if trimmed.is_empty() {
            block.clear();
            continue;
        }

        // `name: ... ## summary` — the same shape make help's awk matches.
        if let Some((head, summary)) = trimmed.split_once("##") {
            if let Some((name, _)) = head.split_once(':') {
                let name = name.trim();
                let ok = !name.is_empty()
                    && name
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c == '-' || c == '_');
                if ok {
                    // Leading and trailing blanks are an artefact of stripping
                    // rule characters; the interior ones are real paragraphs.
                    while block.first().is_some_and(|l| l.is_empty()) {
                        block.remove(0);
                    }
                    while block.last().is_some_and(|l| l.is_empty()) {
                        block.pop();
                    }
                    out.push(Target {
                        name: name.to_string(),
                        summary: summary.trim().to_string(),
                        page: std::mem::take(&mut block),
                    });
                    continue;
                }
            }
        }
        block.clear();
    }
    out
}

/// Sections, with a count of what each one carries.
///
/// The counts are the point rather than decoration: they are what makes the
/// tree honest about a section being large or nearly empty before you open it.
pub fn sections(root: &Path) -> Vec<Section> {
    let Ok(text) = fs::read_to_string(root.join("deps.conf")) else {
        return Vec::new();
    };
    let mut out: Vec<Section> = Vec::new();
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if let Some(name) = line
            .strip_prefix('[')
            .and_then(|l| l.strip_suffix(']'))
            .filter(|n| !n.is_empty())
        {
            out.push(Section {
                name: name.to_string(),
                links: 0,
                tools: 0,
            });
            continue;
        }
        if let Some(last) = out.last_mut() {
            let mut w = line.split_whitespace();
            match w.next() {
                Some("link") => last.links += 1,
                Some("tool") => last.tools += 1,
                _ => {}
            }
        }
    }
    out
}

/// Every target that can reach `sudo`, derived from the tree.
///
/// This exists so `console::ESCALATES` cannot rot. A hardcoded list is right --
/// the mapping is not fully mechanical, since `make install` reaches sudo three
/// files away, through install.sh and run_tools into pkg_install -- but a
/// hardcoded list that nothing checks is one `sudo` away from being a lie, and
/// the lie's consequence here is a password prompt fired inside a pane that
/// cannot show it.
///
/// Two halves, because the two shapes are genuinely different:
///
///   direct     a Makefile recipe containing `sudo`. Fully derivable, so it is
///              derived rather than listed.
///   indirect   a script that escalates, plus the target that reaches it. The
///              PAIRING is the hand-maintained part; that the file set has not
///              grown is what the test checks.
///
/// bootstrap.sh is excluded on purpose and not by oversight: it escalates, and
/// `dots` can never run it. It is the pre-clone entry point, and by the time
/// this binary exists the work it does is done.
pub const INDIRECT: [(&str, &str); 1] = [("lib/pkg.sh", "install")];

/// Files under the repo that invoke sudo, relative to the root.
///
/// Skips `windows/` — that is PowerShell running on the Windows host, where
/// `sudo.exe` and gsudo are a different mechanism on a different machine that
/// `dots` never invokes — and skips comments, so a note ABOUT sudo does not
/// read as a call to it.
pub fn sudo_files(root: &Path) -> Vec<String> {
    fn walk(dir: &Path, root: &Path, out: &mut Vec<String>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let path = e.path();
            let name = e.file_name();
            let name = name.to_string_lossy();
            if path.is_dir() {
                if matches!(
                    name.as_ref(),
                    ".git" | "target" | "node_modules" | "windows" | "docs"
                ) {
                    continue;
                }
                walk(&path, root, out);
                continue;
            }
            // bootstrap.sh escalates and `dots` can never run it: it is the
            // PRE-CLONE entry point, and by the time this binary exists the
            // apt/dnf it does has already happened. Excluding it is a claim
            // about reachability, not a convenience.
            if name == "bootstrap.sh" {
                continue;
            }
            let ext_ok = path.extension().is_some_and(|x| x == "sh");
            if !(ext_ok || name == "Makefile") {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            let hit = text.lines().any(|l| {
                let t = l.trim_start();
                !t.starts_with('#') && (t.contains("sudo ") || t.contains("| sudo"))
            });
            if hit {
                if let Ok(rel) = path.strip_prefix(root) {
                    out.push(rel.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(root, root, &mut out);
    out.sort();
    out
}

/// Makefile targets whose own recipe invokes sudo.
pub fn sudo_recipes(root: &Path) -> Vec<String> {
    let Ok(text) = fs::read_to_string(root.join("Makefile")) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut current: Option<String> = None;
    for line in text.lines() {
        if let Some(body) = line.strip_prefix('\t') {
            let t = body.trim_start();
            if !t.starts_with('#') && (t.contains("sudo ") || t.contains("| sudo")) {
                if let Some(name) = &current {
                    if !out.contains(name) {
                        out.push(name.clone());
                    }
                }
            }
            continue;
        }
        let head = line.trim_start();
        if head.starts_with('#') || head.is_empty() {
            continue;
        }
        // A conditional does not end a rule. GNU make lets ifeq/else/endif wrap
        // a recipe, and `make shell` does exactly that -- its sudo lives inside
        // an ifeq on UNAME. Treating the directive as a new rule attributed the
        // escalation to NO target, so the drift test reported the tree and the
        // console agreeing when they did not. That is the failure mode this
        // whole test exists to prevent, found in the test's own parser.
        if matches!(
            head.split_whitespace().next(),
            Some("ifeq" | "ifneq" | "ifdef" | "ifndef" | "else" | "endif")
        ) {
            continue;
        }
        current = line
            .split_once(':')
            .map(|(h, _)| h.trim().to_string())
            .filter(|n| {
                !n.is_empty()
                    && n.chars()
                        .all(|c| c.is_ascii_lowercase() || c == '-' || c == '_')
            });
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Against the REAL Makefile and deps.conf, deliberately. A fixture would
    // assert that the parser still parses the fixture, which is not the thing
    // that breaks -- what breaks is someone reformatting a rule and the console
    // quietly losing a page.
    fn repo() -> PathBuf {
        root().expect("tests run inside the repo")
    }

    #[test]
    fn the_escalating_set_is_still_what_the_console_believes() {
        let root = repo();

        // Half one: every file that escalates is one we have already reasoned
        // about. A NEW one fails here, and the fix is a decision -- which
        // target reaches it, and does that target still stream -- not an edit
        // to make the test pass.
        let files = sudo_files(&root);
        let known: Vec<String> = INDIRECT
            .iter()
            .map(|(f, _)| f.to_string())
            .chain(std::iter::once("Makefile".to_string()))
            .collect();
        for f in &files {
            assert!(
                known.contains(f),
                "{f} invokes sudo and nothing in dots knows it. Decide which \
                 target reaches it, then add it to repo::INDIRECT and to \
                 console::ESCALATES -- do not just widen this test."
            );
        }

        // Half two: the derived set and the console's list agree exactly.
        let mut derived: Vec<String> = sudo_recipes(&root);
        for (file, target) in INDIRECT {
            if files.iter().any(|f| f == file) && !derived.contains(&target.to_string()) {
                derived.push(target.to_string());
            }
        }
        derived.sort();
        let mut declared: Vec<String> = crate::console::ESCALATES
            .iter()
            .map(|s| s.to_string())
            .collect();
        declared.sort();
        assert_eq!(
            derived, declared,
            "console::ESCALATES and the tree disagree about which targets can \
             reach sudo. A target missing from ESCALATES would be STREAMED, \
             and its password prompt would fire into a pane that cannot show it."
        );
    }

    #[test]
    fn the_derivation_can_actually_find_something() {
        // Without this, the test above passes just as well on a repo where the
        // scanner is broken and finds nothing anywhere -- the same vacuum a
        // positive control exists to rule out.
        let root = repo();
        assert!(
            !sudo_files(&root).is_empty(),
            "the sudo scanner found nothing at all; it is broken, not the repo"
        );
        assert!(
            sudo_recipes(&root).contains(&"shell".to_string()),
            "make shell escalates via `sudo tee -a /etc/shells` and the recipe \
             scanner no longer sees it"
        );
    }

    #[test]
    fn every_documented_target_is_found() {
        let found = targets(&repo());
        let makefile = fs::read_to_string(repo().join("Makefile")).unwrap();
        let declared = makefile
            .lines()
            .filter(|l| {
                !l.starts_with('#')
                    && l.contains("##")
                    && l.split_once(':').is_some_and(|(h, _)| {
                        !h.is_empty()
                            && h.chars()
                                .all(|c| c.is_ascii_lowercase() || c == '-' || c == '_')
                    })
            })
            .count();
        assert_eq!(
            found.len(),
            declared,
            "the console shows a different set of targets than `make help` does"
        );
        assert!(found.iter().any(|t| t.name == "status"));
        assert!(found.iter().all(|t| !t.summary.is_empty()));
    }

    #[test]
    fn a_target_with_a_comment_block_gets_a_page() {
        let found = targets(&repo());
        // `prune` carries the note about mise doing the wrong half in a
        // non-interactive shell; if that stops arriving, the parser has
        // stopped reading blocks at all.
        let prune = found.iter().find(|t| t.name == "prune");
        assert!(prune.is_some(), "prune is gone from the Makefile");
        assert!(
            found.iter().any(|t| !t.page.is_empty()),
            "no target has a page -- the comment-block walk is broken"
        );
    }

    #[test]
    fn pages_never_start_or_end_blank() {
        for t in targets(&repo()) {
            if let Some(first) = t.page.first() {
                assert!(!first.is_empty(), "{} page starts blank", t.name);
                assert!(!t.page.last().unwrap().is_empty(), "{} ends blank", t.name);
            }
        }
    }

    #[test]
    fn sections_match_the_manifest() {
        let found = sections(&repo());
        let text = fs::read_to_string(repo().join("deps.conf")).unwrap();
        let declared = text
            .lines()
            .filter(|l| {
                let t = l.trim();
                t.starts_with('[') && t.ends_with(']') && !t.starts_with("[[")
            })
            .count();
        assert_eq!(found.len(), declared);
        assert!(found.iter().any(|s| s.name == "bash"));
        // A section with neither a link nor a tool would be a section that does
        // nothing, which is worth failing on rather than rendering as an empty
        // row someone then wonders about.
        assert!(
            found.iter().all(|s| s.links + s.tools > 0),
            "a section declares nothing"
        );
    }
}
