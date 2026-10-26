//! Environments: the deployment gates, and the picker that edits them.
//!
//! An environment is where a workflow deploys TO -- staging, production -- and
//! what it carries is a set of gates: a wait timer, a list of people who have
//! to approve, a rule about which branches may deploy at all, plus its own
//! secrets. The list endpoint returns every one of those, so the whole screen
//! is one call and the pane needs no second round trip for anything except the
//! environment's secrets and its recent deployments.
//!
//! ## Why every change sends the WHOLE environment
//!
//! `PUT /repos/{owner}/{repo}/environments/{name}` is "create or update an
//! environment", and the documentation does not say what happens to a
//! parameter you leave out. That is the entire reason this file composes the
//! complete desired state on every change rather than sending the one field
//! that moved: the bash implementation sent `{wait_timer: n}` alone, so IF
//! omission clears, setting a wait timer silently dropped the required
//! reviewers -- and nobody would find out until a deploy that should have
//! waited for an approval did not.
//!
//! Sending everything makes the question moot. Whatever the semantics, the
//! environment afterwards is what the pane showed plus the one change, and the
//! confirm in `Menu` prints the exact command so it can be read before it
//! runs.
//!
//! `gh api`'s field syntax carries all of it without a shell or a temp file:
//! `-F 'reviewers[][type]=User' -F 'reviewers[][id]=123'` builds an array of
//! objects, one per pair, in order; `-F 'reviewers[]'` sends an empty array;
//! `-F key[sub]=value` nests; and `-F x=null` sends a real JSON null. Verified
//! against `gh api --verbose` before any of this was written.
//!
//! ## Why required reviewers get a picker
//!
//! Because the API wants a numeric user id, which nobody knows and no amount
//! of typing produces. The collaborators endpoint hands back logins WITH ids,
//! so a list to tick is both easier than typing a username and the only shape
//! that can work at all. It also matches the semantics: the field is a SET
//! that the PUT replaces wholesale, so editing it as a set -- pre-ticked with
//! whoever is required now -- is the only way to add a reviewer without
//! dropping the others.

use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use reticle::{nav::Action, Flow, Pane, Row, Screen, Tick};
use serde::Deserialize;

use crate::gh::{Fetcher, Got, Req};
use crate::menu::{Act, Item, Menu};
use crate::paint::{idx, BOLD, DIM, GRN, GRY, OFF, ORG, PUR, RED, YEL};
use crate::runs::urlencode;
use crate::secrets::{envs_req, list_req};
use crate::time;

const IN_FLIGHT: Duration = Duration::from_millis(100);
const LIST_EVERY: Duration = Duration::from_secs(60);

// ─── What the API says about an environment ───────────────────────

#[derive(Debug, Clone, Deserialize)]
struct RawList {
    #[serde(default)]
    environments: Vec<RawEnv>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawEnv {
    name: String,
    #[serde(default)]
    created_at: Option<String>,
    #[serde(default)]
    updated_at: Option<String>,
    #[serde(default)]
    protection_rules: Vec<RawRule>,
    #[serde(default)]
    deployment_branch_policy: Option<RawPolicy>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawRule {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    wait_timer: Option<u64>,
    #[serde(default)]
    prevent_self_review: Option<bool>,
    #[serde(default)]
    reviewers: Vec<RawSlot>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawSlot {
    #[serde(rename = "type", default)]
    kind: Option<String>,
    #[serde(default)]
    reviewer: Option<RawWho>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawWho {
    #[serde(default)]
    id: Option<u64>,
    #[serde(default)]
    login: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    slug: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawPolicy {
    #[serde(default)]
    protected_branches: bool,
    #[serde(default)]
    custom_branch_policies: bool,
}

/// Which branches may deploy here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Policy {
    /// No policy at all, which the API spells as a null object.
    Any,
    Protected,
    Selected,
}

/// One person or team that has to approve.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reviewer {
    pub team: bool,
    pub id: u64,
    pub name: String,
}

impl Reviewer {
    fn key(&self) -> (bool, u64) {
        (self.team, self.id)
    }

    fn kind(&self) -> &'static str {
        if self.team {
            "Team"
        } else {
            "User"
        }
    }
}

/// An environment, flattened out of the three shapes the API splits it into.
#[derive(Debug, Clone)]
pub struct Env {
    pub name: String,
    created_at: Option<String>,
    updated_at: Option<String>,
    pub wait_timer: u64,
    pub prevent_self_review: bool,
    pub reviewers: Vec<Reviewer>,
    pub policy: Policy,
}

impl Env {
    fn gates(&self) -> usize {
        usize::from(self.wait_timer > 0)
            + usize::from(!self.reviewers.is_empty())
            + usize::from(self.policy != Policy::Any)
    }
}

fn read_list(v: &serde_json::Value) -> Vec<Env> {
    let Ok(list) = serde_json::from_value::<RawList>(v.clone()) else {
        return Vec::new();
    };
    list.environments
        .into_iter()
        .map(|e| {
            let mut wait_timer = 0;
            let mut prevent_self_review = false;
            let mut reviewers = Vec::new();
            for rule in &e.protection_rules {
                match rule.kind.as_str() {
                    "wait_timer" => wait_timer = rule.wait_timer.unwrap_or(0),
                    "required_reviewers" => {
                        prevent_self_review = rule.prevent_self_review.unwrap_or(false);
                        for slot in &rule.reviewers {
                            let team = slot.kind.as_deref() == Some("Team");
                            let Some(who) = &slot.reviewer else { continue };
                            let Some(id) = who.id else { continue };
                            // A user carries `login`; a team carries `slug`
                            // and `name`. Either way there is one string
                            // worth printing.
                            let name = who
                                .login
                                .clone()
                                .or_else(|| who.slug.clone())
                                .or_else(|| who.name.clone())
                                .unwrap_or_else(|| id.to_string());
                            reviewers.push(Reviewer { team, id, name });
                        }
                    }
                    _ => {}
                }
            }
            let policy = match &e.deployment_branch_policy {
                None => Policy::Any,
                Some(p) if p.custom_branch_policies => Policy::Selected,
                Some(p) if p.protected_branches => Policy::Protected,
                Some(_) => Policy::Any,
            };
            Env {
                name: e.name,
                created_at: e.created_at,
                updated_at: e.updated_at,
                wait_timer,
                prevent_self_review,
                reviewers,
                policy,
            }
        })
        .collect()
}

/// The complete environment, as one `gh api` command line.
///
/// `wait` is a string so a menu item can pass `{}` and let `Act::Prompt` fill
/// in what was typed -- the template and the literal share one builder, which
/// is what keeps the two from drifting apart.
///
/// `had_reviewers` is what the environment requires NOW: an empty `reviewers`
/// means "nobody", and saying so needs the explicit empty array -- but only
/// when there was somebody to remove, since sending `reviewers[]` to an
/// environment that has none is a change asking to be a no-op.
pub fn put_argv(
    repo: &str,
    env: &str,
    wait: &str,
    prevent: bool,
    reviewers: &[Reviewer],
    had_reviewers: bool,
    policy: Policy,
) -> Vec<String> {
    let mut argv = vec![
        "gh".to_string(),
        "api".into(),
        "-X".into(),
        "PUT".into(),
        format!("repos/{repo}/environments/{}", urlencode(env)),
        "--silent".into(),
        "-F".into(),
        format!("wait_timer={wait}"),
    ];
    if reviewers.is_empty() {
        if had_reviewers {
            argv.push("-F".into());
            argv.push("reviewers[]".into());
        }
    } else {
        // Only meaningful alongside a reviewer list, and sending it without
        // one is asking the API to validate a rule that does not exist.
        argv.push("-F".into());
        argv.push(format!("prevent_self_review={prevent}"));
        for r in reviewers {
            argv.push("-F".into());
            argv.push(format!("reviewers[][type]={}", r.kind()));
            argv.push("-F".into());
            argv.push(format!("reviewers[][id]={}", r.id));
        }
    }
    match policy {
        Policy::Any => {
            argv.push("-F".into());
            argv.push("deployment_branch_policy=null".into());
        }
        Policy::Protected | Policy::Selected => {
            let custom = policy == Policy::Selected;
            argv.push("-F".into());
            argv.push(format!(
                "deployment_branch_policy[protected_branches]={}",
                !custom
            ));
            argv.push("-F".into());
            argv.push(format!(
                "deployment_branch_policy[custom_branch_policies]={custom}"
            ));
        }
    }
    argv
}

// ─── The list ─────────────────────────────────────────────────────

#[derive(Debug, PartialEq, Eq)]
enum At {
    Nothing,
    Env(usize),
    New,
}

/// Three answers, not two.
///
/// "Not yet" and "cannot" want different lines, and collapsing them is how a
/// pane sits on `asking github\u{2026}` forever for a repo you are only allowed
/// to read -- which is what it did on the first pass.
enum Maybe<T> {
    Waiting,
    Got(T),
    Cannot(String),
}

impl<T> Maybe<T> {
    fn of<F>(got: Option<Got>, parse: F) -> Self
    where
        F: FnOnce(serde_json::Value) -> Result<T, serde_json::Error>,
    {
        match got {
            Some(Got::Json(v)) => match parse(v.as_ref().clone()) {
                Ok(t) => Maybe::Got(t),
                Err(e) => Maybe::Cannot(format!("unreadable: {e}")),
            },
            Some(Got::Denied(d)) => Maybe::Cannot(d.fix()),
            Some(Got::Failed(e)) => Maybe::Cannot(e),
            _ => Maybe::Waiting,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
struct Deployment {
    #[serde(default)]
    created_at: Option<String>,
    #[serde(rename = "ref", default)]
    reference: Option<String>,
    #[serde(default)]
    creator: Option<RawWho>,
}

pub struct Envs {
    repo: String,
    fetch: Arc<Fetcher>,
    envs: Vec<Env>,
    epoch_seen: u64,
    asked: Instant,
    error: Option<String>,
    asking: bool,
    status: String,
    sel: usize,
}

fn deploys_req(repo: &str, env: &str) -> Req {
    Req::Json {
        path: format!(
            "repos/{repo}/deployments?environment={}&per_page=5",
            urlencode(env)
        ),
    }
}

impl Envs {
    pub fn open(repo: &str, fetch: Arc<Fetcher>) -> Self {
        fetch.request(envs_req(repo));
        Self {
            repo: repo.to_string(),
            fetch,
            envs: Vec::new(),
            epoch_seen: 0,
            asked: Instant::now(),
            error: None,
            asking: false,
            status: String::new(),
            sel: 0,
        }
    }

    fn sync(&mut self) {
        match self.fetch.get(&envs_req(&self.repo)) {
            Some(Got::Json(v)) => {
                self.envs = read_list(&v);
                self.error = None;
            }
            Some(Got::Denied(d)) => self.error = Some(d.fix()),
            Some(Got::Failed(e)) => self.error = Some(e),
            _ => {}
        }
        self.want_detail(self.sel);
    }

    /// The pane's two extra calls, for the row under the cursor and the next
    /// one -- the same one-neighbour rule the run list uses.
    fn want_detail(&self, sel: usize) {
        for i in [sel, sel + 1] {
            if let Some(e) = self.envs.get(i) {
                self.fetch.request(list_req(&self.repo, Some(&e.name)));
                self.fetch.request(deploys_req(&self.repo, &e.name));
            }
        }
    }

    fn refresh(&mut self) {
        self.fetch.refresh(envs_req(&self.repo));
        for e in &self.envs {
            self.fetch.refresh(list_req(&self.repo, Some(&e.name)));
            self.fetch.refresh(deploys_req(&self.repo, &e.name));
        }
        self.asked = Instant::now();
    }

    fn at(&self, sel: usize) -> At {
        if sel < self.envs.len() {
            return At::Env(sel);
        }
        // An empty list still draws ONE row -- the "no environments yet"
        // placeholder -- so the rows below it are where a single environment
        // would have put them. Reading this off `envs.len()` alone put the
        // new-environment row one position too high on exactly the repo where
        // it is the only thing you can do.
        let listed = self.envs.len().max(1);
        if sel == listed + 1 {
            return At::New;
        }
        At::Nothing
    }

    fn put(&self, e: &Env, wait: &str, prevent: bool, reviewers: &[Reviewer]) -> Vec<String> {
        put_argv(
            &self.repo,
            &e.name,
            wait,
            prevent,
            reviewers,
            !e.reviewers.is_empty(),
            e.policy,
        )
    }

    fn env_menu(&self, i: usize) -> Menu {
        let e = &self.envs[i];
        let mut items = vec![Item::new(
            "Set wait timer",
            "gh api -X PUT",
            Act::Prompt {
                label: "minutes to wait before deploying (0 disables)".into(),
                initial: e.wait_timer.to_string(),
                argv: self.put(e, "{}", e.prevent_self_review, &e.reviewers),
            },
        )
        .confirm()
        .note(&[
            "Every job targeting this environment waits that long",
            "before it starts, and anyone can cancel it meanwhile.",
            "The whole environment is sent, so its reviewers and",
            "branch policy are unchanged.",
        ])];
        // Only means anything alongside a reviewer list.
        if !e.reviewers.is_empty() {
            let on = !e.prevent_self_review;
            items.push(
                Item::new(
                    if on {
                        "Stop the author approving their own deploy"
                    } else {
                        "Let the author approve their own deploy"
                    },
                    "gh api -X PUT prevent_self_review",
                    Act::Run(self.put(e, &e.wait_timer.to_string(), on, &e.reviewers)),
                )
                .confirm(),
            );
        }
        items.push(Item::new(
            "Required reviewers",
            format!(
                "{} now",
                match e.reviewers.len() {
                    0 => "nobody".to_string(),
                    n => n.to_string(),
                }
            ),
            Act::Open(Box::new(Reviewers::open(
                &self.repo,
                e,
                Arc::clone(&self.fetch),
            ))),
        ));
        items.push(Item::new(
            "Set a secret here",
            "gh secret set --env",
            Act::Prompt {
                label: format!("name of the new {} secret", e.name),
                initial: String::new(),
                argv: vec![
                    "gh".into(),
                    "secret".into(),
                    "set".into(),
                    "{}".into(),
                    "--repo".into(),
                    self.repo.clone(),
                    "--env".into(),
                    e.name.clone(),
                ],
            },
        ));
        items.push(
            Item::new(
                "Delete environment",
                "gh api -X DELETE",
                Act::Run(vec![
                    "gh".into(),
                    "api".into(),
                    "-X".into(),
                    "DELETE".into(),
                    format!("repos/{}/environments/{}", self.repo, urlencode(&e.name)),
                    "--silent".into(),
                ]),
            )
            .danger()
            .note(&[
                "Takes every secret in it with it, and any workflow",
                "naming this environment fails until it exists again.",
            ]),
        );
        Menu::new("environment", e.name.clone(), items)
    }

    fn secrets_of(&self, env: &str) -> Maybe<Vec<String>> {
        #[derive(Deserialize)]
        struct Named {
            name: String,
        }
        Maybe::of(self.fetch.get(&list_req(&self.repo, Some(env))), |v| {
            serde_json::from_value::<Vec<Named>>(v).map(|v| v.into_iter().map(|n| n.name).collect())
        })
    }

    fn deploys_of(&self, env: &str) -> Maybe<Vec<Deployment>> {
        Maybe::of(
            self.fetch.get(&deploys_req(&self.repo, env)),
            serde_json::from_value,
        )
    }
}

impl Screen for Envs {
    fn title(&self) -> String {
        "environments".into()
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
        let waited = self.asked.elapsed();
        if waited >= LIST_EVERY {
            self.refresh();
            return Tick::Wake(IN_FLIGHT);
        }
        Tick::Wake(LIST_EVERY - waited)
    }

    fn rows(&mut self) -> Vec<Row> {
        let mut rows = Vec::new();
        for e in &self.envs {
            let detail = e
                .created_at
                .as_deref()
                .and_then(time::epoch)
                .map(|t| format!("created {} ago", time::age((time::now() - t).max(0))))
                .unwrap_or_default();
            let mut r = Row::leaf(format!("\u{1f30d} {}", e.name)).detail(detail);
            // Rightmost first, so these read left to right as timer, people,
            // branches -- loosest gate last.
            if e.policy != Policy::Any {
                r = r.badged("\u{1f33f}", idx::GRY);
            }
            if !e.reviewers.is_empty() {
                r = r.badged(format!("\u{1f464} {}", e.reviewers.len()), idx::GRN);
            }
            if e.wait_timer > 0 {
                r = r.badged(format!("\u{23f1} {}m", e.wait_timer), idx::YEL);
            }
            if e.gates() == 0 {
                r = r.badged("no gates", idx::DIM);
            }
            rows.push(r);
        }
        if self.envs.is_empty() {
            rows.push(
                Row::leaf(match &self.error {
                    Some(e) => format!("could not list environments \u{2014} {e}"),
                    None if self.fetch.pending() => "asking github\u{2026}".into(),
                    None => "no environments yet".into(),
                })
                .detail(String::new()),
            );
        }
        rows.push(Row::spacer());
        rows.push(Row::leaf("+ new environment").detail("gh api -X PUT"));
        rows
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = Vec::new();
        match self.at(sel) {
            At::New => {
                lines.push(format!("{BOLD}a new environment{OFF}"));
                lines.push(format!("{GRY}a place to deploy to{OFF}"));
                lines.push(crate::paint::rule(cols));
                lines.push(format!(
                    "{DIM}It arrives with no gates: any branch may deploy{OFF}"
                ));
                lines.push(format!(
                    "{DIM}to it and no approval is needed. Add those after,{OFF}"
                ));
                lines.push(format!("{DIM}from its own menu.{OFF}"));
                lines.push(String::new());
                lines.push(format!("{DIM}Creating one needs admin on the repo.{OFF}"));
            }
            At::Nothing => {
                if let Some(e) = &self.error {
                    lines.push(format!("{RED}{e}{OFF}"));
                } else if self.envs.is_empty() {
                    lines.push(format!("{GRY}Nothing deploys from here yet.{OFF}"));
                    lines.push(String::new());
                    lines.push(format!(
                        "{DIM}An environment is a named deployment target with{OFF}"
                    ));
                    lines.push(format!(
                        "{DIM}its own secrets, its own approvals and its own{OFF}"
                    ));
                    lines.push(format!("{DIM}rule about which branches may reach it.{OFF}"));
                }
            }
            At::Env(i) => {
                let e = &self.envs[i];
                lines.push(format!("{BOLD}\u{1f30d} {}{OFF}", e.name));
                let stamp = |s: &Option<String>| {
                    s.as_deref()
                        .map(|t| t.chars().take(10).collect::<String>())
                        .unwrap_or_else(|| "?".into())
                };
                lines.push(format!(
                    "{DIM}created {} \u{b7} updated {}{OFF}",
                    stamp(&e.created_at),
                    stamp(&e.updated_at)
                ));
                lines.push(crate::paint::rule(cols));
                lines.push(format!("{GRY}gates{OFF}"));
                if e.gates() == 0 {
                    lines.push(format!(
                        "{DIM}   none \u{2014} any job may deploy here{OFF}"
                    ));
                }
                if e.wait_timer > 0 {
                    lines.push(format!(
                        "   {YEL}\u{23f1}{OFF}  wait {} min before deploying",
                        e.wait_timer
                    ));
                }
                if !e.reviewers.is_empty() {
                    let who: Vec<String> = e
                        .reviewers
                        .iter()
                        .map(|r| {
                            if r.team {
                                format!("{} (team)", r.name)
                            } else {
                                r.name.clone()
                            }
                        })
                        .collect();
                    lines.push(format!(
                        "   {GRN}\u{1f464}{OFF} {}{}",
                        who.join(", "),
                        if e.prevent_self_review {
                            " \u{b7} not the author"
                        } else {
                            ""
                        }
                    ));
                }
                lines.push(match e.policy {
                    Policy::Any => format!("   {DIM}\u{1f33f} any branch may deploy{OFF}"),
                    Policy::Protected => {
                        "   \u{1f33f} only protected branches may deploy".to_string()
                    }
                    Policy::Selected => {
                        "   \u{1f33f} only selected branches and tags may deploy".to_string()
                    }
                });
                lines.push(String::new());
                lines.push(format!("{GRY}secrets{OFF}"));
                match self.secrets_of(&e.name) {
                    Maybe::Waiting => lines.push(format!("{DIM}   asking github\u{2026}{OFF}")),
                    // Listing an environment's secrets needs admin, and an
                    // honest-looking "none" on a repo you only read would be
                    // the same lie `Got::Denied` exists to stop telling.
                    Maybe::Cannot(why) => lines.push(format!("   {DIM}{why}{OFF}")),
                    Maybe::Got(s) if s.is_empty() => lines.push(format!("{DIM}   none{OFF}")),
                    Maybe::Got(s) => {
                        for name in s {
                            lines.push(format!("   \u{1f511} {name}"));
                        }
                    }
                }
                lines.push(String::new());
                lines.push(format!("{GRY}recent deployments{OFF}"));
                match self.deploys_of(&e.name) {
                    Maybe::Waiting => lines.push(format!("{DIM}   asking github\u{2026}{OFF}")),
                    Maybe::Cannot(why) => lines.push(format!("   {DIM}{why}{OFF}")),
                    Maybe::Got(d) if d.is_empty() => lines.push(format!("{DIM}   none{OFF}")),
                    Maybe::Got(d) => {
                        for dep in d {
                            let when = dep
                                .created_at
                                .as_deref()
                                .map(|t| t.chars().take(16).collect::<String>().replace('T', " "))
                                .unwrap_or_else(|| "?".into());
                            let who = dep
                                .creator
                                .as_ref()
                                .and_then(|c| c.login.clone())
                                .unwrap_or_else(|| "?".into());
                            lines.push(format!(
                                "   {when} {DIM}{} \u{b7} {who}{OFF}",
                                dep.reference.unwrap_or_default()
                            ));
                        }
                    }
                }
                lines.push(String::new());
                lines.push(format!(
                    "{ORG}enter{OFF} {DIM}for its gates and secrets{OFF}"
                ));
            }
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        self.status.clear();
        match (action, self.at(sel)) {
            (Action::Activate, At::Env(i)) => Flow::Push(Box::new(self.env_menu(i))),
            (Action::Activate, At::New) => {
                self.asking = true;
                Flow::Ask {
                    label: "name of the new environment".into(),
                    initial: String::new(),
                }
            }
            (Action::Key('o'), _) => {
                self.status = crate::browse(&format!(
                    "https://github.com/{}/settings/environments",
                    self.repo
                ));
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
        if !std::mem::take(&mut self.asking) {
            return Flow::Continue;
        }
        let Some(name) = text.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) else {
            return Flow::Dirty;
        };
        self.asked = Instant::now() - LIST_EVERY;
        // A bare PUT with no fields creates it with no gates at all, which is
        // what the GitHub UI's "New environment" does too.
        Flow::Detach(vec![
            "gh".into(),
            "api".into(),
            "-X".into(),
            "PUT".into(),
            format!("repos/{}/environments/{}", self.repo, urlencode(&name)),
            "--silent".into(),
        ])
    }

    fn footer(&self) -> String {
        if !self.status.is_empty() {
            return self.status.clone();
        }
        match self.at(self.sel) {
            At::Env(_) => "enter its menu \u{b7} o browser \u{b7} r refresh".into(),
            At::New => "enter names it \u{b7} needs admin on the repo".into(),
            At::Nothing => "o browser \u{b7} r refresh".into(),
        }
    }
}

// ─── The reviewer picker ──────────────────────────────────────────

fn collab_req(repo: &str) -> Req {
    Req::Json {
        path: format!("repos/{repo}/collaborators?per_page=100"),
    }
}

#[derive(Debug, Clone, Deserialize)]
struct Collaborator {
    login: String,
    id: u64,
}

/// Who has to approve a deploy to one environment.
///
/// A set, edited as a set: pre-ticked with whoever is required now, because
/// the PUT replaces the list and adding one person by typing a name would
/// drop everyone else.
pub struct Reviewers {
    repo: String,
    env: String,
    wait_timer: u64,
    prevent: bool,
    policy: Policy,
    had: Vec<Reviewer>,
    fetch: Arc<Fetcher>,
    people: Vec<Reviewer>,
    ticked: BTreeSet<(bool, u64)>,
    epoch_seen: u64,
    error: Option<String>,
    sel: usize,
}

impl Reviewers {
    pub fn open(repo: &str, env: &Env, fetch: Arc<Fetcher>) -> Self {
        fetch.request(collab_req(repo));
        let mut me = Self {
            repo: repo.to_string(),
            env: env.name.clone(),
            wait_timer: env.wait_timer,
            prevent: env.prevent_self_review,
            policy: env.policy,
            had: env.reviewers.clone(),
            fetch,
            // Whoever is required now is a candidate whether or not they are
            // a collaborator -- a team never will be, and an outside reviewer
            // would otherwise vanish from the list that replaces them.
            people: env.reviewers.clone(),
            ticked: env.reviewers.iter().map(|r| r.key()).collect(),
            epoch_seen: 0,
            error: None,
            sel: 0,
        };
        me.sort();
        me
    }

    fn sort(&mut self) {
        self.people.sort_by_key(|r| (r.team, r.name.to_lowercase()));
    }

    fn sync(&mut self) {
        match self.fetch.get(&collab_req(&self.repo)) {
            Some(Got::Json(v)) => {
                match serde_json::from_value::<Vec<Collaborator>>(v.as_ref().clone()) {
                    Ok(list) => {
                        for c in list {
                            let r = Reviewer {
                                team: false,
                                id: c.id,
                                name: c.login,
                            };
                            if !self.people.iter().any(|p| p.key() == r.key()) {
                                self.people.push(r);
                            }
                        }
                        self.sort();
                        self.error = None;
                    }
                    Err(e) => self.error = Some(format!("unreadable collaborator list: {e}")),
                }
            }
            Some(Got::Denied(d)) => self.error = Some(d.fix()),
            Some(Got::Failed(e)) => self.error = Some(e),
            _ => {}
        }
    }

    fn chosen(&self) -> Vec<Reviewer> {
        self.people
            .iter()
            .filter(|p| self.ticked.contains(&p.key()))
            .cloned()
            .collect()
    }

    /// The one item worth confirming, with the whole command in it.
    fn apply_menu(&self) -> Menu {
        let chosen = self.chosen();
        let argv = put_argv(
            &self.repo,
            &self.env,
            &self.wait_timer.to_string(),
            self.prevent,
            &chosen,
            !self.had.is_empty(),
            self.policy,
        );
        let item = if chosen.is_empty() {
            Item::new(
                "Require nobody",
                "gh api -X PUT reviewers[]",
                Act::Run(argv),
            )
            .danger()
            .note(&[
                "Removes the approval gate entirely. Deploys to this",
                "environment stop waiting for anyone.",
            ])
        } else {
            Item::new(
                match chosen.len() {
                    1 => "Require this 1 reviewer".to_string(),
                    n => format!("Require these {n} reviewers"),
                },
                "gh api -X PUT",
                Act::Run(argv),
            )
            .confirm()
            .note(&[
                "Replaces the reviewer list with exactly the ticked",
                "set. The wait timer and branch policy are sent",
                "unchanged, so nothing else about the environment",
                "moves.",
            ])
        };
        Menu::new("required reviewers", self.env.clone(), vec![item])
    }

    fn at(&self, sel: usize) -> Option<usize> {
        // Row 0 is the apply row; everyone else is offset by it. Anything
        // past the last person is the spacer or the note, and neither is a
        // person -- the cursor cannot reach either, since both are
        // unselectable.
        sel.checked_sub(1).filter(|&i| i < self.people.len())
    }
}

impl Screen for Reviewers {
    fn title(&self) -> String {
        format!("required reviewers \u{b7} {}", self.env)
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
        let n = self.ticked.len();
        let mut rows = vec![Row::leaf(match n {
            0 => "\u{25a1} require nobody".to_string(),
            1 => "\u{25a3} require 1 reviewer".to_string(),
            n => format!("\u{25a3} require {n} reviewers"),
        })
        .badged("apply", idx::GRN)];
        if self.people.is_empty() {
            rows.push(
                Row::leaf(match &self.error {
                    Some(e) => format!("could not list collaborators \u{2014} {e}"),
                    None if self.fetch.pending() => "asking github\u{2026}".into(),
                    None => "nobody to pick".into(),
                })
                .detail(String::new()),
            );
            return rows;
        }
        for p in &self.people {
            let box_ = if self.ticked.contains(&p.key()) {
                "\u{25a3}"
            } else {
                "\u{25a1}"
            };
            let mut r = Row::leaf(format!("{box_} {}", p.name));
            r.depth = 1;
            let was = self.had.iter().any(|h| h.key() == p.key());
            rows.push(r.detail(match (p.team, was) {
                (true, true) => "team \u{b7} required now",
                (true, false) => "team",
                (false, true) => "required now",
                (false, false) => "collaborator",
            }));
        }
        // Said out loud even when there ARE rows, because the rows are then
        // only whoever is required ALREADY -- a short list that looks like
        // the whole list is the one way this screen could mislead.
        if let Some(e) = &self.error {
            rows.push(Row::spacer());
            let mut note = Row::leaf(format!("could not list collaborators \u{2014} {e}"));
            note.selectable = false;
            rows.push(note);
        }
        rows
    }

    fn pane(&mut self, sel: usize, cols: u16, _rows: u16) -> Pane {
        let mut lines = vec![format!("{BOLD}{PUR}{}{OFF}", self.env)];
        match self.at(sel) {
            None => {
                lines.push(format!("{GRY}who has to approve a deploy{OFF}"));
                lines.push(crate::paint::rule(cols));
                lines.push(format!(
                    "{DIM}Only ONE of them has to approve for a job to go{OFF}"
                ));
                lines.push(format!("{DIM}ahead. Up to six, people or teams.{OFF}"));
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}enter here sends the ticked set. It replaces the{OFF}"
                ));
                lines.push(format!(
                    "{DIM}whole list, which is why it starts ticked{OFF}"
                ));
                lines.push(format!("{DIM}with whoever is required now.{OFF}"));
                if let Some(e) = &self.error {
                    lines.push(String::new());
                    lines.push(format!("{RED}{e}{OFF}"));
                    lines.push(format!(
                        "{DIM}so the only names here are the ones already{OFF}"
                    ));
                    lines.push(format!(
                        "{DIM}required. Listing collaborators needs push.{OFF}"
                    ));
                }
            }
            Some(i) => {
                let p = &self.people[i];
                lines.push(format!(
                    "{GRY}{}{OFF}",
                    if p.team {
                        "a team in this org"
                    } else {
                        "a collaborator on this repo"
                    }
                ));
                lines.push(crate::paint::rule(cols));
                lines.push(format!("{:8} {}", "name", p.name));
                lines.push(format!("{:8} {}", "id", p.id));
                lines.push(String::new());
                lines.push(format!(
                    "{DIM}The API takes the id, not the name, which is why{OFF}"
                ));
                lines.push(format!("{DIM}this is a list rather than a field.{OFF}"));
            }
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        match (action, self.at(sel)) {
            // enter on a person ticks them, because there is nothing else it
            // could usefully mean here -- there is no menu behind a name.
            (Action::Activate | Action::Key(' '), Some(i)) => {
                let key = self.people[i].key();
                if !self.ticked.remove(&key) {
                    self.ticked.insert(key);
                }
                Flow::Dirty
            }
            (Action::Activate, None) => Flow::Push(Box::new(self.apply_menu())),
            (Action::Key('r'), _) => {
                self.fetch.refresh(collab_req(&self.repo));
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        match self.at(self.sel) {
            Some(_) => "space or enter ticks \u{b7} k to the apply row".into(),
            None => "enter sends the ticked set \u{b7} j into the list".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIVE: &str = r#"{"total_count":2,"environments":[
      {"name":"production","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-02-03T00:00:00Z",
       "protection_rules":[
         {"id":1,"type":"wait_timer","wait_timer":30},
         {"id":2,"type":"required_reviewers","prevent_self_review":true,
          "reviewers":[{"type":"User","reviewer":{"id":7,"login":"roest1"}},
                       {"type":"Team","reviewer":{"id":9,"slug":"platform","name":"Platform"}}]},
         {"id":3,"type":"branch_policy"}],
       "deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}},
      {"name":"staging","created_at":"2026-01-02T00:00:00Z",
       "protection_rules":[],"deployment_branch_policy":null}]}"#;

    fn envs() -> Vec<Env> {
        read_list(&serde_json::from_str(LIVE).expect("parses"))
    }

    /// The API splits an environment across three rule objects of different
    /// shapes; this is the one place that has to put it back together.
    #[test]
    fn the_rules_flatten_into_one_environment() {
        let e = envs();
        assert_eq!(e[0].name, "production");
        assert_eq!(e[0].wait_timer, 30);
        assert!(e[0].prevent_self_review);
        assert_eq!(e[0].policy, Policy::Protected);
        assert_eq!(e[0].reviewers.len(), 2);
        assert_eq!(
            e[0].reviewers[0],
            Reviewer {
                team: false,
                id: 7,
                name: "roest1".into()
            }
        );
        // A team carries `slug`, not `login`, and must still be named.
        assert_eq!(
            e[0].reviewers[1],
            Reviewer {
                team: true,
                id: 9,
                name: "platform".into()
            }
        );
        assert_eq!(e[1].wait_timer, 0);
        assert!(e[1].reviewers.is_empty());
        assert_eq!(e[1].policy, Policy::Any);
        assert_eq!(e[1].gates(), 0);
    }

    /// The bug this file exists to not have: a wait timer that drops the
    /// reviewers. Every PUT carries the whole environment.
    #[test]
    fn setting_a_wait_timer_still_sends_the_reviewers() {
        let e = &envs()[0];
        let argv = put_argv(
            "roest1/dotfiles",
            &e.name,
            "5",
            e.prevent_self_review,
            &e.reviewers,
            !e.reviewers.is_empty(),
            e.policy,
        );
        let line = argv.join(" ");
        assert!(line.contains("wait_timer=5"), "{line}");
        assert!(line.contains("prevent_self_review=true"), "{line}");
        assert!(line.contains("reviewers[][type]=User"), "{line}");
        assert!(line.contains("reviewers[][id]=7"), "{line}");
        assert!(line.contains("reviewers[][type]=Team"), "{line}");
        assert!(line.contains("reviewers[][id]=9"), "{line}");
        assert!(
            line.contains("deployment_branch_policy[protected_branches]=true"),
            "{line}"
        );
        // Each reviewer is its own pair, in order, which is what makes gh
        // build an array of objects rather than one merged object.
        let types: Vec<&String> = argv
            .iter()
            .filter(|a| a.starts_with("reviewers[]"))
            .collect();
        assert_eq!(types.len(), 4, "{argv:?}");
    }

    /// Clearing the list needs the explicit empty array -- but only when
    /// there was somebody to clear.
    #[test]
    fn requiring_nobody_sends_an_empty_array_only_when_it_has_to() {
        let had = put_argv("r/r", "prod", "0", false, &[], true, Policy::Any);
        assert!(had.iter().any(|a| a == "reviewers[]"), "{had:?}");
        // prevent_self_review is meaningless with no reviewers, and sending it
        // asks the API to validate a rule that is not there.
        assert!(
            !had.iter().any(|a| a.starts_with("prevent_self_review")),
            "{had:?}"
        );
        let never = put_argv("r/r", "prod", "0", false, &[], false, Policy::Any);
        assert!(!never.iter().any(|a| a == "reviewers[]"), "{never:?}");
    }

    /// "Any branch" is a real null, not an absent field -- the docs are
    /// explicit about that one.
    #[test]
    fn an_open_branch_policy_is_a_null() {
        let any = put_argv("r/r", "e", "0", false, &[], false, Policy::Any).join(" ");
        assert!(any.contains("deployment_branch_policy=null"), "{any}");
        let sel = put_argv("r/r", "e", "0", false, &[], false, Policy::Selected).join(" ");
        assert!(
            sel.contains("[custom_branch_policies]=true")
                && sel.contains("[protected_branches]=false"),
            "{sel}"
        );
    }

    /// An environment name with a space is legal on GitHub and must survive
    /// the path.
    #[test]
    fn an_awkward_name_is_encoded_into_the_path() {
        let argv = put_argv("r/r", "blue green", "0", false, &[], false, Policy::Any);
        assert!(
            argv.iter()
                .any(|a| a == "repos/r/r/environments/blue%20green"),
            "{argv:?}"
        );
    }

    /// The wait-timer item is a TEMPLATE: the same builder produces it, so the
    /// command that confirms is the command that runs.
    #[test]
    fn the_wait_timer_item_keeps_the_rest_of_the_environment() {
        let mut screen = Envs::open("roest1/dotfiles", Arc::new(Fetcher::new("")));
        screen.envs = envs();
        let argv = screen.put(
            &screen.envs[0],
            "{}",
            true,
            &screen.envs[0].reviewers.clone(),
        );
        assert!(argv.iter().any(|a| a == "wait_timer={}"), "{argv:?}");
        assert!(argv.iter().any(|a| a == "reviewers[][id]=7"), "{argv:?}");
    }

    /// The positions and the rows are two readings of one list.
    #[test]
    fn the_rows_and_the_positions_agree() {
        let mut screen = Envs::open("roest1/dotfiles", Arc::new(Fetcher::new("")));
        screen.envs = envs();
        let rows = screen.rows();
        assert_eq!(screen.at(0), At::Env(0));
        assert_eq!(screen.at(1), At::Env(1));
        assert_eq!(screen.at(2), At::Nothing, "the spacer");
        assert!(!rows[2].selectable);
        assert_eq!(screen.at(3), At::New);
        assert_eq!(rows[3].label, "+ new environment");
    }

    /// And they have to agree on the EMPTY repo too, which is where it
    /// mattered most and where the first version was wrong: the placeholder
    /// row is a row, so `+ new environment` is at 2 rather than at 1. On a
    /// repo with no environments, creating one is the only thing the screen
    /// can do, and `enter` on it did nothing.
    #[test]
    fn the_positions_survive_an_empty_list() {
        let mut screen = Envs::open("roest1/dotfiles", Arc::new(Fetcher::new("")));
        let rows = screen.rows();
        assert_eq!(
            rows.len(),
            3,
            "{:?}",
            rows.iter().map(|r| &r.label).collect::<Vec<_>>()
        );
        assert_eq!(rows[2].label, "+ new environment");
        assert_eq!(screen.at(2), At::New);
        assert!(matches!(
            screen.on_action(Action::Activate, 2),
            Flow::Ask { .. }
        ));
    }

    /// An environment with no gates says so, rather than looking like one
    /// whose badges have not loaded.
    #[test]
    fn an_ungated_environment_says_no_gates() {
        let mut screen = Envs::open("roest1/dotfiles", Arc::new(Fetcher::new("")));
        screen.envs = envs();
        let rows = screen.rows();
        let badges: Vec<&str> = rows[0].badges.iter().map(|b| b.0.as_str()).collect();
        assert!(badges.iter().any(|b| b.contains("30m")), "{badges:?}");
        assert!(badges.iter().any(|b| b.contains('2')), "{badges:?}");
        assert_eq!(
            rows[1].badges.first().map(|b| b.0.as_str()),
            Some("no gates")
        );
    }

    /// The picker opens on the current set, which is the only way to add one
    /// reviewer without removing the others.
    #[test]
    fn the_picker_starts_ticked_with_whoever_is_required_now() {
        let e = &envs()[0];
        let mut p = Reviewers::open("roest1/dotfiles", e, Arc::new(Fetcher::new("")));
        assert_eq!(p.ticked.len(), 2);
        // Teams sort after people, so roest1 is row 1 and platform is row 2.
        assert_eq!(p.at(0), None, "row 0 is apply");
        assert_eq!(p.people[p.at(1).expect("a person")].name, "roest1");
        // Unticking the team leaves the person, and the command says so.
        p.on_action(Action::Key(' '), 2);
        assert_eq!(p.chosen().len(), 1);
        assert_eq!(p.chosen()[0].name, "roest1");
    }

    /// Unticking everybody is a destructive change and has to read as one.
    #[test]
    fn clearing_the_whole_list_is_marked_destructive() {
        let e = &envs()[0];
        let mut p = Reviewers::open("roest1/dotfiles", e, Arc::new(Fetcher::new("")));
        p.ticked.clear();
        let mut menu = p.apply_menu();
        assert_eq!(
            menu.rows()[0].badges.first().map(|b| b.0.as_str()),
            Some("!")
        );
        assert!(
            menu.footer().contains("cannot be undone"),
            "{}",
            menu.footer()
        );
    }

    /// A reviewer who is not a collaborator must not disappear from the list
    /// that replaces them.
    #[test]
    fn a_required_reviewer_is_a_candidate_even_if_the_list_never_names_them() {
        let e = &envs()[0];
        let p = Reviewers::open("roest1/dotfiles", e, Arc::new(Fetcher::new("")));
        assert_eq!(p.people.len(), 2);
        assert!(p.people.iter().any(|r| r.team && r.name == "platform"));
    }

    /// A payload that is not the shape expected comes back empty rather than
    /// panicking -- a 404 body is JSON too.
    #[test]
    fn a_wrong_shaped_payload_is_empty_rather_than_a_panic() {
        let v: serde_json::Value = serde_json::from_str(r#"{"message":"Not Found"}"#).unwrap();
        assert!(read_list(&v).is_empty());
    }
}
