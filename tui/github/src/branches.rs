//! Branches: a full-width table, grouped Default / yours / all.
//!
//! The first screen to use `Split::Full`, and the reason that exists. A branch
//! row carries six facts -- protection, when, ahead/behind, who, the subject,
//! its checks and its PR -- and squeezing those into a 52-column sidebar beside
//! a pane with nothing to say would have meant dropping columns to make room
//! for emptiness.
//!
//! ## Nearly all of it comes from local git
//!
//! This is the shape the bash implementation found and it is worth preserving
//! exactly: `git for-each-ref` gives every remote branch's age, author, subject
//! AND its ahead/behind count against the default branch in ONE call, locally,
//! instantly, offline. The API is asked only for the things git cannot know --
//! which of them are `protected`, which have an open PR, and how their checks
//! went.
//!
//! So the table is on screen before any request is made, and the three API
//! columns fill in after. `%(ahead-behind:)` needs git >= 2.41; older gits get
//! the same table without those two numbers rather than an error.
//!
//! ## Checks come from the runs we already fetch
//!
//! A per-branch check status would be one API call per branch. But a workflow
//! run already carries its `head_branch`, so the newest run per branch IS the
//! check status -- and `Req::Runs` is a request this crate already makes. One
//! call for the whole column.
//!
//! ## The three groups, and why "all" repeats "yours"
//!
//! github.com's own branches page does this, and the design doc asks for it:
//! Default on its own, then yours, then everything. The repetition is the
//! point -- "yours" is a shortcut to the handful you are working on, and "all"
//! is the complete list you search. Both are collapsible, so the duplication
//! costs a keystroke to be rid of.

use std::collections::HashMap;
use std::process::Command;
use std::sync::Arc;

use reticle::{nav::Action, Flow, Pane, Row, Screen, Split, Tick};
use serde::Deserialize;

use crate::gh::{Fetcher, Got, Req};
use crate::menu::{Act, Item, Menu};
use crate::model::Verdict;
use crate::paint::{idx, DIM, OFF};
use crate::time;

const IN_FLIGHT: std::time::Duration = std::time::Duration::from_millis(100);

#[derive(Debug, Clone, Deserialize)]
struct ApiBranch {
    name: String,
    #[serde(default)]
    protected: bool,
}

#[derive(Debug, Clone, Deserialize)]
struct RepoInfo {
    default_branch: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct Pr {
    number: u64,
    #[serde(default)]
    draft: bool,
    head: PrHead,
}

#[derive(Debug, Clone, Deserialize)]
struct PrHead {
    #[serde(rename = "ref")]
    name: String,
}

/// What local git knows about one remote branch.
#[derive(Debug, Clone, Default)]
struct Facts {
    when: i64,
    who: String,
    /// Matched against `user.email` to decide whose branch this is. The NAME
    /// cannot do it: measured on this repo, the same person authored commits
    /// as both `Riley Oest` and `roest1` -- GitHub's web UI and a local
    /// `user.name` disagreeing -- while the email was identical on every one.
    /// Matching on the name silently filed your own branches under someone
    /// else.
    email: String,
    subject: String,
    /// `None` on git < 2.41, which has no `%(ahead-behind:)`.
    ahead_behind: Option<(u32, u32)>,
}

/// One branch, everything joined.
#[derive(Debug, Clone)]
struct Branch {
    name: String,
    protected: bool,
    facts: Option<Facts>,
}

/// What `git` told us, once, at open.
struct Local {
    default: Option<String>,
    current: Option<String>,
    /// Every branch under `refs/heads` -- the ones you have a copy of.
    ///
    /// The table is otherwise a list of REMOTE branches, which cannot answer
    /// "do I have this one" -- and that is the question in front of "should I
    /// check it out". The fzf preview said `remote only -- enter to check
    /// out`; here it is a marker, because it belongs on every row at once
    /// rather than on the one the cursor happens to be resting on.
    locals: std::collections::HashSet<String>,
    /// `user.email`, then `user.name` as a fallback for a repo configured with
    /// no email.
    me_email: Option<String>,
    me_name: Option<String>,
    facts: HashMap<String, Facts>,
}

impl Local {
    fn is_mine(&self, f: Option<&Facts>) -> bool {
        let Some(f) = f else { return false };
        if let Some(e) = self.me_email.as_deref().filter(|e| !e.is_empty()) {
            return f.email == e;
        }
        self.me_name.as_deref().is_some_and(|n| f.who == n)
    }
}

fn git(dir: &std::path::Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Read every local fact in five `git` calls.
///
/// Synchronous, at open, which is the one place this crate shells out before
/// the first frame. It is affordable because all four read files -- no network,
/// no object walk beyond the refs -- and because the alternative is a table
/// that cannot draw until the API answers. `index` makes the same trade in the
/// other direction, and the note there says why.
fn read_local(dir: &std::path::Path) -> Local {
    // `refs/remotes/origin/HEAD` is a local symref written by clone, so the
    // default branch is known offline. The API's `default_branch` is the
    // fallback, and it arrives later.
    let default = git(
        dir,
        &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
    )
    .and_then(|s| s.rsplit('/').next().map(str::to_string));
    let current = git(dir, &["symbolic-ref", "--short", "HEAD"]);
    let me_email = git(dir, &["config", "user.email"]);
    let me_name = git(dir, &["config", "user.name"]);
    // `lstrip=2` drops `refs/heads/`, so these are directly comparable with
    // the remote names below, which `lstrip=3` strips to the same shape.
    let locals: std::collections::HashSet<String> = git(
        dir,
        &[
            "for-each-ref",
            "--format",
            "%(refname:lstrip=2)",
            "refs/heads",
        ],
    )
    .unwrap_or_default()
    .lines()
    .filter(|l| !l.is_empty())
    .map(str::to_string)
    .collect();

    let base = default.clone().unwrap_or_else(|| "HEAD".into());
    let fmt = format!(
        "%(refname:lstrip=3)%09%(committerdate:unix)%09%(authorname)%09\
         %(authoremail:trim)%09%(subject)%09%(ahead-behind:refs/remotes/origin/{base})"
    );
    // The fallback drops only the two numbers. Asking for an unsupported atom
    // makes git fail the WHOLE command, so there is no partial answer to take.
    let raw = git(
        dir,
        &["for-each-ref", "--format", &fmt, "refs/remotes/origin"],
    )
    .or_else(|| {
        let plain = "%(refname:lstrip=3)%09%(committerdate:unix)%09%(authorname)%09\
                     %(authoremail:trim)%09%(subject)";
        git(
            dir,
            &["for-each-ref", "--format", plain, "refs/remotes/origin"],
        )
    });

    let mut facts = HashMap::new();
    for line in raw.unwrap_or_default().lines() {
        let mut f = line.split('\t');
        let (Some(name), Some(when), Some(who), Some(email), Some(subject)) =
            (f.next(), f.next(), f.next(), f.next(), f.next())
        else {
            continue;
        };
        // `origin/HEAD` is a symref, not a branch; it would otherwise appear as
        // a row duplicating the default.
        if name.is_empty() || name == "HEAD" {
            continue;
        }
        let ahead_behind = f.next().and_then(|ab| {
            let mut n = ab.split_whitespace();
            Some((n.next()?.parse().ok()?, n.next()?.parse().ok()?))
        });
        facts.insert(
            name.to_string(),
            Facts {
                when: when.parse().unwrap_or(0),
                who: who.to_string(),
                email: email.to_string(),
                subject: subject.to_string(),
                ahead_behind,
            },
        );
    }
    Local {
        default,
        current,
        locals,
        me_email,
        me_name,
        facts,
    }
}

/// Which group a row sits in.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Group {
    Default,
    Mine,
    All,
}

enum At {
    Head(usize),
    Branch(usize, usize),
    Nothing,
}

pub struct Branches {
    repo: String,
    dir: std::path::PathBuf,
    fetch: Arc<Fetcher>,
    local: Local,
    branches: Vec<Branch>,
    /// Indices into `branches`, per group, in display order.
    groups: Vec<(Group, &'static str, Vec<usize>)>,
    open: Vec<bool>,
    prs: HashMap<String, (u64, bool)>,
    checks: HashMap<String, Verdict>,
    epoch_seen: u64,
    error: Option<String>,
    status: String,
    sel: usize,
    /// A menu ran something, so the next tick re-asks.
    stale: bool,
}

const BRANCHES: &str = "branches?per_page=100";
const PULLS: &str = "pulls?state=open&per_page=100";

impl Branches {
    pub fn open(repo: &str, dir: &std::path::Path, fetch: Arc<Fetcher>) -> Self {
        let local = read_local(dir);
        let mut me = Self {
            repo: repo.to_string(),
            dir: dir.to_path_buf(),
            fetch,
            local,
            branches: Vec::new(),
            groups: Vec::new(),
            open: Vec::new(),
            prs: HashMap::new(),
            checks: HashMap::new(),
            epoch_seen: 0,
            error: None,
            status: String::new(),
            sel: 0,
            stale: false,
        };
        me.ask();
        // Drawn from local git immediately, so the table is on screen before
        // any of the three requests land.
        me.rebuild();
        me
    }

    fn path(&self, tail: &str) -> String {
        format!("repos/{}/{tail}", self.repo)
    }

    fn ask(&self) {
        for tail in [BRANCHES, PULLS, ""] {
            self.fetch.request(Req::Json {
                path: self.path(tail).trim_end_matches('/').to_string(),
            });
        }
        self.fetch.request(Req::Runs {
            query: "per_page=100".into(),
        });
    }

    fn refresh(&self) {
        for tail in [BRANCHES, PULLS] {
            self.fetch.refresh(Req::Json {
                path: self.path(tail),
            });
        }
        self.fetch.refresh(Req::Runs {
            query: "per_page=100".into(),
        });
    }

    fn json(&self, tail: &str) -> Option<Arc<serde_json::Value>> {
        let path = self.path(tail).trim_end_matches('/').to_string();
        match self.fetch.get(&Req::Json { path }) {
            Some(Got::Json(v)) => Some(v),
            _ => None,
        }
    }

    fn sync(&mut self) {
        if let Some(v) = self.json(BRANCHES) {
            match serde_json::from_value::<Vec<ApiBranch>>(v.as_ref().clone()) {
                Ok(api) => {
                    for b in api {
                        if let Some(existing) = self.branches.iter_mut().find(|x| x.name == b.name)
                        {
                            existing.protected = b.protected;
                        } else {
                            self.branches.push(Branch {
                                protected: b.protected,
                                facts: self.local.facts.get(&b.name).cloned(),
                                name: b.name,
                            });
                        }
                    }
                    self.error = None;
                }
                Err(e) => self.error = Some(format!("unreadable branch list: {e}")),
            }
        }
        if let Some(Got::Denied(d)) = self.fetch.get(&Req::Json {
            path: self.path(BRANCHES),
        }) {
            self.error = Some(d.fix());
        }
        if let Some(v) = self.json(PULLS) {
            if let Ok(prs) = serde_json::from_value::<Vec<Pr>>(v.as_ref().clone()) {
                self.prs = prs
                    .into_iter()
                    .map(|p| (p.head.name, (p.number, p.draft)))
                    .collect();
            }
        }
        if let Some(v) = self.json("") {
            if let Ok(info) = serde_json::from_value::<RepoInfo>(v.as_ref().clone()) {
                // Only as a fallback: the local symref is authoritative for
                // what THIS clone thinks, and it is what the ahead/behind
                // numbers were computed against.
                if self.local.default.is_none() {
                    self.local.default = info.default_branch;
                }
            }
        }
        if let Some(Got::Runs(runs)) = self.fetch.get(&Req::Runs {
            query: "per_page=100".into(),
        }) {
            // Newest first from the API, so the first run seen for a branch is
            // its latest -- `entry().or_insert` keeps exactly that one.
            let mut seen: HashMap<String, Verdict> = HashMap::new();
            for r in runs.iter() {
                if let Some(b) = &r.head_branch {
                    seen.entry(b.clone()).or_insert_with(|| r.verdict());
                }
            }
            self.checks = seen;
        }
        self.rebuild();
    }

    /// Re-derive the groups from whatever is known.
    fn rebuild(&mut self) {
        // Local git knows branches the API has not confirmed yet, which is how
        // the table draws before the first response.
        for (name, facts) in &self.local.facts {
            if !self.branches.iter().any(|b| &b.name == name) {
                self.branches.push(Branch {
                    name: name.clone(),
                    protected: false,
                    facts: Some(facts.clone()),
                });
            }
        }
        let when = |b: &Branch| b.facts.as_ref().map(|f| f.when).unwrap_or(0);
        self.branches.sort_by(|a, b| {
            when(b)
                .cmp(&when(a))
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });

        let def = self.local.default.clone().unwrap_or_default();
        let mut d = Vec::new();
        let mut mine = Vec::new();
        let mut all = Vec::new();
        for (i, b) in self.branches.iter().enumerate() {
            if b.name == def {
                d.push(i);
                continue;
            }
            if self.local.is_mine(b.facts.as_ref()) {
                mine.push(i);
            }
            all.push(i);
        }
        let keep = |v: Vec<usize>| !v.is_empty();
        let mut groups: Vec<(Group, &'static str, Vec<usize>)> = Vec::new();
        if keep(d.clone()) {
            groups.push((Group::Default, "\u{2b50} default", d));
        }
        if keep(mine.clone()) {
            groups.push((Group::Mine, "\u{1f331} your branches", mine));
        }
        if keep(all.clone()) {
            groups.push((Group::All, "\u{1f33f} all branches", all));
        }
        // Open state follows the group COUNT, so a group appearing after the
        // API answers does not shift which ones were collapsed.
        if self.open.len() != groups.len() {
            self.open = groups
                .iter()
                .map(|(g, _, _)| *g != Group::All || groups.len() == 1)
                .collect();
        }
        self.groups = groups;
    }

    fn at(&self, sel: usize) -> At {
        let mut row = 0;
        for (g, (_, _, ids)) in self.groups.iter().enumerate() {
            if sel == row {
                return At::Head(g);
            }
            row += 1;
            if self.open[g] {
                for (k, _) in ids.iter().enumerate() {
                    if sel == row {
                        return At::Branch(g, k);
                    }
                    row += 1;
                }
            }
            row += 1; // spacer
        }
        At::Nothing
    }

    fn branch_at(&self, sel: usize) -> Option<&Branch> {
        match self.at(sel) {
            At::Branch(g, k) => self.branches.get(self.groups[g].2[k]),
            _ => None,
        }
    }

    fn is_default(&self, name: &str) -> bool {
        self.local.default.as_deref() == Some(name)
    }

    fn is_current(&self, name: &str) -> bool {
        self.local.current.as_deref() == Some(name)
    }

    /// The row for one branch: the marker column, then the facts right-aligned
    /// as a table.
    fn row_for(&self, b: &Branch) -> Row {
        // Two fixed cells before the name, so every name starts in the same
        // column whether or not it is marked.
        //
        // The lock is back, which is the design doc's detail an earlier version
        // of this could not meet. `U+1F512` is East Asian Wide -- two cells
        // where `\u{2605}` is one -- and padding by character count put them in
        // different columns. `width::pad` measures CELLS, so the flag is
        // exactly two wide whatever is in it.
        // Three states in one cell, which is what keeps the column fixed:
        // you are ON it, you HAVE it, or it is only on the remote. The last
        // is the interesting one -- it is the branch `Checkout` would have to
        // create -- and it is the blank, because most of a long list is
        // branches you have never fetched.
        let here = if self.is_current(&b.name) {
            "\u{25cf}"
        } else if self.local.locals.contains(&b.name) {
            "\u{25cb}"
        } else {
            " "
        };
        let flag = if self.is_default(&b.name) {
            "\u{2b50}"
        } else if b.protected {
            "\u{1f512}"
        } else {
            ""
        };
        let flag = reticle::width::pad(flag, 2);
        let mut row = Row::leaf(format!("{here}{flag} {}", b.name));
        // Depth 1, because a branch IS a child of its group -- and `depth` is
        // what says so. It was 0, which looked right because the marker column
        // supplies the visual indent anyway, and was wrong in two ways that
        // only showed up later: filtering could not tell which group owned a
        // surviving row, so a match appeared with its heading deleted; and `h`
        // on a branch had no parent to collapse.
        row.depth = 1;

        let f = b.facts.as_ref();
        row = row.detail(
            f.map(|f| f.subject.replace(['\t', '\n'], " "))
                .unwrap_or_else(|| "not fetched yet".into()),
        );

        // Badges in reading order, each padded to a FIXED width so they line up
        // as columns -- `app` packs them right but does not align them.
        let who = f.map(|f| f.who.as_str()).unwrap_or("");
        row = row.badged(format!("{:<14}", trunc(who, 14)), idx::GRY);

        let age = f
            .map(|f| time::age((time::now() - f.when).max(0)))
            .unwrap_or_default();
        row = row.badged(format!("{age:>4}"), idx::DIM);

        // The default branch is what the others are measured against, so it has
        // no ahead/behind of its own -- blanks rather than two zeros, which
        // would read as a fact.
        let ab = if self.is_default(&b.name) {
            " ".repeat(9)
        } else {
            match f.and_then(|f| f.ahead_behind) {
                Some((a, d)) => format!("\u{2191}{a:>3} \u{2193}{d:>3}"),
                None => " ".repeat(9),
            }
        };
        let ab_colour = match f.and_then(|f| f.ahead_behind) {
            Some((_, d)) if d > 0 => idx::YEL,
            Some(_) => idx::GRN,
            None => idx::DIM,
        };
        row = row.badged(ab, ab_colour);

        // Padded in CELLS. `{:>9}` counts characters, so every checked row
        // would come out one column narrower than the blank ones -- the exact
        // bug `reticle::width` was written for.
        let (check, check_colour) = match self.checks.get(&b.name) {
            Some(v) => {
                let (t, c) = v.badge();
                (reticle::width::rpad(t, 9), c)
            }
            None => (" ".repeat(9), idx::DIM),
        };
        row = row.badged(check, check_colour);

        let (pr, pr_colour) = match self.prs.get(&b.name) {
            Some((n, draft)) => (
                format!("{:>6}", format!("#{n}")),
                if *draft { idx::GRY } else { idx::GRN },
            ),
            None => (" ".repeat(6), idx::DIM),
        };
        row.badged(pr, pr_colour)
    }

    /// The branch's action menu -- the three-dots from the design.
    fn menu_for(&self, b: &Branch) -> Menu {
        let name = b.name.clone();
        let repo = self.repo.clone();
        let dir = self.dir.to_string_lossy().into_owned();
        let g = |args: &[&str]| {
            let mut v = vec!["git".to_string(), "-C".into(), dir.clone()];
            v.extend(args.iter().map(|s| s.to_string()));
            v
        };
        let mut items = Vec::new();

        if !self.is_current(&name) {
            let have = self.local.locals.contains(&name);
            items.push(
                Item::new(
                    "Checkout",
                    format!("git switch {name}"),
                    Act::Run(g(&["switch", &name])),
                )
                .note(if have {
                    &["You already have this branch locally."]
                } else {
                    &[
                        "You have no local copy, so git creates one",
                        "tracking origin -- which is why the marker",
                        "column is blank on this row.",
                    ]
                }),
            );
        }
        // Offered on every branch, including one with no lock on it, because
        // "no rules apply" is a different answer from "unprotected by
        // mistake" and only this call can tell them apart.
        items.push(Item::new(
            "Effective rules",
            format!("gh api repos/{repo}/rules/branches/{name}"),
            Act::Open(Box::new(crate::rules::Rules::open(
                &repo,
                &name,
                Arc::clone(&self.fetch),
            ))),
        ));
        match self.prs.get(&name) {
            Some((n, _)) => {
                items.push(Item::new(
                    format!("Open PR #{n}"),
                    "gh pr view --web",
                    Act::Run(vec![
                        "gh".into(),
                        "pr".into(),
                        "view".into(),
                        n.to_string(),
                        "--repo".into(),
                        repo.clone(),
                        "--web".into(),
                    ]),
                ));
                items.push(Item::new(
                    format!("Diff PR #{n}"),
                    "gh pr diff | less",
                    Act::Run(vec![
                        "gh".into(),
                        "pr".into(),
                        "diff".into(),
                        n.to_string(),
                        "--repo".into(),
                        repo.clone(),
                    ]),
                ));
            }
            None if !self.is_default(&name) => {
                // `gh pr create` with no flags PROMPTS for title and body on a
                // tty, which is why this needs no text input of its own.
                items.push(
                    Item::new(
                        "New pull request",
                        "gh pr create",
                        // `--repo` is load-bearing, not tidiness: without it
                        // `gh pr create` resolves the repo from the process's
                        // cwd, and this TUI is launched from anywhere --
                        // which is the entire point of the repo index. Run
                        // from outside the clone it failed with `not a git
                        // repository`. Verified that `-R` alone is enough: gh
                        // resolves the base branch from the API, so there is
                        // no `--base` to supply.
                        Act::Run(vec![
                            "gh".into(),
                            "pr".into(),
                            "create".into(),
                            "--repo".into(),
                            repo.clone(),
                            "--head".into(),
                            name.clone(),
                        ]),
                    )
                    .note(&[
                        "gh asks for the title and body itself, so this",
                        "needs no text entry of its own.",
                    ]),
                );
            }
            None => {}
        }
        if !self.is_default(&name) {
            // The design's "rename branch", and the first real consumer of
            // `Flow::Ask`. `gh` has no rename command and the API wants the
            // new name as a field, so this is the shape of thing that still
            // needs a text field: a short identifier, not a body.
            items.push(
                Item::new(
                    "Rename branch",
                    "gh api -X POST .../rename",
                    Act::Prompt {
                        label: format!("rename {name} to"),
                        initial: name.clone(),
                        argv: vec![
                            "gh".into(),
                            "api".into(),
                            "-X".into(),
                            "POST".into(),
                            format!("repos/{repo}/branches/{name}/rename"),
                            "-f".into(),
                            "new_name={}".into(),
                        ],
                    },
                )
                .note(&[
                    "Renames it on the remote and moves any open PR with",
                    "it. Your local branch keeps the old name until you",
                    "fetch and re-point it.",
                ]),
            );
            // No input needed, so no field: `gh` takes the branch as an
            // argument and reports what it did.
            items.push(
                Item::new(
                    "Set as default branch",
                    "gh repo edit --default-branch",
                    Act::Run(vec![
                        "gh".into(),
                        "repo".into(),
                        "edit".into(),
                        repo.clone(),
                        "--default-branch".into(),
                        name.clone(),
                    ]),
                )
                .note(&["Needs admin on the repo; gh says so if you have not."]),
            );
        }
        items.push(Item::new(
            "Open in browser",
            "gh browse --branch",
            Act::Run(vec![
                "gh".into(),
                "browse".into(),
                "--repo".into(),
                repo.clone(),
                "--branch".into(),
                name.clone(),
            ]),
        ));
        if !self.is_default(&name) {
            items.push(
                Item::new(
                    "Delete remote branch",
                    format!("git push origin --delete {name}"),
                    Act::Run(g(&["push", "origin", "--delete", &name])),
                )
                .danger()
                .note(&[
                    "Deletes it on the remote. Your local copy stays.",
                    "git prints what it did and fails loudly if the",
                    "branch is protected.",
                ]),
            );
        }
        Menu::new("branch", name, items)
    }
}

fn trunc(s: &str, w: usize) -> String {
    if s.chars().count() <= w {
        return s.to_string();
    }
    s.chars().take(w.saturating_sub(1)).collect::<String>() + "\u{2026}"
}

impl Screen for Branches {
    fn title(&self) -> String {
        format!("{} \u{b7} branches", self.repo)
    }

    /// The whole point of `Split::Full`: six columns of fact per row, and
    /// nothing a pane could add that the row does not already say.
    fn split(&self) -> Split {
        Split::Full
    }

    fn focus(&mut self, sel: usize) {
        self.sel = sel;
        self.status.clear();
    }

    fn tick(&mut self) -> Tick {
        if self.stale {
            self.stale = false;
            self.local = read_local(&self.dir);
            self.refresh();
            return Tick::Changed;
        }
        let now = self.fetch.epoch();
        if now != self.epoch_seen {
            self.epoch_seen = now;
            self.sync();
            return Tick::Changed;
        }
        if self.fetch.pending() {
            return Tick::Wake(IN_FLIGHT);
        }
        Tick::Idle
    }

    fn rows(&mut self) -> Vec<Row> {
        if self.groups.is_empty() {
            return vec![Row::leaf(if self.fetch.pending() {
                "asking github\u{2026}"
            } else {
                "no branches found"
            })
            .detail(
                self.error
                    .clone()
                    .unwrap_or_else(|| "nothing under refs/remotes/origin".into()),
            )];
        }
        let mut rows = Vec::new();
        for (g, (_, name, ids)) in self.groups.iter().enumerate() {
            let mut head = Row::leaf(*name);
            head.group = true;
            head.expanded = self.open[g];
            rows.push(head.detail(match ids.len() {
                1 => "1".to_string(),
                n => n.to_string(),
            }));
            if self.open[g] {
                for &i in ids {
                    rows.push(self.row_for(&self.branches[i]));
                }
            }
            rows.push(Row::spacer());
        }
        rows
    }

    /// Never drawn -- `Split::Full` means `app` does not ask. Implemented
    /// because the trait requires it, and kept honest rather than
    /// `unreachable!()` in case a caller ever composes this differently.
    fn pane(&mut self, _sel: usize, _cols: u16, _rows: u16) -> Pane {
        Pane::default()
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        self.status.clear();
        match (action, self.at(sel)) {
            (Action::Activate | Action::Open, At::Head(g)) => {
                self.open[g] = !self.open[g];
                Flow::Dirty
            }
            (Action::Close, At::Head(g)) => {
                self.open[g] = false;
                Flow::Dirty
            }
            (Action::Close, At::Branch(g, _)) => {
                self.open[g] = false;
                Flow::Dirty
            }
            // The three-dots. Enter on a branch opens everything you can do to
            // it, named, rather than hiding it behind keys you have to be told.
            // `Activate` only -- `l` is a direction.
            (Action::Activate, At::Branch(..)) => {
                let Some(menu) = self.branch_at(sel).map(|b| self.menu_for(b)) else {
                    return Flow::Continue;
                };
                // Anything in there may change what this screen shows, so the
                // next tick after the pop re-reads git and the API.
                self.stale = true;
                Flow::Push(Box::new(menu))
            }
            (Action::Key('r'), _) => {
                self.local = read_local(&self.dir);
                self.refresh();
                self.status = "refreshing\u{2026}".into();
                Flow::Dirty
            }
            (Action::Key('f'), _) => {
                // A real fetch, on the real terminal: it can prompt for a key
                // passphrase, and it is the thing that makes ahead/behind true
                // again.
                self.stale = true;
                Flow::Detach(vec![
                    "git".into(),
                    "-C".into(),
                    self.dir.to_string_lossy().into_owned(),
                    "fetch".into(),
                    "--prune".into(),
                    "origin".into(),
                ])
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        let legend = format!(
            "{DIM}\u{25cf} here  \u{25cb} local copy  \u{2b50} default  \u{1f512} protected  \u{2191}ahead \u{2193}behind the default{OFF}"
        );
        match self.at(self.sel) {
            At::Head(_) => format!("enter open/close \u{b7} f fetch \u{b7} r refresh\n{legend}"),
            At::Branch(..) => {
                format!("enter what you can do to it \u{b7} f fetch \u{b7} r refresh\n{legend}")
            }
            At::Nothing => format!("f fetch \u{b7} r refresh\n{legend}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> Branches {
        let mut b = Branches {
            repo: "roest1/dotfiles".into(),
            dir: std::path::PathBuf::from("/nonexistent"),
            fetch: Arc::new(Fetcher::new("roest1/dotfiles")),
            local: Local {
                default: Some("main".into()),
                current: Some("feat/x".into()),
                // feat/x is checked out, feat/y is fetched but not checked
                // out, and chore/z has never been fetched -- one row per
                // marker state.
                locals: std::collections::HashSet::from([
                    "feat/x".to_string(),
                    "feat/y".to_string(),
                ]),
                me_email: Some("me@example.com".into()),
                me_name: Some("Riley Oest".into()),
                facts: HashMap::new(),
            },
            branches: Vec::new(),
            groups: Vec::new(),
            open: Vec::new(),
            prs: HashMap::new(),
            checks: HashMap::new(),
            epoch_seen: 0,
            error: None,
            status: String::new(),
            sel: 0,
            stale: false,
        };
        // Two of mine, authored under DIFFERENT names but one email -- the
        // real shape on this machine, and what makes name-matching wrong.
        for (name, who, email, ab) in [
            ("main", "Someone Else", "other@example.com", (0u32, 0u32)),
            ("feat/x", "Riley Oest", "me@example.com", (3, 1)),
            ("feat/y", "roest1", "me@example.com", (1, 0)),
            ("chore/z", "Someone Else", "other@example.com", (2, 7)),
        ] {
            b.local.facts.insert(
                name.into(),
                Facts {
                    when: 1_700_000_000,
                    who: who.into(),
                    email: email.into(),
                    subject: format!("work on {name}"),
                    ahead_behind: Some(ab),
                },
            );
        }
        b.rebuild();
        b
    }

    /// The three groups the design asks for, with the default on its own and
    /// "all" genuinely repeating "yours" -- which is what github.com does and
    /// what makes "yours" a shortcut rather than a filter.
    #[test]
    fn it_groups_default_yours_and_all() {
        let b = screen();
        let names: Vec<String> = b
            .groups
            .iter()
            .map(|(_, n, _)| n.split_whitespace().skip(1).collect::<Vec<_>>().join(" "))
            .collect();
        assert_eq!(names, vec!["default", "your branches", "all branches"]);
        assert_eq!(b.groups[0].2.len(), 1, "default is alone");
        // Both of mine, despite the two different author NAMES.
        assert_eq!(b.groups[1].2.len(), 2, "two of mine");
        assert_eq!(b.groups[2].2.len(), 3, "all, minus the default");
    }

    /// The invariant every tree screen here carries.
    #[test]
    fn the_walk_matches_the_rows() {
        let mut b = screen();
        for shape in [
            vec![true, true, true],
            vec![true, false, true],
            vec![false; 3],
        ] {
            b.open = shape;
            let rows = b.rows();
            for (i, row) in rows.iter().enumerate() {
                if !row.selectable {
                    continue;
                }
                match b.at(i) {
                    At::Head(g) => assert_eq!(row.label, b.groups[g].1),
                    At::Branch(g, k) => {
                        let want = &b.branches[b.groups[g].2[k]].name;
                        assert!(row.label.contains(want.as_str()), "{} vs {want}", row.label);
                    }
                    At::Nothing => panic!("row {i} ({}) resolves to nothing", row.label),
                }
            }
        }
    }

    /// `app` packs badges to the right but does not align them, so the screen
    /// pads each to a fixed width. If that slips, the table stops being a
    /// table -- and it is invisible in a unit test that only reads content.
    #[test]
    fn every_branch_row_has_the_same_column_widths() {
        let mut b = screen();
        b.open = vec![true, true, true];
        let rows = b.rows();
        let branch_rows: Vec<&Row> = rows
            .iter()
            .enumerate()
            .filter(|(i, r)| r.selectable && matches!(b.at(*i), At::Branch(..)))
            .map(|(_, r)| r)
            .collect();
        assert!(branch_rows.len() >= 4);
        let widths: Vec<Vec<usize>> = branch_rows
            .iter()
            .map(|r| r.badges.iter().map(|(t, _)| t.chars().count()).collect())
            .collect();
        for w in &widths {
            assert_eq!(*w, widths[0], "columns differ across rows");
        }
    }

    /// The default branch is what the others are measured against, so two
    /// zeros would read as a fact it does not have.
    #[test]
    fn the_default_branch_shows_no_ahead_behind() {
        let mut b = screen();
        b.open = vec![true, true, true];
        let rows = b.rows();
        let main = rows
            .iter()
            .find(|r| r.label.contains("main"))
            .expect("main");
        let ab = &main.badges[2].0;
        assert!(ab.trim().is_empty(), "default shows {ab:?}");
        // And a non-default one does carry it.
        let x = rows
            .iter()
            .find(|r| r.label.contains("feat/x"))
            .expect("feat/x");
        assert!(x.badges[2].0.contains('\u{2191}'), "{:?}", x.badges[2].0);
    }

    /// The marker column is two cells whether or not anything is in it, or
    /// names would start in different columns down the list.
    #[test]
    fn the_marker_column_is_fixed_width() {
        let mut b = screen();
        b.open = vec![true, true, true];
        let rows = b.rows();
        // Counted in CELLS. This assertion has now been wrong twice in two
        // different ways, which is why it is written out rather than inlined:
        // `str::find` returns a BYTE offset and `\u{2b50}` is four bytes, and
        // `chars().count()` returns CHARACTERS where a star is one char but
        // two cells. Both versions failed on a perfectly aligned row, and both
        // would have passed on a broken one whose counts happened to cancel.
        // Only cells describe what the terminal does.
        const MARKS: [char; 5] = [' ', '\u{25cf}', '\u{25cb}', '\u{2b50}', '\u{1f512}'];
        for (i, r) in rows.iter().enumerate() {
            if !matches!(b.at(i), At::Branch(..)) {
                continue;
            }
            let marks: String = r.label.chars().take_while(|c| MARKS.contains(c)).collect();
            assert_eq!(
                reticle::width::width(&marks),
                4,
                "marker prefix of {:?} is {} cells, so its name is in the wrong column",
                r.label,
                reticle::width::width(&marks)
            );
        }
    }

    /// Three states in one cell: on it, have it, or remote only. The last is
    /// the one the table could not say before, and it is the one that decides
    /// whether Checkout creates a branch or moves to one.
    #[test]
    fn the_marker_says_whether_you_have_a_local_copy() {
        let mut b = screen();
        b.open = vec![true, true, true];
        let rows = b.rows();
        let mark = |name: &str| -> char {
            rows.iter()
                .find(|r| r.label.contains(name))
                .unwrap_or_else(|| panic!("no row for {name}"))
                .label
                .chars()
                .next()
                .unwrap()
        };
        assert_eq!(mark("feat/x"), '\u{25cf}', "checked out");
        assert_eq!(mark("feat/y"), '\u{25cb}', "fetched, not checked out");
        assert_eq!(mark("chore/z"), ' ', "remote only");

        // And the menu says which of the two Checkout is about to do, since
        // creating a branch and moving to one are different acts.
        let z = b
            .branches
            .iter()
            .find(|x| x.name == "chore/z")
            .unwrap()
            .clone();
        let pane = b.menu_for(&z).pane(0, 60, 40).lines.join("\n");
        assert!(pane.contains("no local copy"), "{pane}");
        let y = b
            .branches
            .iter()
            .find(|x| x.name == "feat/y")
            .unwrap()
            .clone();
        let pane = b.menu_for(&y).pane(0, 60, 40).lines.join("\n");
        assert!(pane.contains("already have"), "{pane}");
    }

    /// Effective rules is offered on EVERY branch, lock or no lock: "no rules
    /// apply" and "unprotected by mistake" are different answers, and only
    /// the call can tell them apart.
    #[test]
    fn every_branch_can_be_asked_what_actually_rules_it() {
        let mut b = screen();
        b.open = vec![true, true, true];
        for name in ["main", "feat/x", "chore/z"] {
            let br = b.branches.iter().find(|x| x.name == name).unwrap().clone();
            let labels: Vec<String> = b
                .menu_for(&br)
                .rows()
                .iter()
                .map(|r| r.label.clone())
                .collect();
            assert!(
                labels.iter().any(|l| l == "Effective rules"),
                "{name}: {labels:?}"
            );
        }
    }

    /// Nothing a menu offers may depend on the process's working directory.
    ///
    /// This TUI is launched from anywhere -- that is what the repo index is
    /// for -- so a `gh` command has to name the repo and a `git` command has
    /// to carry `-C`. `New pull request` did neither: `gh pr create --head x`
    /// resolves the repo from the cwd, so it worked when run inside the clone
    /// and failed with `not a git repository` everywhere else. Found by
    /// driving it, which is also the only way it could have been found.
    #[test]
    fn no_menu_item_depends_on_the_working_directory() {
        let mut b = screen();
        b.open = vec![true, true, true];
        for name in ["main", "feat/x", "feat/y", "chore/z"] {
            let br = b.branches.iter().find(|x| x.name == name).unwrap().clone();
            for item in b.menu_for(&br).items() {
                let argv = match &item.act {
                    Act::Run(v) => v.clone(),
                    Act::Prompt { argv, .. } => argv.clone(),
                    _ => continue,
                };
                match argv.first().map(String::as_str) {
                    // Either as `--repo <slug>` or inside a `gh api` path.
                    // Both name it, which is what actually matters.
                    Some("gh") => assert!(
                        argv.iter().any(|a| a.contains("roest1/dotfiles")),
                        "{name}: {:?} names no repo: {argv:?}",
                        item.label
                    ),
                    Some("git") => assert!(
                        argv.iter().any(|a| a == "-C"),
                        "{name}: {:?} runs git without -C: {argv:?}",
                        item.label
                    ),
                    _ => {}
                }
            }
        }
    }

    /// The menu is built from what is TRUE of that branch: no checkout for the
    /// one you are on, no delete for the default, and "new PR" only when there
    /// is not already one.
    #[test]
    fn the_menu_offers_only_what_applies() {
        let mut b = screen();
        let labels =
            |m: &mut Menu| -> Vec<String> { m.rows().iter().map(|r| r.label.clone()).collect() };

        let main = b
            .branches
            .iter()
            .find(|x| x.name == "main")
            .unwrap()
            .clone();
        let l = labels(&mut b.menu_for(&main));
        assert!(!l.iter().any(|s| s.contains("Delete")), "default: {l:?}");
        assert!(!l.iter().any(|s| s.contains("New pull")), "default: {l:?}");

        let cur = b
            .branches
            .iter()
            .find(|x| x.name == "feat/x")
            .unwrap()
            .clone();
        let l = labels(&mut b.menu_for(&cur));
        assert!(!l.iter().any(|s| s.contains("Checkout")), "current: {l:?}");
        assert!(l.iter().any(|s| s.contains("New pull")), "{l:?}");
        assert!(l.iter().any(|s| s.contains("Delete")), "{l:?}");

        b.prs.insert("feat/y".into(), (42, false));
        let other = b
            .branches
            .iter()
            .find(|x| x.name == "feat/y")
            .unwrap()
            .clone();
        let l = labels(&mut b.menu_for(&other));
        assert!(l.iter().any(|s| s.contains("Checkout")), "{l:?}");
        assert!(l.iter().any(|s| s.contains("#42")), "{l:?}");
        assert!(!l.iter().any(|s| s.contains("New pull")), "has one: {l:?}");
    }

    /// Git < 2.41 has no `%(ahead-behind:)`. The table must still draw, with
    /// those two columns blank rather than the screen failing.
    #[test]
    fn an_old_git_loses_two_columns_and_nothing_else() {
        let mut b = screen();
        for f in b.local.facts.values_mut() {
            f.ahead_behind = None;
        }
        b.branches.clear();
        b.rebuild();
        b.open = vec![true, true, true];
        let rows = b.rows();
        let x = rows
            .iter()
            .find(|r| r.label.contains("feat/x"))
            .expect("feat/x");
        assert!(x.badges[2].0.trim().is_empty());
        // The author and subject still arrive, which is the point.
        assert!(x.detail.as_deref().unwrap_or("").contains("work on"));
    }
}
