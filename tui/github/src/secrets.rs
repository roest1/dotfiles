//! Secrets: the repository's, and each environment's, in one list.
//!
//! The one screen in this program whose subject cannot be read. GitHub
//! encrypts a secret's value on the way in and never gives it back -- not to
//! the API, not to `gh`, not to the Actions log -- so there is nothing for a
//! pane to show except the name, when it last changed, and how to use it. That
//! is the whole screen, and it is why there is no preview worth prefetching.
//!
//! ## Why the environments are groups rather than a second screen
//!
//! An environment secret IS a secret; the environment is just where it lives.
//! The fzf screen already listed both in one list with a glyph to tell them
//! apart, because the question you arrive with is "is `DEPLOY_TOKEN` set
//! anywhere" rather than "list the staging ones". Groups keep that and gain
//! two things the flat list could not have: `/` narrows across every scope at
//! once, and the scope of a NEW secret is decided by which group you are
//! standing in rather than by a dialog asking where it should live.
//!
//! ## Setting a value needs no text widget, and must not have one
//!
//! `gh secret set NAME` reads the value from the terminal with echo off and
//! encrypts it locally before it leaves the machine. `Flow::Detach` hands it
//! the real tty, so the value never passes through this process, is never in a
//! `String` here, and cannot end up in a redraw. A field in this program would
//! be strictly worse at the only part that matters.
//!
//! The NAME is asked for here, because `gh` takes it as an argument rather
//! than prompting for it. It is passed as typed: GitHub treats secret names
//! case-insensitively, so the upper-casing the bash version did was a
//! convention rather than a requirement, and silently rewriting what someone
//! typed is not a thing to do on their behalf. What is checked is the part
//! GitHub will refuse -- the character set, and the reserved `GITHUB_` prefix
//! -- because finding that out from a round trip is worse than being told.

use std::sync::Arc;
use std::time::{Duration, Instant};

use reticle::{nav::Action, Flow, Pane, Row, Screen, Tick};
use serde::Deserialize;

use crate::gh::{Fetcher, Got, Req};
use crate::menu::{Act, Item, Menu};
use crate::paint::{idx, BOLD, DIM, GRY, OFF, ORG, PUR, RED};
use crate::time;

const IN_FLIGHT: Duration = Duration::from_millis(100);

/// How long the list stays good for. The same sixty seconds the fzf screen
/// cached it for, and for the same reason: the only thing that changes a
/// secret is you, so this is about catching up after a `set` rather than about
/// watching anything.
const LIST_EVERY: Duration = Duration::from_secs(60);

/// What `gh secret list --json` hands back.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Secret {
    name: String,
    #[serde(default)]
    updated_at: Option<String>,
}

/// One group: the repository, or one environment.
struct Lane {
    /// `None` is the repository itself.
    env: Option<String>,
    secrets: Vec<Secret>,
    error: Option<String>,
    waiting: bool,
}

impl Lane {
    fn title(&self) -> String {
        match &self.env {
            None => "\u{1f511} repository".into(),
            Some(e) => format!("\u{1f30d} {e}"),
        }
    }
}

/// Where the cursor is, derived from the rows rather than remembered.
#[derive(Debug, PartialEq, Eq)]
enum At {
    Nothing,
    Head(usize),
    Secret(usize, usize),
    New(usize),
}

pub struct Secrets {
    repo: String,
    fetch: Arc<Fetcher>,
    lanes: Vec<Lane>,
    open: Vec<bool>,
    epoch_seen: u64,
    asked: Instant,
    /// The lane a pending name belongs to, so the answer knows its scope.
    asking: Option<usize>,
    status: String,
    sel: usize,
}

/// The environments list, shared with the Environments screen -- same key, so
/// whichever tab is opened first pays for it.
pub fn envs_req(repo: &str) -> Req {
    Req::Json {
        path: format!("repos/{repo}/environments?per_page=100"),
    }
}

pub(crate) fn list_req(repo: &str, env: Option<&str>) -> Req {
    let mut args = vec![
        "secret".to_string(),
        "list".into(),
        "--repo".into(),
        repo.to_string(),
    ];
    if let Some(e) = env {
        args.push("--env".into());
        args.push(e.to_string());
    }
    args.push("--json".into());
    args.push("name,updatedAt".into());
    Req::Cmd { args }
}

/// What GitHub will accept as a secret name.
///
/// Checked here rather than left to the round trip, because the answer is
/// deterministic and the alternative is typing a name, handing over the
/// terminal, typing a value, and only then being told.
fn bad_name(name: &str) -> Option<&'static str> {
    let mut chars = name.chars();
    match chars.next() {
        None => return Some("a secret needs a name"),
        Some(c) if !c.is_ascii_alphabetic() && c != '_' => {
            return Some("a name starts with a letter or an underscore")
        }
        Some(_) => {}
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Some("letters, digits and underscores only");
    }
    // GitHub reserves the prefix for the variables it sets itself.
    if name.len() >= 7 && name[..7].eq_ignore_ascii_case("GITHUB_") {
        return Some("GITHUB_ is reserved by GitHub");
    }
    None
}

impl Secrets {
    pub fn open(repo: &str, fetch: Arc<Fetcher>) -> Self {
        fetch.request(list_req(repo, None));
        fetch.request(envs_req(repo));
        Self {
            repo: repo.to_string(),
            fetch,
            lanes: vec![Lane {
                env: None,
                secrets: Vec::new(),
                error: None,
                waiting: true,
            }],
            open: vec![true],
            epoch_seen: 0,
            asked: Instant::now(),
            asking: None,
            status: String::new(),
            sel: 0,
        }
    }

    /// Read whatever has landed. Lanes appear as the environment list does, so
    /// the repository's secrets are on screen before the environments are
    /// known -- which is the common case, since most repos have none.
    fn sync(&mut self) {
        if let Some(Got::Json(v)) = self.fetch.get(&envs_req(&self.repo)) {
            #[derive(Deserialize)]
            struct EnvNames {
                #[serde(default)]
                environments: Vec<Named>,
            }
            #[derive(Deserialize)]
            struct Named {
                name: String,
            }
            if let Ok(list) = serde_json::from_value::<EnvNames>(v.as_ref().clone()) {
                let mut names: Vec<String> =
                    list.environments.into_iter().map(|e| e.name).collect();
                names.sort_by_key(|n| n.to_lowercase());
                for name in names {
                    if self.lanes.iter().any(|l| l.env.as_deref() == Some(&name)) {
                        continue;
                    }
                    self.fetch.request(list_req(&self.repo, Some(&name)));
                    self.lanes.push(Lane {
                        env: Some(name),
                        secrets: Vec::new(),
                        error: None,
                        waiting: true,
                    });
                    self.open.push(true);
                }
            }
        }
        for lane in &mut self.lanes {
            match self.fetch.get(&list_req(&self.repo, lane.env.as_deref())) {
                Some(Got::Json(v)) => {
                    match serde_json::from_value::<Vec<Secret>>(v.as_ref().clone()) {
                        Ok(mut s) => {
                            s.sort_by_key(|s| s.name.to_lowercase());
                            lane.secrets = s;
                            lane.error = None;
                        }
                        Err(e) => lane.error = Some(format!("unreadable secret list: {e}")),
                    }
                    lane.waiting = false;
                }
                // `gh secret list` is a plain subcommand, so there are no
                // scope headers to read -- gh says on stderr why it could not,
                // and "needs admin" is the usual answer.
                Some(Got::Failed(e)) => {
                    lane.error = Some(e);
                    lane.waiting = false;
                }
                Some(Got::Denied(d)) => {
                    lane.error = Some(d.fix());
                    lane.waiting = false;
                }
                Some(Got::Pending) | None => lane.waiting = true,
                _ => {}
            }
        }
    }

    fn refresh(&mut self) {
        self.fetch.refresh(envs_req(&self.repo));
        for lane in &self.lanes {
            self.fetch
                .refresh(list_req(&self.repo, lane.env.as_deref()));
        }
        self.asked = Instant::now();
    }

    fn at(&self, sel: usize) -> At {
        let mut i = 0;
        for (l, lane) in self.lanes.iter().enumerate() {
            if i == sel {
                return At::Head(l);
            }
            i += 1;
            if self.open[l] {
                for s in 0..lane.secrets.len() {
                    if i == sel {
                        return At::Secret(l, s);
                    }
                    i += 1;
                }
                if i == sel {
                    return At::New(l);
                }
                i += 1;
            }
            i += 1; // the spacer
        }
        At::Nothing
    }

    fn settings_url(&self, sel: usize) -> String {
        match self.at(sel) {
            At::Head(l) | At::Secret(l, _) | At::New(l) => match &self.lanes[l].env {
                Some(_) => format!("https://github.com/{}/settings/environments", self.repo),
                None => format!("https://github.com/{}/settings/secrets/actions", self.repo),
            },
            At::Nothing => format!("https://github.com/{}/settings/secrets/actions", self.repo),
        }
    }

    /// The two things you can do to a secret that exists.
    fn secret_menu(&self, lane: usize, idx: usize) -> Menu {
        let lane = &self.lanes[lane];
        let name = lane.secrets[idx].name.clone();
        let scope = |v: &mut Vec<String>| {
            v.push("--repo".into());
            v.push(self.repo.clone());
            if let Some(e) = &lane.env {
                v.push("--env".into());
                v.push(e.clone());
            }
        };
        let mut set = vec![
            "gh".to_string(),
            "secret".into(),
            "set".into(),
            name.clone(),
        ];
        scope(&mut set);
        let mut del = vec![
            "gh".to_string(),
            "secret".into(),
            "delete".into(),
            name.clone(),
        ];
        scope(&mut del);
        let items = vec![
            // Not a `confirm()`: `gh` stops and asks for the value, which is
            // both the prompt and the chance to back out, and a second
            // question before it would be one too many.
            Item::new("Set a new value", "gh secret set", Act::Run(set)).note(&[
                "gh asks for the value with echo off and encrypts it",
                "before it leaves this machine. Setting it again is the",
                "only way to change one -- the old value is unreadable.",
            ]),
            Item::new("Delete", "gh secret delete", Act::Run(del))
                .danger()
                .note(&[
                    "Any workflow reading it starts failing at the next",
                    "run. The value cannot be recovered or retyped from",
                    "here -- nothing has it.",
                ]),
        ];
        let kind = match &lane.env {
            Some(e) => format!("{e} secret"),
            None => "repository secret".into(),
        };
        Menu::new(kind, name, items)
    }
}

impl Screen for Secrets {
    fn title(&self) -> String {
        "secrets".into()
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
        let waited = self.asked.elapsed();
        if waited >= LIST_EVERY {
            self.refresh();
            return Tick::Wake(IN_FLIGHT);
        }
        Tick::Wake(LIST_EVERY - waited)
    }

    fn rows(&mut self) -> Vec<Row> {
        let mut rows = Vec::new();
        for (l, lane) in self.lanes.iter().enumerate() {
            let mut head = Row::leaf(lane.title());
            head.group = true;
            head.expanded = self.open[l];
            let head = match &lane.error {
                Some(e) => head.detail(e.clone()).badged("!", idx::RED),
                None if lane.waiting => head.detail("asking github\u{2026}"),
                None => head.detail(match lane.secrets.len() {
                    0 => "none".to_string(),
                    n => n.to_string(),
                }),
            };
            rows.push(head);
            if !self.open[l] {
                rows.push(Row::spacer());
                continue;
            }
            for s in &lane.secrets {
                let mut r = Row::leaf(&s.name);
                r.depth = 1;
                let when = s
                    .updated_at
                    .as_deref()
                    .and_then(time::epoch)
                    .map(|t| format!("updated {} ago", time::age((time::now() - t).max(0))))
                    .unwrap_or_default();
                rows.push(r.detail(when));
            }
            // In the group, so the scope of a new secret is wherever the
            // cursor already is. No dialog asks where it should live.
            let mut new = Row::leaf(match &lane.env {
                Some(e) => format!("+ new secret in {e}"),
                None => "+ new repository secret".into(),
            });
            new.depth = 1;
            rows.push(new.detail("gh secret set"));
            rows.push(Row::spacer());
        }
        rows
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = Vec::new();
        let write_only = |lines: &mut Vec<String>| {
            lines.push(format!(
                "{GRY}Values are write-only. GitHub never returns one{OFF}"
            ));
            lines.push(format!(
                "{GRY}-- not to the API, not to the CLI, not to a log.{OFF}"
            ));
        };
        match self.at(sel) {
            At::Nothing => {}
            At::Head(l) => {
                let lane = &self.lanes[l];
                lines.push(format!("{BOLD}{}{OFF}", lane.title()));
                match &lane.env {
                    Some(e) => lines.push(format!(
                        "{GRY}available to a job that declares environment: {e}{OFF}"
                    )),
                    None => {
                        lines.push(format!("{GRY}available to every workflow in the repo{OFF}"))
                    }
                }
                lines.push(crate::paint::rule(cols));
                if let Some(e) = &lane.error {
                    lines.push(format!("{RED}{e}{OFF}"));
                    lines.push(String::new());
                    lines.push(format!(
                        "{DIM}Listing secrets needs admin on the repository.{OFF}"
                    ));
                    return Pane { image: None, lines };
                }
                lines.push(format!("{} here", lane.secrets.len()));
                lines.push(String::new());
                write_only(&mut lines);
            }
            At::Secret(l, s) => {
                let lane = &self.lanes[l];
                let secret = &lane.secrets[s];
                lines.push(format!("{BOLD}{}{OFF}", secret.name));
                match &lane.env {
                    Some(e) => lines.push(format!("{GRY}environment secret \u{b7} {PUR}{e}{OFF}")),
                    None => lines.push(format!("{GRY}repository secret{OFF}")),
                }
                lines.push(crate::paint::rule(cols));
                write_only(&mut lines);
                lines.push(format!(
                    "{GRY}To change one, set it again -- that is the only way.{OFF}"
                ));
                lines.push(String::new());
                lines.push(format!("{DIM}Used in a workflow as{OFF}"));
                lines.push(format!("  {ORG}${{{{ secrets.{} }}}}{OFF}", secret.name));
                if let Some(e) = &lane.env {
                    lines.push(String::new());
                    lines.push(format!(
                        "{DIM}which resolves only in a job that declares{OFF}"
                    ));
                    lines.push(format!("  {ORG}environment: {e}{OFF}"));
                }
            }
            At::New(l) => {
                let lane = &self.lanes[l];
                lines.push(format!("{BOLD}a new secret{OFF}"));
                match &lane.env {
                    Some(e) => lines.push(format!("{GRY}in the {e} environment{OFF}")),
                    None => lines.push(format!("{GRY}on the repository{OFF}")),
                }
                lines.push(crate::paint::rule(cols));
                lines.push(format!(
                    "{DIM}enter asks for the name. Then gh takes the{OFF}"
                ));
                lines.push(format!(
                    "{DIM}terminal and asks for the value with echo{OFF}"
                ));
                lines.push(format!(
                    "{DIM}off, and encrypts it before it leaves this{OFF}"
                ));
                lines.push(format!("{DIM}machine -- so the value never passes{OFF}"));
                lines.push(format!("{DIM}through this program at all.{OFF}"));
                lines.push(String::new());
                lines.push(format!(
                    "{GRY}A name already here replaces that secret's value.{OFF}"
                ));
            }
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        self.status.clear();
        match (action, self.at(sel)) {
            (Action::Activate | Action::Open, At::Head(l)) => {
                self.open[l] = !self.open[l];
                Flow::Dirty
            }
            (Action::Close, At::Head(l)) => {
                self.open[l] = false;
                Flow::Dirty
            }
            (Action::Close, At::Secret(l, _) | At::New(l)) => {
                self.open[l] = false;
                Flow::Dirty
            }
            (Action::Activate, At::Secret(l, s)) => Flow::Push(Box::new(self.secret_menu(l, s))),
            (Action::Activate, At::New(l)) => {
                self.asking = Some(l);
                Flow::Ask {
                    label: match &self.lanes[l].env {
                        Some(e) => format!("name of the new {e} secret"),
                        None => "name of the new repository secret".into(),
                    },
                    initial: String::new(),
                }
            }
            (Action::Key('o'), _) => {
                self.status = crate::browse(&self.settings_url(sel));
                Flow::Dirty
            }
            (Action::Key('r'), _) => {
                self.refresh();
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }

    fn answered(&mut self, text: Option<String>) -> Flow {
        let Some(l) = self.asking.take() else {
            return Flow::Continue;
        };
        let Some(name) = text.map(|t| t.trim().to_string()) else {
            return Flow::Dirty;
        };
        if let Some(why) = bad_name(&name) {
            self.status = why.into();
            return Flow::Dirty;
        }
        let mut argv = vec!["gh".to_string(), "secret".into(), "set".into(), name];
        argv.push("--repo".into());
        argv.push(self.repo.clone());
        if let Some(e) = &self.lanes[l].env {
            argv.push("--env".into());
            argv.push(e.clone());
        }
        // The list will not know about it until it is asked again, and the
        // next tick is within a second of getting the terminal back.
        self.asked = Instant::now() - LIST_EVERY;
        Flow::Detach(argv)
    }

    fn footer(&self) -> String {
        if !self.status.is_empty() {
            return self.status.clone();
        }
        match self.at(self.sel) {
            At::Head(_) => "enter open/close \u{b7} o browser \u{b7} r refresh".into(),
            At::Secret(..) => "enter set or delete \u{b7} o browser \u{b7} r refresh".into(),
            At::New(_) => "enter names it, then gh asks for the value".into(),
            At::Nothing => "o browser \u{b7} r refresh".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> Secrets {
        let mut s = Secrets::open("roest1/dotfiles", Arc::new(Fetcher::new("")));
        s.lanes[0].waiting = false;
        s.lanes[0].secrets = vec![
            Secret {
                name: "STATS_TOKEN".into(),
                updated_at: Some("2026-10-20T00:00:00Z".into()),
            },
            Secret {
                name: "NPM_TOKEN".into(),
                updated_at: None,
            },
        ];
        s.lanes.push(Lane {
            env: Some("staging".into()),
            secrets: vec![Secret {
                name: "DEPLOY_KEY".into(),
                updated_at: None,
            }],
            error: None,
            waiting: false,
        });
        s.open.push(true);
        s
    }

    /// The scope comes from the group the cursor is in, which is the whole
    /// reason the environments are groups: there is no dialog asking where a
    /// new secret should live.
    #[test]
    fn a_new_secret_takes_the_scope_of_the_group_it_is_in() {
        let mut s = screen();
        // repository: head, two secrets, new, spacer -> 0..4
        assert_eq!(s.at(3), At::New(0));
        // staging: head, one secret, new, spacer -> 5..8
        assert_eq!(s.at(7), At::New(1));
        assert!(matches!(s.on_action(Action::Activate, 7), Flow::Ask { .. }));
        match s.answered(Some("DEPLOY_TOKEN".into())) {
            Flow::Detach(argv) => assert_eq!(
                argv,
                vec![
                    "gh",
                    "secret",
                    "set",
                    "DEPLOY_TOKEN",
                    "--repo",
                    "roest1/dotfiles",
                    "--env",
                    "staging"
                ]
            ),
            f => panic!("expected a detach, got {}", flow_name(&f)),
        }
    }

    /// A repository secret gets no `--env`, which is what makes it a
    /// repository secret rather than one in an environment called nothing.
    #[test]
    fn a_repository_secret_is_scoped_to_the_repo_alone() {
        let mut s = screen();
        s.on_action(Action::Activate, 3);
        match s.answered(Some("  NPM_TOKEN  ".into())) {
            Flow::Detach(argv) => {
                assert!(!argv.iter().any(|a| a == "--env"), "{argv:?}");
                assert_eq!(argv[3], "NPM_TOKEN", "trimmed");
            }
            f => panic!("expected a detach, got {}", flow_name(&f)),
        }
    }

    /// Names GitHub will refuse are refused here, where saying so costs
    /// nothing. The alternative is typing a name, handing over the terminal,
    /// typing a VALUE, and being told then.
    #[test]
    fn a_name_github_would_reject_never_reaches_gh() {
        for (name, why) in [
            ("", "needs a name"),
            ("2FA_TOKEN", "starts with"),
            ("MY-TOKEN", "underscores only"),
            ("MY TOKEN", "underscores only"),
            ("GITHUB_TOKEN", "reserved"),
            ("github_token", "reserved"),
        ] {
            let mut s = screen();
            s.on_action(Action::Activate, 3);
            let flow = s.answered(Some(name.to_string()));
            assert!(
                !matches!(flow, Flow::Detach(_)),
                "{name:?} was handed to gh"
            );
            assert!(s.footer().contains(why), "{name:?}: {}", s.footer());
        }
        // And one that is fine.
        let mut s = screen();
        s.on_action(Action::Activate, 3);
        assert!(matches!(
            s.answered(Some("_PRIVATE_2".into())),
            Flow::Detach(_)
        ));
    }

    /// An answer arriving when nothing was asked must not set a secret named
    /// after whatever was typed.
    #[test]
    fn an_unexpected_answer_does_nothing() {
        let mut s = screen();
        assert!(matches!(s.answered(Some("X".into())), Flow::Continue));
    }

    /// A collapsed group hides its secrets AND its new-secret row, so the
    /// positions after it have to move by the whole block.
    #[test]
    fn collapsing_a_group_moves_everything_after_it() {
        let mut s = screen();
        s.on_action(Action::Close, 0);
        assert_eq!(s.at(0), At::Head(0));
        assert_eq!(s.at(1), At::Nothing, "the spacer after the closed group");
        assert_eq!(s.at(2), At::Head(1), "staging moved up from row 5");
        assert_eq!(s.at(3), At::Secret(1, 0));
    }

    /// The rows and the positions are two readings of one list, so they have
    /// to agree -- `at` walking differently from `rows` is how a delete lands
    /// on the wrong secret.
    #[test]
    fn the_rows_and_the_positions_agree() {
        let mut s = screen();
        let rows = s.rows();
        for (i, row) in rows.iter().enumerate() {
            match s.at(i) {
                At::Head(l) => assert_eq!(row.label, s.lanes[l].title()),
                At::Secret(l, x) => assert_eq!(row.label, s.lanes[l].secrets[x].name),
                At::New(_) => assert!(row.label.starts_with("+ new"), "{}", row.label),
                At::Nothing => assert!(!row.selectable, "{} is not a spacer", row.label),
            }
        }
    }

    /// `o` goes to the page that holds what you were looking at: the repo's
    /// Actions secrets, or the environments page for an environment's.
    #[test]
    fn the_browser_key_follows_the_scope() {
        let s = screen();
        assert!(s.settings_url(1).ends_with("/settings/secrets/actions"));
        assert!(s.settings_url(6).ends_with("/settings/environments"));
    }

    /// A lane that could not be listed says so on its own row and leaves the
    /// others alone -- one environment you cannot read is not an empty screen.
    #[test]
    fn one_lane_failing_does_not_empty_the_screen() {
        let mut s = screen();
        s.lanes[1].error = Some("gh: Not Found (HTTP 404)".into());
        s.lanes[1].secrets.clear();
        let rows = s.rows();
        assert!(rows.iter().any(|r| r.label.contains("STATS_TOKEN")));
        let head = rows
            .iter()
            .find(|r| r.label.contains("staging"))
            .expect("head");
        assert_eq!(head.badges.first().map(|b| b.0.as_str()), Some("!"));
    }

    fn flow_name(f: &Flow) -> &'static str {
        match f {
            Flow::Continue => "Continue",
            Flow::Dirty => "Dirty",
            Flow::Push(_) => "Push",
            Flow::Pop => "Pop",
            Flow::Ask { .. } => "Ask",
            Flow::Retarget => "Retarget",
            Flow::Detach(_) => "Detach",
            Flow::Quit => "Quit",
        }
    }
}
