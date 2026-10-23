//! Pull requests: filters on the left, the list on the right.
//!
//! The first `Split::Sidebar` screen, and the one the mock in `GITHUB_TUI.md`
//! is drawn for. The layout is the inverse of every other screen here -- the
//! left column holds CONTROLS and the content is on the right -- which is why
//! the sidebar needed to be a navigable region rather than a width.
//!
//! ## Every control is a dropdown, and that is deliberate
//!
//! The mock draws the state toggles, the sort order and the search in a header
//! strip above the list, and the five user/label filters down the side. They
//! are all the same thing: a named thing you open, pick from, and close. So
//! they are all rows in the sidebar, one control per row, and `enter` on a row
//! means exactly one thing.
//!
//! The alternative was a header row holding four controls side by side, which
//! needs column-wise focus inside a row -- a second navigation axis, and the
//! one thing the directional model is built to avoid. Riley's note that the
//! sidebar dropdowns and the main-pane dropdowns are the same kind of thing is
//! what made this the obvious shape.
//!
//! ## Selection and bulk actions
//!
//! `space` ticks a pull request, the same key that toggles a section in
//! `dots`. With anything ticked the list grows a row at the top saying how
//! many, and `enter` on it opens a menu whose items act on the set. So bulk
//! actions need no extra region and no extra keys: they are the same `Menu`
//! every other screen uses.
//!
//! ## What is filtered where
//!
//! `state` goes into the `gh pr list` call, because it changes which pull
//! requests exist. Everything else -- author, assignee, involvement, review
//! requests, labels, sort, and the `/` search -- is applied to the fifty that
//! came back, which is instant and needs no round trip. The user lists are
//! derived from those fifty rather than fetched: the people who have pull
//! requests here are the people worth filtering by, and it saves two
//! endpoints.

use std::collections::BTreeSet;
use std::sync::Arc;

use reticle::{nav::Action, Flow, Pane, Row, Screen, Split, Tick};
use serde::Deserialize;

use crate::gh::{Fetcher, Got, Req};
use crate::menu::{Act, Item, Menu};
use crate::paint::{idx, DIM, OFF};
use crate::time;

const IN_FLIGHT: std::time::Duration = std::time::Duration::from_millis(100);

/// Everything `gh pr list` is asked for, in one call.
const FIELDS: &str = "number,title,author,headRefName,baseRefName,reviewDecision,\
isDraft,createdAt,updatedAt,additions,deletions,labels,statusCheckRollup,url,state,assignees";

#[derive(Debug, Clone, Deserialize)]
struct Who {
    #[serde(default)]
    login: String,
}

#[derive(Debug, Clone, Deserialize)]
struct Label {
    name: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Check {
    #[serde(default)]
    conclusion: Option<String>,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    status: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pr {
    number: u64,
    title: String,
    #[serde(default)]
    author: Option<Who>,
    #[serde(default)]
    assignees: Vec<Who>,
    head_ref_name: Option<String>,
    base_ref_name: Option<String>,
    review_decision: Option<String>,
    #[serde(default)]
    is_draft: bool,
    created_at: Option<String>,
    updated_at: Option<String>,
    #[serde(default)]
    additions: i64,
    #[serde(default)]
    deletions: i64,
    #[serde(default)]
    labels: Vec<Label>,
    #[serde(default)]
    status_check_rollup: Vec<Check>,
    state: Option<String>,
}

impl Pr {
    fn author_login(&self) -> &str {
        self.author
            .as_ref()
            .map(|a| a.login.as_str())
            .unwrap_or("?")
    }

    /// The review glyph, in the vocabulary the fzf list used.
    fn review(&self) -> (&'static str, u8) {
        match self.state.as_deref() {
            Some("MERGED") => return ("\u{1f7e3} merged", idx::GRY),
            Some("CLOSED") => return ("\u{26d4} closed", idx::GRY),
            _ => {}
        }
        if self.is_draft {
            return ("\u{1f4dd} draft", idx::DIM);
        }
        match self.review_decision.as_deref() {
            Some("APPROVED") => ("\u{2705} approved", idx::GRN),
            Some("CHANGES_REQUESTED") => ("\u{1f504} changes", idx::RED),
            Some("REVIEW_REQUIRED") => ("\u{1f440} review", idx::YEL),
            _ => ("\u{23f3} open", idx::YEL),
        }
    }

    /// The check rollup, collapsed the way the bash `ci` helper did: any
    /// failure is a failure, anything outstanding is outstanding, else green.
    fn checks(&self) -> Option<(&'static str, u8)> {
        if self.status_check_rollup.is_empty() {
            return None;
        }
        let bad = |c: &Check| {
            matches!(c.conclusion.as_deref(), Some("FAILURE"))
                || matches!(c.state.as_deref(), Some("FAILURE") | Some("ERROR"))
        };
        let waiting = |c: &Check| {
            matches!(c.state.as_deref(), Some("PENDING") | Some("EXPECTED"))
                || matches!(c.status.as_deref(), Some(s) if s != "COMPLETED")
        };
        if self.status_check_rollup.iter().any(bad) {
            Some(("\u{274c}", idx::RED))
        } else if self.status_check_rollup.iter().any(waiting) {
            Some(("\u{23f3}", idx::YEL))
        } else {
            Some(("\u{2705}", idx::GRN))
        }
    }

    /// `feat/a -> main  +10 -2` -- the branch pair and the diff size, which the
    /// fzf row carried and which the mock's column list leaves implicit.
    fn shape(&self) -> String {
        let mut s = String::new();
        if let (Some(h), Some(b)) = (&self.head_ref_name, &self.base_ref_name) {
            s.push_str(&format!("{h} \u{2192} {b}"));
        }
        if self.additions != 0 || self.deletions != 0 {
            if !s.is_empty() {
                s.push_str("  ");
            }
            s.push_str(&format!("+{} \u{2212}{}", self.additions, self.deletions));
        }
        s
    }

    fn age(&self) -> String {
        self.created_at
            .as_deref()
            .and_then(time::epoch)
            .map(|t| time::age((time::now() - t).max(0)))
            .unwrap_or_default()
    }

    fn touched(&self) -> i64 {
        self.updated_at
            .as_deref()
            .and_then(time::epoch)
            .or_else(|| self.created_at.as_deref().and_then(time::epoch))
            .unwrap_or(0)
    }

    fn involves(&self, who: &str) -> bool {
        self.author_login() == who || self.assignees.iter().any(|a| a.login == who)
    }
}

/// One control in the sidebar.
enum Control {
    /// Exactly one of these. Picking collapses, because the question is
    /// answered.
    Pick {
        name: &'static str,
        options: Vec<String>,
        chosen: usize,
    },
    /// Any number. Picking leaves it open, because you are usually choosing
    /// more than one -- which is the interaction the design doc specifies.
    Many {
        name: &'static str,
        options: Vec<String>,
        on: Vec<bool>,
    },
    /// Not a filter: a thing to do.
    Action { name: &'static str, detail: String },
}

impl Control {
    fn name(&self) -> &str {
        match self {
            Control::Pick { name, .. } | Control::Many { name, .. } => name,
            Control::Action { name, .. } => name,
        }
    }

    fn len(&self) -> usize {
        match self {
            Control::Pick { options, .. } | Control::Many { options, .. } => options.len(),
            Control::Action { .. } => 0,
        }
    }

    /// What the collapsed row says it is set to.
    fn summary(&self) -> String {
        match self {
            Control::Pick {
                options, chosen, ..
            } => options.get(*chosen).cloned().unwrap_or_default(),
            Control::Many { options, on, .. } => {
                let n = on.iter().filter(|x| **x).count();
                match n {
                    0 => "any".into(),
                    1 => options
                        .iter()
                        .zip(on)
                        .find(|(_, x)| **x)
                        .map(|(o, _)| o.clone())
                        .unwrap_or_default(),
                    // The count rather than the names: five logins do not fit
                    // and the pane is not here to hold them.
                    n => format!("{n} of {}", options.len()),
                }
            }
            Control::Action { detail, .. } => detail.clone(),
        }
    }

    fn picked(&self) -> Vec<&str> {
        match self {
            Control::Many { options, on, .. } => options
                .iter()
                .zip(on)
                .filter(|(_, x)| **x)
                .map(|(o, _)| o.as_str())
                .collect(),
            _ => Vec::new(),
        }
    }
}

/// Which sidebar control, and which option within it.
enum SideAt {
    Head(usize),
    Option(usize, usize),
    Nothing,
}

/// Which main row.
enum At {
    Bulk,
    Pr(usize),
    Nothing,
}

/// The order of the controls, by index, so the code reads as the design does.
const STATE: usize = 0;
const SORT: usize = 1;
const CREATED: usize = 2;
const ASSIGNED: usize = 3;
const INVOLVES: usize = 4;
const LABELS: usize = 5;

pub struct Prs {
    repo: String,
    fetch: Arc<Fetcher>,
    me: String,
    prs: Vec<Pr>,
    /// Indices into `prs`, after the sidebar's filters and the sort.
    shown: Vec<usize>,
    /// Ticked pull request NUMBERS, so a refresh cannot silently move the
    /// selection onto different rows.
    ticked: BTreeSet<u64>,
    controls: Vec<Control>,
    open: Vec<bool>,
    epoch_seen: u64,
    error: Option<String>,
    status: String,
    sel: usize,
    /// Set after a menu ran something, so the next tick re-asks.
    stale: bool,
}

impl Prs {
    pub fn open(repo: &str, me: &str, fetch: Arc<Fetcher>) -> Self {
        let controls = vec![
            Control::Pick {
                name: "state",
                options: vec![
                    "open".into(),
                    "closed".into(),
                    "merged".into(),
                    "all".into(),
                ],
                chosen: 0,
            },
            Control::Pick {
                name: "sort",
                options: vec!["newest".into(), "oldest".into(), "recently updated".into()],
                chosen: 0,
            },
            Control::Many {
                name: "created by",
                options: Vec::new(),
                on: Vec::new(),
            },
            Control::Many {
                name: "assigned to",
                options: Vec::new(),
                on: Vec::new(),
            },
            Control::Many {
                name: "involves",
                options: Vec::new(),
                on: Vec::new(),
            },
            Control::Many {
                name: "labels",
                options: Vec::new(),
                on: Vec::new(),
            },
            Control::Action {
                name: "new pull request",
                detail: "gh pr create".into(),
            },
        ];
        let open = vec![false; controls.len()];
        let me_ = Self {
            repo: repo.to_string(),
            fetch,
            me: me.to_string(),
            prs: Vec::new(),
            shown: Vec::new(),
            ticked: BTreeSet::new(),
            controls,
            open,
            epoch_seen: 0,
            error: None,
            status: String::new(),
            sel: 0,
            stale: false,
        };
        me_.ask();
        me_
    }

    fn state(&self) -> &str {
        match &self.controls[STATE] {
            Control::Pick {
                options, chosen, ..
            } => options[*chosen].as_str(),
            _ => "open",
        }
    }

    fn req(&self) -> Req {
        Req::Cmd {
            args: vec![
                "pr".into(),
                "list".into(),
                "--repo".into(),
                self.repo.clone(),
                "--state".into(),
                self.state().into(),
                "--limit".into(),
                "50".into(),
                "--json".into(),
                FIELDS.into(),
            ],
        }
    }

    fn ask(&self) {
        self.fetch.request(self.req());
    }

    fn sync(&mut self) {
        match self.fetch.get(&self.req()) {
            Some(Got::Json(v)) => match serde_json::from_value::<Vec<Pr>>(v.as_ref().clone()) {
                Ok(prs) => {
                    self.prs = prs;
                    self.error = None;
                    self.learn_options();
                }
                Err(e) => self.error = Some(format!("unreadable pull request list: {e}")),
            },
            Some(Got::Denied(d)) => self.error = Some(d.fix()),
            Some(Got::Failed(e)) => self.error = Some(e),
            _ => {}
        }
        self.apply();
    }

    /// Fill the user and label dropdowns from the pull requests themselves.
    ///
    /// `me` is pinned first whether or not they appear, which is the design
    /// doc's "me at the top" -- and it is the option you reach for most, so it
    /// should not move about as the list changes.
    fn learn_options(&mut self) {
        let mut users: Vec<String> = vec![self.me.clone()];
        let mut labels: Vec<String> = Vec::new();
        for pr in &self.prs {
            for who in std::iter::once(pr.author_login().to_string())
                .chain(pr.assignees.iter().map(|a| a.login.clone()))
            {
                if !who.is_empty() && who != "?" && !users.contains(&who) {
                    users.push(who);
                }
            }
            for l in &pr.labels {
                if !labels.contains(&l.name) {
                    labels.push(l.name.clone());
                }
            }
        }
        labels.sort();
        for (i, opts) in [
            (CREATED, users.clone()),
            (ASSIGNED, users.clone()),
            (INVOLVES, users),
            (LABELS, labels),
        ] {
            if let Control::Many { options, on, .. } = &mut self.controls[i] {
                // Selections are kept by NAME across a refresh: the option list
                // can grow, and re-indexing a Vec<bool> would silently move a
                // tick onto someone else.
                let was: Vec<String> = options
                    .iter()
                    .zip(on.iter())
                    .filter(|(_, x)| **x)
                    .map(|(o, _)| o.clone())
                    .collect();
                *on = opts.iter().map(|o| was.contains(o)).collect();
                *options = opts;
            }
        }
    }

    /// Re-derive `shown` from the controls and the sort.
    fn apply(&mut self) {
        let created = self.controls[CREATED].picked();
        let assigned = self.controls[ASSIGNED].picked();
        let involves = self.controls[INVOLVES].picked();
        let labels = self.controls[LABELS].picked();
        let mut keep: Vec<usize> = (0..self.prs.len())
            .filter(|&i| {
                let pr = &self.prs[i];
                let ok_created = created.is_empty() || created.contains(&pr.author_login());
                let ok_assigned = assigned.is_empty()
                    || pr
                        .assignees
                        .iter()
                        .any(|a| assigned.contains(&a.login.as_str()));
                let ok_involves = involves.is_empty() || involves.iter().any(|w| pr.involves(w));
                let ok_labels = labels.is_empty()
                    || pr.labels.iter().any(|l| labels.contains(&l.name.as_str()));
                ok_created && ok_assigned && ok_involves && ok_labels
            })
            .collect();
        let sort = match &self.controls[SORT] {
            Control::Pick { chosen, .. } => *chosen,
            _ => 0,
        };
        match sort {
            1 => keep.sort_by_key(|&i| self.prs[i].number),
            2 => keep.sort_by_key(|&i| std::cmp::Reverse(self.prs[i].touched())),
            // Newest first, which is what `gh pr list` already gives -- sorted
            // explicitly so the order does not depend on that staying true.
            _ => keep.sort_by_key(|&i| std::cmp::Reverse(self.prs[i].number)),
        }
        self.shown = keep;
    }

    fn side_at(&self, sel: usize) -> SideAt {
        let mut row = 0;
        for (c, ctl) in self.controls.iter().enumerate() {
            if sel == row {
                return SideAt::Head(c);
            }
            row += 1;
            if self.open[c] {
                for o in 0..ctl.len() {
                    if sel == row {
                        return SideAt::Option(c, o);
                    }
                    row += 1;
                }
            }
        }
        SideAt::Nothing
    }

    /// True when the bulk row is drawn, which shifts every main index by one.
    fn bulk(&self) -> bool {
        !self.ticked.is_empty()
    }

    fn at(&self, sel: usize) -> At {
        if self.bulk() {
            if sel == 0 {
                return At::Bulk;
            }
            return self
                .shown
                .get(sel - 1)
                .map(|&i| At::Pr(i))
                .unwrap_or(At::Nothing);
        }
        self.shown
            .get(sel)
            .map(|&i| At::Pr(i))
            .unwrap_or(At::Nothing)
    }

    fn pr_menu(&self, pr: &Pr) -> Menu {
        let n = pr.number.to_string();
        let repo = self.repo.clone();
        let gh = |args: &[&str]| {
            let mut v = vec!["gh".to_string(), "pr".into()];
            v.extend(args.iter().map(|s| s.to_string()));
            v.extend(["--repo".to_string(), repo.clone()]);
            v
        };
        let mut items = vec![
            Item::new(
                "Checkout locally",
                "gh pr checkout",
                Act::Run(gh(&["checkout", &n])),
            ),
            Item::new("Diff", "gh pr diff", Act::Run(gh(&["diff", &n]))),
            Item::new(
                "Changed files",
                "gh pr diff --name-only",
                Act::Run(gh(&["diff", &n, "--name-only"])),
            ),
            // gh opens an editor or prompts for the body itself.
            Item::new("Comment", "gh pr comment", Act::Run(gh(&["comment", &n]))),
        ];
        if pr.state.as_deref() == Some("OPEN") {
            items.push(
                Item::new(
                    "Approve",
                    "gh pr review --approve",
                    Act::Run(gh(&["review", &n, "--approve"])),
                )
                .confirm()
                .note(&["Posts an approving review as you."]),
            );
            items.push(Item::new(
                "Request changes",
                "gh pr review --request-changes",
                Act::Run(gh(&["review", &n, "--request-changes"])),
            ));
            items.push(Item::new(
                "Add a label",
                "gh pr edit --add-label",
                Act::Prompt {
                    label: format!("label to add to #{n}"),
                    initial: String::new(),
                    argv: gh(&["edit", &n, "--add-label", "{}"]),
                },
            ));
            items.push(Item::new(
                "Add a reviewer",
                "gh pr edit --add-reviewer",
                Act::Prompt {
                    label: format!("reviewer to add to #{n}"),
                    initial: String::new(),
                    argv: gh(&["edit", &n, "--add-reviewer", "{}"]),
                },
            ));
            // Interactive: gh asks what to change.
            items.push(Item::new(
                "Edit title / body",
                "gh pr edit",
                Act::Run(gh(&["edit", &n])),
            ));
            items.push(
                Item::new("Merge", "gh pr merge", Act::Run(gh(&["merge", &n])))
                    .confirm()
                    .note(&[
                        "gh asks which merge method and whether to delete",
                        "the branch, so this confirms the merge itself.",
                    ]),
            );
            items.push(
                Item::new(
                    if pr.is_draft {
                        "Mark ready"
                    } else {
                        "Mark draft"
                    },
                    if pr.is_draft {
                        "gh pr ready"
                    } else {
                        "gh pr ready --undo"
                    },
                    Act::Run(if pr.is_draft {
                        gh(&["ready", &n])
                    } else {
                        gh(&["ready", &n, "--undo"])
                    }),
                )
                .confirm(),
            );
            items.push(
                Item::new("Close", "gh pr close", Act::Run(gh(&["close", &n])))
                    .danger()
                    .note(&["Closes it without merging. It can be reopened."]),
            );
        }
        items.push(Item::new(
            "Open in browser",
            "gh pr view --web",
            Act::Run(gh(&["view", &n, "--web"])),
        ));
        Menu::new("pull request", format!("#{n}  {}", pr.title), items)
    }

    /// The menu for everything ticked.
    fn bulk_menu(&self) -> Menu {
        let nums: Vec<String> = self.ticked.iter().map(|n| n.to_string()).collect();
        let repo = self.repo.clone();
        // One `gh` call per pull request would be one Detach per pull request,
        // and Detach runs ONE command. So the bulk items are built as a single
        // command where gh takes many numbers, and skipped where it does not.
        let mut items = Vec::new();
        for (label, verb) in [("Close all", "close"), ("Reopen all", "reopen")] {
            let mut argv = vec!["gh".to_string(), "pr".into(), verb.into()];
            argv.extend(nums.iter().cloned());
            argv.extend(["--repo".to_string(), repo.clone()]);
            items.push(
                Item::new(
                    label,
                    format!("gh pr {verb} \u{d7}{}", nums.len()),
                    Act::Run(argv),
                )
                .danger()
                .note(&["Applies to every ticked pull request."]),
            );
        }
        let mut label_argv = vec!["gh".to_string(), "pr".into(), "edit".into()];
        label_argv.extend(nums.iter().cloned());
        label_argv.extend([
            "--repo".to_string(),
            repo.clone(),
            "--add-label".into(),
            "{}".into(),
        ]);
        items.push(Item::new(
            "Add a label to all",
            "gh pr edit --add-label",
            Act::Prompt {
                label: format!("label for {} pull requests", nums.len()),
                initial: String::new(),
                argv: label_argv,
            },
        ));
        let mut rev_argv = vec!["gh".to_string(), "pr".into(), "edit".into()];
        rev_argv.extend(nums.iter().cloned());
        rev_argv.extend([
            "--repo".to_string(),
            repo,
            "--add-reviewer".into(),
            "{}".into(),
        ]);
        items.push(Item::new(
            "Add a reviewer to all",
            "gh pr edit --add-reviewer",
            Act::Prompt {
                label: format!("reviewer for {} pull requests", nums.len()),
                initial: String::new(),
                argv: rev_argv,
            },
        ));
        items.push(Item::new(
            "Untick everything",
            "clears the selection",
            Act::Back,
        ));
        Menu::new("selection", format!("{} pull requests", nums.len()), items)
    }
}

impl Screen for Prs {
    fn title(&self) -> String {
        format!("{} \u{b7} pull requests", self.repo)
    }

    /// Filters left, list right -- the mock's layout, and the reason
    /// `Split::Sidebar` exists.
    fn split(&self) -> Split {
        Split::Sidebar
    }

    fn focus(&mut self, sel: usize) {
        self.sel = sel;
        self.status.clear();
    }

    fn tick(&mut self) -> Tick {
        if self.stale {
            self.stale = false;
            self.fetch.refresh(self.req());
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

    fn sidebar(&mut self) -> Vec<Row> {
        let mut rows = Vec::new();
        for (c, ctl) in self.controls.iter().enumerate() {
            let mut head = Row::leaf(ctl.name());
            if ctl.len() > 0 {
                head.group = true;
                head.expanded = self.open[c];
            }
            rows.push(head.detail(ctl.summary()));
            if !self.open[c] {
                continue;
            }
            match ctl {
                Control::Pick {
                    options, chosen, ..
                } => {
                    for (o, opt) in options.iter().enumerate() {
                        let mut r = Row::leaf(opt);
                        r.depth = 1;
                        if o == *chosen {
                            r = r.badged("\u{25cf}", idx::GRN);
                        }
                        rows.push(r);
                    }
                }
                Control::Many { options, on, .. } => {
                    for (o, opt) in options.iter().enumerate() {
                        let mut r = Row::leaf(opt);
                        r.depth = 1;
                        if on[o] {
                            r = r.badged("\u{2713}", idx::GRN);
                        }
                        rows.push(r);
                    }
                }
                Control::Action { .. } => {}
            }
        }
        rows
    }

    fn rows(&mut self) -> Vec<Row> {
        if let Some(e) = &self.error {
            return vec![Row::leaf("could not list pull requests").detail(e.clone())];
        }
        if self.prs.is_empty() {
            return vec![Row::leaf(if self.fetch.pending() {
                "asking github\u{2026}"
            } else {
                "nothing in this state"
            })];
        }
        let mut rows = Vec::new();
        if self.bulk() {
            let mut r = Row::leaf(format!(
                "\u{25a3} {} of {} ticked",
                self.ticked.len(),
                self.shown.len()
            ));
            r.group = true;
            rows.push(r.detail("enter for what to do with them"));
        }
        if self.shown.is_empty() {
            rows.push(Row::leaf("no pull request matches these filters"));
            return rows;
        }
        for &i in &self.shown {
            let pr = &self.prs[i];
            let (review, rc) = pr.review();
            let box_ = if self.ticked.contains(&pr.number) {
                "\u{25a3}"
            } else {
                "\u{25a1}"
            };
            let mut r = Row::leaf(format!(
                "{box_} {DIM}#{}{OFF} {}",
                pr.number,
                pr.title.replace(['\t', '\n'], " ")
            ))
            .detail(format!(
                "{} \u{b7} {} \u{b7} {}",
                pr.author_login(),
                pr.age(),
                pr.shape()
            ));
            r = r.badged(review, rc);
            if let Some((c, cc)) = pr.checks() {
                r = r.badged(c, cc);
            }
            rows.push(r);
        }
        rows
    }

    /// Never drawn: `Split::Sidebar` has no pane, by the mock's design.
    fn pane(&mut self, _sel: usize, _cols: u16, _rows: u16) -> Pane {
        Pane::default()
    }

    fn on_sidebar(&mut self, action: Action, sel: usize) -> Flow {
        match (action, self.side_at(sel)) {
            // `l` opens a closed control, and CROSSES to the list once there
            // is nothing left to open -- the edge rule, applied to a column
            // where every row is a dropdown. Without the second half `l` just
            // toggled dropdowns forever and the list was unreachable from
            // here, which is the opposite of navigating freely.
            (Action::Open, SideAt::Head(c)) if self.open[c] => Flow::Continue,
            (Action::Open, SideAt::Option(..)) => Flow::Continue,
            (Action::Activate | Action::Open, SideAt::Head(c)) => {
                if self.controls[c].len() == 0 {
                    // The action row. `gh pr create` prompts for the title and
                    // body itself, which is why this needs no field.
                    if let Control::Action { .. } = self.controls[c] {
                        return Flow::Detach(vec![
                            "gh".into(),
                            "pr".into(),
                            "create".into(),
                            "--repo".into(),
                            self.repo.clone(),
                        ]);
                    }
                    return Flow::Continue;
                }
                self.open[c] = !self.open[c];
                Flow::Dirty
            }
            (Action::Close, SideAt::Head(c)) => {
                self.open[c] = false;
                Flow::Dirty
            }
            // `h` on an option closes the control it belongs to, leaving the
            // cursor on its row. The design doc describes left-then-enter to
            // get the same place; one key is the same end state and matches
            // what `h` already means on a step row.
            (Action::Close, SideAt::Option(c, _)) => {
                self.open[c] = false;
                Flow::Dirty
            }
            (Action::Activate, SideAt::Option(c, o)) => {
                let refetch = c == STATE;
                match &mut self.controls[c] {
                    Control::Pick { chosen, .. } => {
                        *chosen = o;
                        // Answered, so it closes.
                        self.open[c] = false;
                    }
                    Control::Many { on, .. } => on[o] = !on[o],
                    Control::Action { .. } => {}
                }
                if refetch {
                    // Only `state` changes which pull requests EXIST.
                    self.prs.clear();
                    self.ticked.clear();
                    self.ask();
                }
                self.apply();
                self.sel = 0;
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        match (action, self.at(sel)) {
            // Space ticks, the same key that toggles a section in `dots` --
            // and deliberately not enter, which opens.
            (Action::Key(' '), At::Pr(i)) => {
                let n = self.prs[i].number;
                if !self.ticked.remove(&n) {
                    self.ticked.insert(n);
                }
                Flow::Dirty
            }
            (Action::Key('a'), _) => {
                if self.ticked.len() == self.shown.len() {
                    self.ticked.clear();
                } else {
                    self.ticked = self.shown.iter().map(|&i| self.prs[i].number).collect();
                }
                Flow::Dirty
            }
            (Action::Activate, At::Bulk) => {
                self.stale = true;
                Flow::Push(Box::new(self.bulk_menu()))
            }
            (Action::Activate, At::Pr(i)) => {
                let menu = self.pr_menu(&self.prs[i]);
                self.stale = true;
                Flow::Push(Box::new(menu))
            }
            (Action::Key('o'), At::Pr(i)) => {
                let n = self.prs[i].number.to_string();
                Flow::Detach(vec![
                    "gh".into(),
                    "pr".into(),
                    "view".into(),
                    n,
                    "--repo".into(),
                    self.repo.clone(),
                    "--web".into(),
                ])
            }
            (Action::Key('r'), _) => {
                self.fetch.refresh(self.req());
                self.status = "refreshing\u{2026}".into();
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        let legend = format!("{DIM}space tick \u{b7} a tick all \u{b7} h for the filters{OFF}");
        match self.at(self.sel) {
            At::Bulk => format!("enter what to do with the ticked ones\n{legend}"),
            At::Pr(_) => {
                format!("enter what you can do to it \u{b7} o browser \u{b7} r refresh\n{legend}")
            }
            At::Nothing => format!("r refresh\n{legend}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RAW: &str = r#"[
      {"number":70,"title":"Add the thing","author":{"login":"roest1"},"assignees":[],
       "headRefName":"feat/a","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED",
       "isDraft":false,"createdAt":"2026-10-22T10:00:00Z","updatedAt":"2026-10-23T10:00:00Z",
       "additions":10,"deletions":2,"labels":[{"name":"enhancement"}],
       "statusCheckRollup":[{"conclusion":"SUCCESS","state":null,"status":"COMPLETED"}],
       "state":"OPEN"},
      {"number":69,"title":"Fix the other","author":{"login":"someone"},
       "assignees":[{"login":"roest1"}],"headRefName":"fix/b","baseRefName":"main",
       "reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-10-20T10:00:00Z",
       "updatedAt":"2026-10-24T10:00:00Z","additions":1,"deletions":1,
       "labels":[{"name":"bug"}],
       "statusCheckRollup":[{"conclusion":"FAILURE","state":null,"status":"COMPLETED"}],
       "state":"OPEN"},
      {"number":68,"title":"Draft idea","author":{"login":"roest1"},"assignees":[],
       "headRefName":"wip","baseRefName":"main","reviewDecision":null,"isDraft":true,
       "createdAt":"2026-10-19T10:00:00Z","updatedAt":"2026-10-19T10:00:00Z",
       "additions":0,"deletions":0,"labels":[],"statusCheckRollup":[],"state":"OPEN"}
    ]"#;

    fn screen() -> Prs {
        let mut p = Prs::open("roest1/dotfiles", "roest1", Arc::new(Fetcher::new("")));
        p.prs = serde_json::from_str(RAW).expect("parses");
        p.learn_options();
        p.apply();
        p
    }

    fn plain(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for e in chars.by_ref() {
                    if e == 'm' {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    /// The whole payload parses, including the camelCase gh gives back and the
    /// nulls it leaves in.
    #[test]
    fn the_gh_pr_list_payload_parses() {
        let p = screen();
        assert_eq!(p.prs.len(), 3);
        assert_eq!(p.prs[0].author_login(), "roest1");
        assert_eq!(p.prs[0].review().0, "\u{1f440} review");
        assert_eq!(p.prs[1].review().0, "\u{2705} approved");
        assert_eq!(p.prs[2].review().0, "\u{1f4dd} draft");
    }

    /// The rollup collapses the way the fzf list did: any failure is a
    /// failure, nothing reported is nothing shown.
    #[test]
    fn the_check_rollup_collapses_to_one_mark() {
        let p = screen();
        assert_eq!(p.prs[0].checks().map(|c| c.0), Some("\u{2705}"));
        assert_eq!(p.prs[1].checks().map(|c| c.0), Some("\u{274c}"));
        assert_eq!(p.prs[2].checks(), None, "no checks is not a green tick");
    }

    /// `me` is pinned first whether or not they have a pull request, because
    /// it is the option reached for most and must not move about.
    #[test]
    fn the_user_dropdowns_put_me_first() {
        let p = screen();
        for i in [CREATED, ASSIGNED, INVOLVES] {
            match &p.controls[i] {
                Control::Many { options, .. } => assert_eq!(options[0], "roest1"),
                _ => panic!("expected a multi-select"),
            }
        }
        match &p.controls[LABELS] {
            Control::Many { options, .. } => assert_eq!(options, &["bug", "enhancement"]),
            _ => panic!("expected a multi-select"),
        }
    }

    /// Each filter narrows on its own field. `involves` is the one that is not
    /// just an equality test -- it is author OR assignee.
    #[test]
    fn each_filter_narrows_on_its_own_field() {
        let mut p = screen();
        assert_eq!(p.shown.len(), 3);

        // created by someone -> only #69
        if let Control::Many { options, on, .. } = &mut p.controls[CREATED] {
            let at = options
                .iter()
                .position(|o| o == "someone")
                .expect("someone");
            on[at] = true;
        }
        p.apply();
        assert_eq!(
            p.shown.iter().map(|&i| p.prs[i].number).collect::<Vec<_>>(),
            vec![69]
        );

        // and assigned to roest1 is also #69, by a different field
        if let Control::Many { on, .. } = &mut p.controls[CREATED] {
            on.iter_mut().for_each(|x| *x = false);
        }
        if let Control::Many { options, on, .. } = &mut p.controls[ASSIGNED] {
            let at = options.iter().position(|o| o == "roest1").expect("me");
            on[at] = true;
        }
        p.apply();
        assert_eq!(
            p.shown.iter().map(|&i| p.prs[i].number).collect::<Vec<_>>(),
            vec![69]
        );
    }

    /// Involvement is author OR assignee, which is why it is its own control
    /// rather than the other two combined.
    #[test]
    fn involves_catches_both_ends() {
        let mut p = screen();
        if let Control::Many { options, on, .. } = &mut p.controls[INVOLVES] {
            let at = options.iter().position(|o| o == "roest1").expect("me");
            on[at] = true;
        }
        p.apply();
        // #70 and #68 authored by me, #69 assigned to me.
        assert_eq!(p.shown.len(), 3);
    }

    #[test]
    fn the_sort_control_reorders_without_refetching() {
        let mut p = screen();
        let nums = |p: &Prs| p.shown.iter().map(|&i| p.prs[i].number).collect::<Vec<_>>();
        assert_eq!(nums(&p), vec![70, 69, 68], "newest first");
        if let Control::Pick { chosen, .. } = &mut p.controls[SORT] {
            *chosen = 1;
        }
        p.apply();
        assert_eq!(nums(&p), vec![68, 69, 70], "oldest first");
        if let Control::Pick { chosen, .. } = &mut p.controls[SORT] {
            *chosen = 2;
        }
        p.apply();
        assert_eq!(nums(&p), vec![69, 70, 68], "recently updated");
    }

    /// The invariant every tree screen here carries, for BOTH regions.
    #[test]
    fn both_walks_match_their_rows() {
        let mut p = screen();
        p.open = vec![true; p.controls.len()];
        let side = p.sidebar();
        for (i, row) in side.iter().enumerate() {
            match p.side_at(i) {
                SideAt::Head(c) => assert_eq!(row.label, p.controls[c].name()),
                SideAt::Option(c, o) => match &p.controls[c] {
                    Control::Pick { options, .. } | Control::Many { options, .. } => {
                        assert_eq!(row.label, options[o])
                    }
                    Control::Action { .. } => panic!("an action has no options"),
                },
                SideAt::Nothing => panic!("sidebar row {i} ({}) resolves to nothing", row.label),
            }
        }
        let rows = p.rows();
        for (i, row) in rows.iter().enumerate() {
            match p.at(i) {
                At::Pr(x) => assert!(
                    plain(&row.label).contains(&format!("#{}", p.prs[x].number)),
                    "{}",
                    row.label
                ),
                At::Bulk => assert!(row.label.contains("ticked")),
                At::Nothing => panic!("row {i} ({}) resolves to nothing", row.label),
            }
        }
    }

    /// Ticking adds the bulk row, which shifts every index below it -- the
    /// exact thing `at()` exists to keep straight.
    #[test]
    fn ticking_adds_a_row_and_the_walk_still_agrees() {
        let mut p = screen();
        assert!(matches!(p.at(0), At::Pr(_)));
        p.on_action(Action::Key(' '), 0);
        assert_eq!(p.ticked.len(), 1);
        assert!(matches!(p.at(0), At::Bulk), "the bulk row did not appear");
        assert!(matches!(p.at(1), At::Pr(_)));
        let rows = p.rows();
        assert!(rows[0].label.contains("1 of 3"));
        // And space again removes it.
        p.on_action(Action::Key(' '), 1);
        assert!(p.ticked.is_empty());
        assert!(matches!(p.at(0), At::Pr(_)));
    }

    /// Ticks are kept by NUMBER, not by position, so a refresh that reorders
    /// or shortens the list cannot move a tick onto a different pull request.
    #[test]
    fn ticks_survive_a_reorder_because_they_are_numbers() {
        let mut p = screen();
        p.on_action(Action::Key(' '), 0); // #70
        assert!(p.ticked.contains(&70));
        if let Control::Pick { chosen, .. } = &mut p.controls[SORT] {
            *chosen = 1;
        }
        p.apply();
        assert!(p.ticked.contains(&70), "the tick followed the row index");
        assert_eq!(p.ticked.len(), 1);
    }

    /// And a selection kept by name survives the option list growing, which a
    /// Vec<bool> indexed by position would not.
    #[test]
    fn a_selection_survives_a_new_option_appearing() {
        let mut p = screen();
        if let Control::Many { options, on, .. } = &mut p.controls[CREATED] {
            let at = options
                .iter()
                .position(|o| o == "someone")
                .expect("someone");
            on[at] = true;
        }
        // A fourth pull request from a new author arrives, sorting before.
        let mut more: Vec<Pr> = serde_json::from_str(RAW).expect("parses");
        more[0].author = Some(Who {
            login: "aaa".into(),
        });
        more[0].number = 99;
        p.prs.push(more.remove(0));
        p.learn_options();
        assert_eq!(p.controls[CREATED].picked(), vec!["someone"]);
    }

    /// `a` ticks everything shown and untick-alls when everything already is.
    #[test]
    fn a_ticks_all_of_what_is_shown() {
        let mut p = screen();
        p.on_action(Action::Key('a'), 0);
        assert_eq!(p.ticked.len(), 3);
        p.on_action(Action::Key('a'), 0);
        assert!(p.ticked.is_empty());
    }

    /// A closed pull request cannot be approved or merged, so those items are
    /// not offered -- the same rule the branch menu follows.
    #[test]
    fn the_menu_offers_only_what_applies_to_that_pull_request() {
        let p = screen();
        let labels = |m: &mut Menu| m.rows().iter().map(|r| r.label.clone()).collect::<Vec<_>>();

        let open = labels(&mut p.pr_menu(&p.prs[0]));
        assert!(open.iter().any(|s| s == "Merge"), "{open:?}");
        assert!(open.iter().any(|s| s == "Approve"), "{open:?}");
        assert!(open.iter().any(|s| s == "Mark draft"), "{open:?}");

        let mut closed = p.prs[0].clone();
        closed.state = Some("CLOSED".into());
        let shut = labels(&mut p.pr_menu(&closed));
        assert!(!shut.iter().any(|s| s == "Merge"), "{shut:?}");
        assert!(!shut.iter().any(|s| s == "Approve"), "{shut:?}");
        assert!(shut.iter().any(|s| s == "Open in browser"), "{shut:?}");

        // A draft offers to become ready rather than to become a draft.
        let draft = labels(&mut p.pr_menu(&p.prs[2]));
        assert!(draft.iter().any(|s| s == "Mark ready"), "{draft:?}");
    }

    /// The bulk menu names how many it will touch, and every item that changes
    /// something asks first.
    #[test]
    fn the_bulk_menu_says_how_many_and_asks() {
        let mut p = screen();
        p.on_action(Action::Key('a'), 0);
        let mut m = p.bulk_menu();
        let rows = m.rows();
        assert!(rows.iter().any(|r| r.label == "Close all"));
        // One command with three numbers, not three commands.
        match m.on_action(Action::Activate, 0) {
            Flow::Dirty => {}
            _ => panic!("a destructive bulk item must ask first"),
        }
        let pane = m.pane(0, 60, 40).lines.join("\n");
        assert!(
            pane.contains("68") && pane.contains("69") && pane.contains("70"),
            "{pane}"
        );
    }

    /// Changing `state` is the only control that refetches, because it is the
    /// only one that changes which pull requests exist.
    #[test]
    fn only_the_state_control_clears_the_list() {
        let mut p = screen();
        p.on_action(Action::Key('a'), 0);
        // The sort control keeps everything.
        p.open[SORT] = true;
        let sort_row = p
            .sidebar()
            .iter()
            .position(|r| r.label == "oldest")
            .expect("oldest");
        p.on_sidebar(Action::Activate, sort_row);
        assert_eq!(p.prs.len(), 3, "sorting refetched");
        assert_eq!(p.ticked.len(), 3, "sorting dropped the ticks");

        // The state control does not.
        p.open[STATE] = true;
        let state_row = p
            .sidebar()
            .iter()
            .position(|r| r.label == "closed")
            .expect("closed");
        p.on_sidebar(Action::Activate, state_row);
        assert!(p.prs.is_empty(), "changing state kept a stale list");
        assert!(
            p.ticked.is_empty(),
            "changing state kept ticks for gone rows"
        );
    }

    /// Picking from a single-select answers the question, so it closes;
    /// a multi-select stays open because you are usually choosing several.
    #[test]
    fn a_pick_closes_and_a_multi_select_stays_open() {
        let mut p = screen();
        p.open[SORT] = true;
        let row = p
            .sidebar()
            .iter()
            .position(|r| r.label == "oldest")
            .expect("oldest");
        p.on_sidebar(Action::Activate, row);
        assert!(!p.open[SORT], "a single-select stayed open");

        p.open[CREATED] = true;
        let row = p
            .sidebar()
            .iter()
            .position(|r| r.label == "someone")
            .expect("someone");
        p.on_sidebar(Action::Activate, row);
        assert!(p.open[CREATED], "a multi-select closed after one pick");
        assert_eq!(p.controls[CREATED].picked(), vec!["someone"]);
    }
}
