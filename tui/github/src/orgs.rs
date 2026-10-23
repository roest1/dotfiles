//! Organisations: the list, and one org's repos, members and teams.
//!
//! The level that works TODAY. `read:org` -- which this token already has --
//! covers members, teams and repos for every org you belong to, and on this
//! machine that is five orgs including one with twenty-one private repos. No
//! new scope, no new permission conversation.
//!
//! ## Enterprises are not here, and that is a decision
//!
//! There is no Enterprise level. Measured before writing any of this: every org
//! on this account is on a free or team plan, and the token has no
//! `read:enterprise`, so GraphQL refuses `viewer.enterprises` outright. A screen
//! for something that cannot exist is a screen to maintain for nothing. If an
//! enterprise ever appears, it slots in as a level ABOVE this one and `Host`
//! already takes the deeper seeded stack that implies.
//!
//! ## Why the org screen is a host and the repo level is not yet
//!
//! An org has three things worth tabbing between and all three are reachable.
//! A repo has six in the design and exactly one ported, and a strip with one
//! tab is a title that cost a row. So the repo level stays a direct push to
//! Actions until a second repo screen exists -- at which point it becomes a
//! `Host` and nothing else changes.

use std::sync::Arc;

use reticle::{nav::Action, Flow, Host, Pane, Row, Screen, Tick};
use serde::Deserialize;

use crate::gh::{Fetcher, Got, Req};
use crate::paint::{idx, BOLD, DIM, GRY, OFF, ORG, PUR, RED};

const IN_FLIGHT: std::time::Duration = std::time::Duration::from_millis(100);

#[derive(Debug, Clone, Deserialize)]
pub struct Org {
    pub login: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct OrgDetail {
    login: String,
    name: Option<String>,
    description: Option<String>,
    blog: Option<String>,
    location: Option<String>,
    #[serde(default)]
    public_repos: u64,
    #[serde(default)]
    owned_private_repos: u64,
    plan: Option<Plan>,
}

#[derive(Debug, Clone, Deserialize)]
struct Plan {
    name: String,
    #[serde(default)]
    seats: u64,
    #[serde(default)]
    filled_seats: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct Member {
    login: String,
}

#[derive(Debug, Clone, Deserialize)]
struct Team {
    name: String,
    slug: String,
    description: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct OrgRepo {
    name: String,
    description: Option<String>,
    private: bool,
    archived: bool,
    default_branch: Option<String>,
    language: Option<String>,
    pushed_at: Option<String>,
}

// ─── The org list ─────────────────────────────────────────────────

pub struct OrgList {
    fetch: Arc<Fetcher>,
    orgs: Vec<Org>,
    /// The per-org detail, fetched for whichever row the cursor is on and the
    /// one after it -- the same one-neighbour rule the run list uses, and for
    /// the same reason: down is the direction of travel.
    epoch_seen: u64,
    error: Option<String>,
    sel: usize,
}

const ORGS_PATH: &str = "user/orgs?per_page=100";

impl OrgList {
    pub fn new(fetch: Arc<Fetcher>) -> Self {
        fetch.request(Req::Json {
            path: ORGS_PATH.into(),
        });
        Self {
            fetch,
            orgs: Vec::new(),
            epoch_seen: 0,
            error: None,
            sel: 0,
        }
    }

    fn detail_req(login: &str) -> Req {
        Req::Json {
            path: format!("orgs/{login}"),
        }
    }

    fn sync(&mut self) {
        match self.fetch.get(&Req::Json {
            path: ORGS_PATH.into(),
        }) {
            Some(Got::Json(v)) => match serde_json::from_value::<Vec<Org>>(v.as_ref().clone()) {
                Ok(mut orgs) => {
                    orgs.sort_by_key(|o| o.login.to_lowercase());
                    self.orgs = orgs;
                    self.error = None;
                }
                Err(e) => self.error = Some(format!("unreadable org list: {e}")),
            },
            Some(Got::Denied(d)) => {
                self.error = Some(format!("needs {} \u{2014} {}", d.suggest, d.fix()))
            }
            Some(Got::Failed(e)) => self.error = Some(e),
            _ => {}
        }
        self.want_detail(self.sel);
    }

    fn want_detail(&self, sel: usize) {
        for i in [sel, sel + 1] {
            if let Some(o) = self.orgs.get(i) {
                self.fetch.request(Self::detail_req(&o.login));
            }
        }
    }

    fn detail_of(&self, login: &str) -> Option<OrgDetail> {
        match self.fetch.get(&Self::detail_req(login)) {
            Some(Got::Json(v)) => serde_json::from_value(v.as_ref().clone()).ok(),
            _ => None,
        }
    }
}

impl Screen for OrgList {
    fn title(&self) -> String {
        "orgs".into()
    }

    fn focus(&mut self, sel: usize) {
        self.sel = sel;
        self.want_detail(sel);
    }

    fn tick(&mut self) -> Tick {
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
        if let Some(e) = &self.error {
            return vec![Row::leaf("could not list orgs").detail(e.clone())];
        }
        if self.orgs.is_empty() {
            return vec![Row::leaf(if self.fetch.pending() {
                "asking github\u{2026}"
            } else {
                "you are in no organisations"
            })];
        }
        self.orgs
            .iter()
            .map(|o| {
                let row = Row::leaf(&o.login);
                // The plan is the one fact that changes what an org can DO, so
                // it earns the badge; anything else is in the pane.
                match self.detail_of(&o.login).and_then(|d| d.plan) {
                    Some(p) if p.name == "free" => row.badged("free", idx::DIM),
                    Some(p) => row.badged(p.name, idx::GRN),
                    None => row,
                }
                .detail(
                    o.description
                        .clone()
                        .unwrap_or_default()
                        .replace(['\n', '\t'], " "),
                )
            })
            .collect()
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = Vec::new();
        if let Some(e) = &self.error {
            lines.push(format!("{RED}{e}{OFF}"));
            return Pane { image: None, lines };
        }
        let Some(org) = self.orgs.get(sel) else {
            return Pane { image: None, lines };
        };
        lines.push(format!("{BOLD}{PUR}{}{OFF}", org.login));
        match self.detail_of(&org.login) {
            None => {
                if let Some(d) = &org.description {
                    lines.push(String::new());
                    lines.push(d.clone());
                }
                lines.push(String::new());
                lines.push(format!("{DIM}fetching details\u{2026}{OFF}"));
            }
            Some(d) => {
                if let Some(n) = &d.name {
                    if n != &d.login {
                        lines.push(format!("{GRY}{n}{OFF}"));
                    }
                }
                if let Some(desc) = &d.description {
                    lines.push(String::new());
                    lines.push(desc.clone());
                }
                lines.push(String::new());
                lines.push(crate::paint::rule(cols));
                lines.push(format!(
                    "{:10} {} public, {} private",
                    "repos", d.public_repos, d.owned_private_repos
                ));
                if let Some(p) = &d.plan {
                    lines.push(format!(
                        "{:10} {}{}",
                        "plan",
                        p.name,
                        if p.seats > 0 {
                            format!(" \u{b7} {}/{} seats", p.filled_seats, p.seats)
                        } else {
                            String::new()
                        }
                    ));
                }
                for (k, v) in [("where", d.location.clone()), ("web", d.blog.clone())] {
                    if let Some(v) = v.filter(|s| !s.is_empty()) {
                        lines.push(format!("{k:10} {v}"));
                    }
                }
            }
        }
        lines.push(String::new());
        lines.push(format!("{DIM}enter for its repos, members and teams{OFF}"));
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        match action {
            Action::Activate => match self.orgs.get(sel) {
                Some(o) => Flow::Push(Box::new(org_screen(Arc::clone(&self.fetch), &o.login))),
                None => Flow::Continue,
            },
            Action::Key('r') => {
                self.fetch.refresh(Req::Json {
                    path: ORGS_PATH.into(),
                });
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        "enter open \u{b7} r refresh".into()
    }
}

// ─── One org ──────────────────────────────────────────────────────

/// An org's three tabs. All reachable with `read:org`.
pub fn org_screen(fetch: Arc<Fetcher>, login: &str) -> Host {
    Host::new(
        Some(login.to_string()),
        vec![
            (
                "\u{1f4e6} Repos".into(),
                Box::new(OrgPane::repos(Arc::clone(&fetch), login)) as Box<dyn Screen>,
            ),
            (
                "\u{1f465} Members".into(),
                Box::new(OrgPane::members(Arc::clone(&fetch), login)),
            ),
            (
                "\u{1f3f7} Teams".into(),
                Box::new(OrgPane::teams(fetch, login)),
            ),
        ],
    )
}

/// One row, decided before it becomes a `Row`.
///
/// A named type rather than the tuple it started as: three of these nested two
/// deep is the kind of signature you have to decode every time you read it,
/// and the fields have obvious names.
struct Line {
    label: String,
    detail: String,
    badge: Option<(String, u8)>,
}

impl Line {
    fn plain(label: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            detail: detail.into(),
            badge: None,
        }
    }
}

/// Which of an org's lists this is.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Repos,
    Members,
    Teams,
}

/// One flat list about one org.
///
/// Three kinds in one type rather than three near-identical screens, because
/// the only differences are the path, how a row reads and what the pane says --
/// and all three are a `match` on four arms. Three files would have been three
/// copies of the fetch-and-tick dance.
pub struct OrgPane {
    fetch: Arc<Fetcher>,
    org: String,
    kind: Kind,
    path: String,
    epoch_seen: u64,
    error: Option<String>,
    rows: Vec<Line>,
    sel: usize,
}

impl OrgPane {
    fn make(fetch: Arc<Fetcher>, org: &str, kind: Kind) -> Self {
        let path = match kind {
            Kind::Repos => format!("orgs/{org}/repos?per_page=100&sort=pushed"),
            Kind::Members => format!("orgs/{org}/members?per_page=100"),
            Kind::Teams => format!("orgs/{org}/teams?per_page=100"),
        };
        fetch.request(Req::Json { path: path.clone() });
        Self {
            fetch,
            org: org.to_string(),
            kind,
            path,
            epoch_seen: 0,
            error: None,
            rows: Vec::new(),
            sel: 0,
        }
    }

    fn repos(fetch: Arc<Fetcher>, org: &str) -> Self {
        Self::make(fetch, org, Kind::Repos)
    }
    fn members(fetch: Arc<Fetcher>, org: &str) -> Self {
        Self::make(fetch, org, Kind::Members)
    }
    fn teams(fetch: Arc<Fetcher>, org: &str) -> Self {
        Self::make(fetch, org, Kind::Teams)
    }

    fn sync(&mut self) {
        let got = self.fetch.get(&Req::Json {
            path: self.path.clone(),
        });
        match got {
            Some(Got::Json(v)) => {
                self.rows = build_rows(self.kind, &v);
                self.error = None;
            }
            Some(Got::Denied(d)) => self.error = Some(d.fix()),
            Some(Got::Failed(e)) => self.error = Some(e),
            _ => {}
        }
    }
}

/// One `Line` per row, per kind.
fn build_rows(kind: Kind, v: &serde_json::Value) -> Vec<Line> {
    match kind {
        Kind::Repos => serde_json::from_value::<Vec<OrgRepo>>(v.clone())
            .unwrap_or_default()
            .into_iter()
            .map(|r| {
                // Say the unusual thing: private is the norm in these orgs so
                // PUBLIC is what is worth badging, and archived outranks both
                // because it means "do not touch this".
                let badge = if r.archived {
                    Some(("archived".to_string(), idx::DIM))
                } else if !r.private {
                    Some(("public".to_string(), idx::GRN))
                } else {
                    None
                };
                let mut detail = r.language.unwrap_or_default();
                if let Some(b) = r.default_branch.filter(|b| b != "main" && b != "master") {
                    if !detail.is_empty() {
                        detail.push_str(" \u{b7} ");
                    }
                    detail.push_str(&b);
                }
                if detail.is_empty() {
                    detail = r.description.unwrap_or_default().replace(['\n', '\t'], " ");
                }
                if let Some(when) = r.pushed_at.as_deref().and_then(crate::time::epoch) {
                    let age = crate::time::age((crate::time::now() - when).max(0));
                    detail = if detail.is_empty() {
                        age
                    } else {
                        format!("{age} \u{b7} {detail}")
                    };
                }
                Line {
                    label: r.name,
                    detail,
                    badge,
                }
            })
            .collect(),
        Kind::Members => serde_json::from_value::<Vec<Member>>(v.clone())
            .unwrap_or_default()
            .into_iter()
            .map(|m| Line::plain(m.login, ""))
            .collect(),
        Kind::Teams => serde_json::from_value::<Vec<Team>>(v.clone())
            .unwrap_or_default()
            .into_iter()
            .map(|t| {
                let detail = t.description.unwrap_or_default().replace(['\n', '\t'], " ");
                let detail = if detail.is_empty() { t.slug } else { detail };
                Line::plain(t.name, detail)
            })
            .collect(),
    }
}

impl Screen for OrgPane {
    fn title(&self) -> String {
        self.org.clone()
    }

    fn focus(&mut self, sel: usize) {
        self.sel = sel;
    }

    fn tick(&mut self) -> Tick {
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
        if let Some(e) = &self.error {
            return vec![Row::leaf("could not read").detail(e.clone())];
        }
        if self.rows.is_empty() {
            return vec![Row::leaf(if self.fetch.pending() {
                "asking github\u{2026}"
            } else {
                "nothing here"
            })];
        }
        self.rows
            .iter()
            .map(|line| {
                let r = Row::leaf(&line.label).detail(line.detail.clone());
                match &line.badge {
                    Some((t, c)) => r.badged(t.clone(), *c),
                    None => r,
                }
            })
            .collect()
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = Vec::new();
        if let Some(e) = &self.error {
            lines.push(format!("{RED}{e}{OFF}"));
            return Pane { image: None, lines };
        }
        let Some(Line { label, detail, .. }) = self.rows.get(sel) else {
            return Pane { image: None, lines };
        };
        match self.kind {
            Kind::Repos => {
                lines.push(format!("{BOLD}{}/{}{OFF}", self.org, label));
                lines.push(format!("{GRY}{detail}{OFF}"));
                lines.push(crate::paint::rule(cols));
                lines.push(format!(
                    "{DIM}Not cloned here, or it would be in the Repos tab{OFF}"
                ));
                lines.push(format!(
                    "{DIM}of your account, read from disk. This list is the{OFF}"
                ));
                lines.push(format!("{DIM}org's, from the API.{OFF}"));
                lines.push(String::new());
                lines.push(format!("{ORG}o{OFF} opens it on github.com"));
            }
            Kind::Members => {
                lines.push(format!("{BOLD}{label}{OFF}"));
                lines.push(format!("{GRY}member of {}{OFF}", self.org));
                lines.push(crate::paint::rule(cols));
                lines.push(format!(
                    "{DIM}Roles and team membership need admin:org, which{OFF}"
                ));
                lines.push(format!("{DIM}this token does not have.{OFF}"));
                lines.push(String::new());
                lines.push(format!("{ORG}o{OFF} opens their profile"));
            }
            Kind::Teams => {
                lines.push(format!("{BOLD}{label}{OFF}"));
                lines.push(format!("{GRY}{detail}{OFF}"));
                lines.push(crate::paint::rule(cols));
                lines.push(format!(
                    "{DIM}Team members and repo access need admin:org.{OFF}"
                ));
            }
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        match action {
            Action::Key('o') => {
                let Some(line) = self.rows.get(sel) else {
                    return Flow::Continue;
                };
                let label = &line.label;
                let url = match self.kind {
                    Kind::Repos => format!("https://github.com/{}/{}", self.org, label),
                    Kind::Members => format!("https://github.com/{label}"),
                    Kind::Teams => format!("https://github.com/orgs/{}/teams", self.org),
                };
                let opener = if cfg!(target_os = "macos") {
                    "open"
                } else {
                    "xdg-open"
                };
                let _ = std::process::Command::new(opener).arg(url).spawn();
                Flow::Continue
            }
            Action::Key('r') => {
                self.fetch.refresh(Req::Json {
                    path: self.path.clone(),
                });
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        match self.kind {
            Kind::Repos => "o browser \u{b7} r refresh".into(),
            Kind::Members => "o profile \u{b7} r refresh".into(),
            Kind::Teams => "r refresh".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_repo_row_badges_the_unusual_case_only() {
        let v: serde_json::Value = serde_json::from_str(
            r#"[{"name":"platform","private":true,"archived":false,"language":"Rust"},
                {"name":"brand","private":false,"archived":false},
                {"name":"old","private":true,"archived":true}]"#,
        )
        .expect("parses");
        let rows = build_rows(Kind::Repos, &v);
        // Private is the norm in these orgs, so it carries no badge.
        assert!(rows[0].badge.is_none(), "{:?}", rows[0].label);
        assert_eq!(rows[1].badge.as_ref().map(|b| b.0.as_str()), Some("public"));
        // Archived outranks public: it means "do not touch this".
        assert_eq!(
            rows[2].badge.as_ref().map(|b| b.0.as_str()),
            Some("archived")
        );
    }

    /// A default branch that is not main is worth saying; main is not.
    #[test]
    fn a_repo_row_names_an_unusual_default_branch() {
        let v: serde_json::Value = serde_json::from_str(
            r#"[{"name":"a","private":true,"archived":false,"default_branch":"dev"},
                {"name":"b","private":true,"archived":false,"default_branch":"main"}]"#,
        )
        .expect("parses");
        let rows = build_rows(Kind::Repos, &v);
        assert!(rows[0].detail.contains("dev"), "{:?}", rows[0].detail);
        assert!(!rows[1].detail.contains("main"), "{:?}", rows[1].detail);
    }

    #[test]
    fn a_team_with_no_description_falls_back_to_its_slug() {
        let v: serde_json::Value =
            serde_json::from_str(r#"[{"name":"Platform","slug":"platform"}]"#).expect("parses");
        let rows = build_rows(Kind::Teams, &v);
        assert_eq!(rows[0].detail, "platform");
    }

    /// A payload that is not the shape we expected must come back empty rather
    /// than panicking -- these are three different endpoints read by one type.
    #[test]
    fn a_wrong_shaped_payload_is_empty_rather_than_a_panic() {
        let v: serde_json::Value = serde_json::from_str(r#"{"message":"Not Found"}"#).unwrap();
        assert!(build_rows(Kind::Repos, &v).is_empty());
        assert!(build_rows(Kind::Members, &v).is_empty());
        assert!(build_rows(Kind::Teams, &v).is_empty());
    }
}
