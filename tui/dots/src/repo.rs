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
