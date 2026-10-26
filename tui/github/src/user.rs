//! The user level: who you are, what this token may do, and your keys.
//!
//! The BOTTOM of the stack, always -- including when `github` is run inside a
//! repo. That is the whole answer to "I want to reach my settings even when I
//! opened this in a repo": there is one root, and standing in a repo seeds you
//! deeper into it rather than giving you a different one. `q` walks up from a
//! workflow run to the repo list to here. No jump key, because a jump key would
//! be a second way to express what the stack already says.
//!
//! ## Why the Account tab leads with scopes
//!
//! Most of what GitHub calls "user settings" is not in the API, and the parts
//! that are need scopes a `repo`-and-`read:org` token does not have. A screen
//! that just showed empty lists would be lying about an account that has keys.
//! So the first thing this says is what the token can do, read off the headers
//! of whatever call last ran -- see `crate::scopes` -- and every denial carries
//! the one command that fixes it.
//!
//! ## What is deliberately absent
//!
//! Personal access tokens and 2FA have NO API, at any scope. They are not
//! pending work and should not appear as empty rows; the Account tab says so in
//! one line instead, because "this screen cannot show you that" is information
//! and a blank list is not.

use std::sync::Arc;

use reticle::{nav::Action, Flow, Host, Pane, Row, Screen, Tick};
use serde::Deserialize;

use crate::gh::{Fetcher, Got, Req};
use crate::orgs::OrgList;
use crate::paint::{idx, BOLD, DIM, GRN, GRY, OFF, ORG, PUR, RED, YEL};
use crate::root::Root;

/// Build the user-level screen.
///
/// `here` is the repo the shell is standing in, if any -- it opens the Repos
/// tab with that repo selected, which is what makes `github` in a repo feel
/// like it opened where you were standing while still having the account
/// underneath it.
pub fn screen(fetch: Arc<Fetcher>, root: Root, login: &str) -> Host {
    Host::new(
        Some(login.to_string()),
        // Glyphs on the tabs, which is where they earn the most: the strip is
        // the thing you look at to navigate, and a shape is faster to find
        // than a word. The set is deliberately small and each one is a noun
        // you would draw -- a folder, a building, a person, a key.
        vec![
            ("\u{1f4c2} Repos".into(), Box::new(root) as Box<dyn Screen>),
            (
                "\u{1f3e2} Orgs".into(),
                Box::new(OrgList::new(Arc::clone(&fetch))),
            ),
            (
                "\u{1f464} Account".into(),
                Box::new(Account::new(Arc::clone(&fetch))),
            ),
            ("\u{1f511} Keys".into(), Box::new(Keys::new(fetch))),
        ],
    )
}

/// The login, read from `gh` rather than from the API.
///
/// `gh auth status` already knows it and answers instantly from a local config,
/// where `/user` is a network round trip. The title strip needs it before the
/// first frame, so the cheap local answer is the right one; the Account tab
/// fetches the full profile afterwards.
pub fn login() -> String {
    std::process::Command::new("gh")
        .args(["api", "user", "--jq", ".login"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "github".into())
}

#[derive(Debug, Clone, Deserialize)]
struct Profile {
    login: String,
    name: Option<String>,
    bio: Option<String>,
    company: Option<String>,
    location: Option<String>,
    #[serde(default)]
    public_repos: u64,
    #[serde(default)]
    total_private_repos: u64,
    #[serde(default)]
    followers: u64,
    #[serde(default)]
    following: u64,
    created_at: Option<String>,
}

// ─── Account ──────────────────────────────────────────────────────

pub struct Account {
    fetch: Arc<Fetcher>,
    profile: Option<Profile>,
    epoch_seen: u64,
    error: Option<String>,
    sel: usize,
}

/// What the rows on this tab are. Resolved once, as everywhere else here, so
/// `pane` and `at` cannot disagree about which row is which.
enum AccountRow {
    Profile,
    Scopes,
    NoApi,
}

impl Account {
    fn new(fetch: Arc<Fetcher>) -> Self {
        fetch.request(Req::Json {
            path: "user".into(),
        });
        Self {
            fetch,
            profile: None,
            epoch_seen: 0,
            error: None,
            sel: 0,
        }
    }

    fn at(&self, sel: usize) -> AccountRow {
        match sel {
            0 => AccountRow::Profile,
            1 => AccountRow::Scopes,
            _ => AccountRow::NoApi,
        }
    }

    fn sync(&mut self) {
        match self.fetch.get(&Req::Json {
            path: "user".into(),
        }) {
            Some(Got::Json(v)) => match serde_json::from_value::<Profile>(v.as_ref().clone()) {
                Ok(p) => {
                    self.profile = Some(p);
                    self.error = None;
                }
                Err(e) => self.error = Some(format!("unreadable profile: {e}")),
            },
            Some(Got::Denied(d)) => self.error = Some(d.fix()),
            Some(Got::Failed(e)) => self.error = Some(e),
            _ => {}
        }
    }
}

impl Screen for Account {
    fn title(&self) -> String {
        "account".into()
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
        Tick::Idle
    }

    fn rows(&mut self) -> Vec<Row> {
        let granted = self.fetch.granted();
        let scope_detail = if granted.is_empty() {
            "asking\u{2026}".to_string()
        } else {
            format!("{} granted", granted.list().len())
        };
        vec![
            Row::leaf("profile").detail(
                self.profile
                    .as_ref()
                    .map(|p| p.login.clone())
                    .unwrap_or_else(|| "fetching\u{2026}".into()),
            ),
            Row::leaf("token scopes").detail(scope_detail),
            Row::leaf("not available here").detail("tokens, 2FA"),
        ]
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = Vec::new();
        match self.at(sel) {
            AccountRow::Profile => match (&self.profile, &self.error) {
                (_, Some(e)) => {
                    lines.push(format!("{RED}{e}{OFF}"));
                }
                (None, None) => lines.push(format!("{DIM}fetching your profile\u{2026}{OFF}")),
                (Some(p), _) => {
                    lines.push(format!(
                        "{BOLD}{}{OFF}",
                        p.name.as_deref().unwrap_or(&p.login)
                    ));
                    lines.push(format!("{GRY}{}{OFF}", p.login));
                    if let Some(bio) = &p.bio {
                        lines.push(String::new());
                        lines.push(bio.clone());
                    }
                    lines.push(String::new());
                    for (k, v) in [
                        ("company", p.company.clone()),
                        ("location", p.location.clone()),
                        (
                            "joined",
                            p.created_at
                                .as_ref()
                                .and_then(|c| c.get(..10).map(str::to_string)),
                        ),
                    ] {
                        if let Some(v) = v {
                            lines.push(format!("{k:10} {v}"));
                        }
                    }
                    lines.push(String::new());
                    lines.push(format!(
                        "{:10} {} public, {} private",
                        "repos", p.public_repos, p.total_private_repos
                    ));
                    lines.push(format!(
                        "{:10} {} \u{b7} following {}",
                        "followers", p.followers, p.following
                    ));
                }
            },
            AccountRow::Scopes => {
                lines.push(format!("{BOLD}What this token may do{OFF}"));
                lines.push(crate::paint::rule(cols));
                let granted = self.fetch.granted();
                if granted.is_empty() {
                    lines.push(format!("{DIM}waiting for the first response\u{2026}{OFF}"));
                } else {
                    for s in granted.list() {
                        lines.push(format!("  {GRN}\u{2713}{OFF} {s}"));
                    }
                }
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}Read from the X-OAuth-Scopes header of whatever{OFF}"
                ));
                lines.push(format!(
                    "{DIM}call last ran, so it costs no request of its own.{OFF}"
                ));
                lines.push(String::new());
                lines.push(format!("{GRY}To widen it:{OFF}"));
                lines.push(format!(
                    "  {ORG}gh auth refresh -h github.com -s <scope>{OFF}"
                ));
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}The Keys tab names the exact scope it needs, so{OFF}"
                ));
                lines.push(format!("{DIM}there is nothing to look up.{OFF}"));
            }
            AccountRow::NoApi => {
                lines.push(format!("{BOLD}Not reachable from any token{OFF}"));
                lines.push(crate::paint::rule(cols));
                lines.push(format!("  {YEL}\u{2022}{OFF} personal access tokens"));
                lines.push(format!("  {YEL}\u{2022}{OFF} two-factor settings"));
                lines.push(String::new());
                lines.push("GitHub exposes no API for either, at any scope.".into());
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}Said out loud rather than shown as an empty list,{OFF}"
                ));
                lines.push(format!(
                    "{DIM}because a blank screen reads as \"none\" and would{OFF}"
                ));
                lines.push(format!("{DIM}be wrong.{OFF}"));
                lines.push(String::new());
                lines.push(format!("{GRY}github.com/settings/tokens{OFF}"));
            }
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, _action: Action, _sel: usize) -> Flow {
        Flow::Continue
    }

    fn footer(&self) -> String {
        match self.at(self.sel) {
            AccountRow::Scopes => "j/k move".into(),
            _ => "j/k move".into(),
        }
    }
}

// ─── Keys ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
struct SshKey {
    id: u64,
    key: String,
    title: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct GpgKey {
    key_id: String,
    #[serde(default)]
    emails: Vec<GpgEmail>,
    can_sign: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
struct GpgEmail {
    email: String,
}

/// One kind of credential, and what came back when we asked for it.
struct Lane {
    name: &'static str,
    path: &'static str,
    state: LaneState,
}

enum LaneState {
    Waiting,
    /// Rendered rows, already formatted -- each lane's shape differs enough
    /// that keeping the raw JSON around would mean re-deciding per draw.
    Items(Vec<(String, String)>),
    /// The scope story, which is the common case on a fresh token.
    Denied(crate::scopes::Denied),
    Failed(String),
}

pub struct Keys {
    fetch: Arc<Fetcher>,
    lanes: Vec<Lane>,
    open: Vec<bool>,
    epoch_seen: u64,
    sel: usize,
    /// Set when we hand the terminal to `gh auth refresh`, so the next tick
    /// re-asks with the token we now have.
    ///
    /// A flag rather than refreshing before the detach, because the detach is
    /// what CHANGES the token -- a request fired beforehand would race the
    /// thing it is waiting for and come back denied again, which looks exactly
    /// like the authorisation not having worked.
    reauthorised: bool,
}

enum At {
    Lane(usize),
    /// A row under a lane. Only the LANE matters -- the pane shows the whole
    /// lane either way, and every action here (refresh, re-authorise) is about
    /// the lane rather than one key in it.
    Item(usize),
    Nothing,
}

impl Keys {
    fn new(fetch: Arc<Fetcher>) -> Self {
        let lanes = vec![
            Lane {
                name: "\u{1f511} ssh keys",
                path: "user/keys",
                state: LaneState::Waiting,
            },
            Lane {
                name: "\u{1f510} gpg keys",
                path: "user/gpg_keys",
                state: LaneState::Waiting,
            },
            Lane {
                name: "\u{1f4dd} signing keys",
                path: "user/ssh_signing_keys",
                state: LaneState::Waiting,
            },
        ];
        for l in &lanes {
            fetch.request(Req::Json {
                path: l.path.into(),
            });
        }
        let open = vec![true; lanes.len()];
        Self {
            fetch,
            lanes,
            open,
            epoch_seen: 0,
            sel: 0,
            reauthorised: false,
        }
    }

    fn refresh_all(&self) {
        for lane in &self.lanes {
            self.fetch.refresh(Req::Json {
                path: lane.path.into(),
            });
        }
    }

    fn sync(&mut self) {
        for lane in self.lanes.iter_mut() {
            let got = self.fetch.get(&Req::Json {
                path: lane.path.into(),
            });
            lane.state = match got {
                Some(Got::Json(v)) => LaneState::Items(render_lane(lane.path, &v)),
                // The reason this screen exists. `GET /user/keys` without the
                // scope answers 404, which as an empty list reads as "you have
                // no SSH keys" on an account with two.
                Some(Got::Denied(d)) => LaneState::Denied(d),
                Some(Got::Failed(e)) => LaneState::Failed(e),
                _ => LaneState::Waiting,
            };
        }
    }

    fn at(&self, sel: usize) -> At {
        let mut row = 0;
        for (l, lane) in self.lanes.iter().enumerate() {
            if sel == row {
                return At::Lane(l);
            }
            row += 1;
            if self.open[l] {
                let n = match &lane.state {
                    LaneState::Items(items) => items.len(),
                    _ => 1, // the one explanatory row
                };
                for _ in 0..n {
                    if sel == row {
                        return At::Item(l);
                    }
                    row += 1;
                }
            }
            row += 1; // spacer
        }
        At::Nothing
    }
}

/// Turn one lane's JSON into (label, detail) pairs.
///
/// Per-path rather than a trait, because three shapes do not justify one and
/// the differences are the point: an SSH key is identified by its title, a GPG
/// key by its key id and the emails it covers.
fn render_lane(path: &str, v: &serde_json::Value) -> Vec<(String, String)> {
    match path {
        "user/keys" | "user/ssh_signing_keys" => {
            serde_json::from_value::<Vec<SshKey>>(v.clone())
                .unwrap_or_default()
                .into_iter()
                .map(|k| {
                    let label = k
                        .title
                        .filter(|t| !t.is_empty())
                        .unwrap_or_else(|| format!("key {}", k.id));
                    // The type plus a short fingerprint-ish tail: enough to tell
                    // two keys apart without putting 400 characters in a column.
                    let kind = k.key.split_whitespace().next().unwrap_or("").to_string();
                    let tail: String = k
                        .key
                        .chars()
                        .rev()
                        .take(8)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect();
                    (label, format!("{kind} \u{2026}{tail}"))
                })
                .collect()
        }
        "user/gpg_keys" => serde_json::from_value::<Vec<GpgKey>>(v.clone())
            .unwrap_or_default()
            .into_iter()
            .map(|k| {
                let who = k
                    .emails
                    .first()
                    .map(|e| e.email.clone())
                    .unwrap_or_else(|| "no email".into());
                let signs = if k.can_sign.unwrap_or(false) {
                    "can sign"
                } else {
                    "cannot sign"
                };
                (k.key_id, format!("{who} \u{b7} {signs}"))
            })
            .collect(),
        _ => Vec::new(),
    }
}

impl Screen for Keys {
    fn title(&self) -> String {
        "keys".into()
    }

    fn focus(&mut self, sel: usize) {
        self.sel = sel;
    }

    fn tick(&mut self) -> Tick {
        // First tick after the terminal comes back from `gh auth refresh`.
        if self.reauthorised {
            self.reauthorised = false;
            self.refresh_all();
            return Tick::Changed;
        }
        let now = self.fetch.epoch();
        if now != self.epoch_seen {
            self.epoch_seen = now;
            self.sync();
            return Tick::Changed;
        }
        if self.fetch.pending() {
            return Tick::Wake(std::time::Duration::from_millis(100));
        }
        Tick::Idle
    }

    fn rows(&mut self) -> Vec<Row> {
        let mut rows = Vec::new();
        for (l, lane) in self.lanes.iter().enumerate() {
            let (detail, badge) = match &lane.state {
                LaneState::Waiting => ("asking\u{2026}".to_string(), None),
                LaneState::Items(items) => (
                    match items.len() {
                        0 => "none".to_string(),
                        1 => "1".to_string(),
                        n => n.to_string(),
                    },
                    None,
                ),
                // Badged rather than shown as a count, because the one thing
                // this row must not look like is an answer.
                LaneState::Denied(_) => (String::new(), Some(("scope", idx::YEL))),
                LaneState::Failed(_) => (String::new(), Some(("error", idx::RED))),
            };
            let mut r = Row::leaf(lane.name);
            r.group = true;
            r.expanded = self.open[l];
            let mut r = r.detail(detail);
            if let Some((t, c)) = badge {
                r = r.badged(t, c);
            }
            rows.push(r);
            if self.open[l] {
                match &lane.state {
                    LaneState::Items(items) if !items.is_empty() => {
                        for (label, detail) in items {
                            let mut r = Row::leaf(label);
                            r.depth = 1;
                            rows.push(r.detail(detail));
                        }
                    }
                    LaneState::Items(_) => {
                        let mut r = Row::leaf("none on this account");
                        r.depth = 1;
                        rows.push(r);
                    }
                    LaneState::Denied(d) => {
                        let mut r = Row::leaf(format!("needs {}", d.suggest));
                        r.depth = 1;
                        rows.push(r.detail("enter to authorise it"));
                    }
                    LaneState::Failed(_) => {
                        let mut r = Row::leaf("could not read");
                        r.depth = 1;
                        rows.push(r);
                    }
                    LaneState::Waiting => {
                        let mut r = Row::leaf("\u{2026}");
                        r.depth = 1;
                        rows.push(r);
                    }
                }
            }
            rows.push(Row::spacer());
        }
        rows
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = Vec::new();
        let l = match self.at(sel) {
            At::Lane(l) | At::Item(l) => l,
            At::Nothing => return Pane { image: None, lines },
        };
        let lane = &self.lanes[l];
        lines.push(format!("{BOLD}{}{OFF}", lane.name));
        lines.push(format!("{GRY}GET /{}{OFF}", lane.path));
        lines.push(crate::paint::rule(cols));
        match &lane.state {
            LaneState::Waiting => lines.push(format!("{DIM}asking github\u{2026}{OFF}")),
            LaneState::Items(items) if items.is_empty() => {
                lines.push("This account has none.".into());
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}And the token CAN see them, so this is an answer{OFF}"
                ));
                lines.push(format!("{DIM}rather than a refusal.{OFF}"));
            }
            LaneState::Items(items) => {
                for (label, detail) in items {
                    lines.push(format!("{PUR}{label}{OFF}"));
                    lines.push(format!("  {GRY}{detail}{OFF}"));
                }
            }
            LaneState::Denied(d) => {
                lines.push(format!("{YEL}Your token cannot read this.{OFF}"));
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}GitHub answers 404 here rather than 403, so an{OFF}"
                ));
                lines.push(format!(
                    "{DIM}honest-looking \"none\" would be wrong -- hence this{OFF}"
                ));
                lines.push(format!("{DIM}page instead.{OFF}"));
                lines.push(String::new());
                lines.push(format!("{GRY}the endpoint accepts any of:{OFF}"));
                for s in &d.accepted {
                    let mark = if *s == d.suggest { ORG } else { DIM };
                    lines.push(format!("  {mark}{s}{OFF}"));
                }
                lines.push(String::new());
                lines.push(format!("{BOLD}Run this:{OFF}"));
                lines.push(format!("  {ORG}{}{OFF}", d.fix()));
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}The narrowest of the three, because this screen only{OFF}"
                ));
                lines.push(format!(
                    "{DIM}reads. Creating keys will ask for write: when it{OFF}"
                ));
                lines.push(format!("{DIM}exists.{OFF}"));
            }
            LaneState::Failed(e) => {
                lines.push(format!("{RED}{e}{OFF}"));
            }
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        // Enter on the row that says what is missing RUNS the thing that fixes
        // it. `gh auth refresh` is interactive -- it prints a one-time code and
        // waits while you paste it into a browser -- so it needs the real tty,
        // which is exactly what `Flow::Detach` hands it. It is also
        // self-confirming: gh says what it is about to do and waits for a
        // keypress, so there is nothing for this screen to ask first.
        if let At::Item(l) = self.at(sel) {
            if let LaneState::Denied(d) = &self.lanes[l].state {
                if matches!(action, Action::Activate | Action::Open) {
                    self.reauthorised = true;
                    return Flow::Detach(vec![
                        "gh".into(),
                        "auth".into(),
                        "refresh".into(),
                        "-h".into(),
                        "github.com".into(),
                        "-s".into(),
                        d.suggest.clone(),
                    ]);
                }
            }
        }
        match (action, self.at(sel)) {
            (Action::Activate | Action::Open, At::Lane(l)) => {
                self.open[l] = !self.open[l];
                Flow::Dirty
            }
            (Action::Close, At::Lane(l)) => {
                self.open[l] = false;
                Flow::Dirty
            }
            (Action::Key('r'), _) => {
                self.refresh_all();
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        match self.at(self.sel) {
            At::Lane(_) => "enter open/close \u{b7} r refresh".into(),
            At::Item(l) if matches!(self.lanes[l].state, LaneState::Denied(_)) => {
                "enter authorises the scope \u{b7} r refresh".into()
            }
            _ => "r refresh".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ssh_key_row_says_its_type_and_enough_to_tell_two_apart() {
        let v: serde_json::Value = serde_json::from_str(
            r#"[{"id":1,"key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabcdefgh","title":"laptop"},
                {"id":2,"key":"ssh-rsa AAAAB3NzaC1yc2EAAAADzzzzzzzz","title":""}]"#,
        )
        .expect("parses");
        let rows = render_lane("user/keys", &v);
        assert_eq!(rows[0].0, "laptop");
        assert!(rows[0].1.starts_with("ssh-ed25519"));
        assert!(rows[0].1.contains("abcdefgh"), "{:?}", rows[0].1);
        // An untitled key still needs a label, or the row is blank.
        assert_eq!(rows[1].0, "key 2");
    }

    #[test]
    fn a_gpg_row_names_the_email_it_covers() {
        let v: serde_json::Value = serde_json::from_str(
            r#"[{"key_id":"ABC123","can_sign":true,"emails":[{"email":"me@example.com"}]}]"#,
        )
        .expect("parses");
        let rows = render_lane("user/gpg_keys", &v);
        assert_eq!(rows[0].0, "ABC123");
        assert!(rows[0].1.contains("me@example.com"));
        assert!(rows[0].1.contains("can sign"));
    }

    /// A GPG key with no email attached must not panic or render blank.
    #[test]
    fn a_gpg_key_with_no_email_still_renders() {
        let v: serde_json::Value =
            serde_json::from_str(r#"[{"key_id":"NOEMAIL","emails":[]}]"#).expect("parses");
        let rows = render_lane("user/gpg_keys", &v);
        assert!(rows[0].1.contains("no email"));
        assert!(rows[0].1.contains("cannot sign"));
    }
}
