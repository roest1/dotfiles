//! The Actions screen: workflow runs, newest first, with the failure opened up.
//!
//! The screen the port was sequenced around. It is the only one that exercises
//! live refresh, cross-session caching and the step-log slicing at the same
//! time, which is why it came second rather than last -- if this shape survives
//! a CI dashboard, the remaining screens are lists with previews.
//!
//! ## The two clocks
//!
//! A run list goes stale; a run in flight changes. Those are different
//! intervals and the screen runs both:
//!
//!   * the LIST is re-asked every 15s, but only while something on it is still
//!     going. A list of finished runs cannot change except by someone pushing,
//!     and `r` is there for that.
//!   * the SELECTED run's jobs are re-asked every 5s, again only while it is
//!     live. That is what makes a step flip from queued to running to green
//!     under the cursor without a keystroke.
//!
//! Both stop by themselves the moment the thing they are watching finishes,
//! which is the property the fzf implementation got from a preview rescheduling
//! its own tick, and the reason neither needs a stop button.
//!
//! They are reported through `Tick::Wake`, NOT `Tick::Busy`. Busy sets the poll
//! timeout to one frame, so a nine-minute run would have spun the process at
//! 60fps for nine minutes to notice something that can only arrive on a
//! five-second boundary.
//!
//! ## What the list column says, and what it does not
//!
//! The fzf list had ~100 columns and spent them: glyph, HEAD marker, age,
//! duration, event, branch, workflow, title. `reticle`'s left column is 52, so
//! the row has to choose, and the triple that IDENTIFIES a run is title, age
//! and verdict. Branch, event, workflow, duration, actor and run number all
//! moved into the pane, which is wider than the old preview was and is on
//! screen at the same time.
//!
//! The branch comes back into the row when -- and only when -- you are looking
//! across branches, because that is when it is the thing that distinguishes two
//! otherwise identical rows. Same rule as the root screen's slug.

use std::sync::Arc;
use std::time::{Duration, Instant};

use reticle::{nav::Action, Flow, Pane, Row, Screen, Tick};

use crate::gh::{Fetcher, Got, Req};
use crate::index::Repo;
use crate::model::Run;
use crate::paint::{DIM, OFF, ORG};
use crate::steps::Steps;
use crate::{render, time};

/// How often to look again while a `gh` call is in flight.
///
/// `Tick::Busy` is the obvious answer and is the wrong one here. It means "wake
/// me next frame", which is right for work that lands in milliseconds -- the
/// font browser rasterising a specimen -- and wasteful for a network round trip
/// measured in hundreds. Polling at 60fps through a one-second fetch is ~60
/// redraws to notice something that could not possibly have arrived sooner,
/// and it is the screen, not the loop, that knows which kind of work it started.
///
/// A tenth of a second is far below the point where a response landing feels
/// delayed, and it is a sixth of the frames.
const IN_FLIGHT: Duration = Duration::from_millis(100);

const LIST_EVERY: Duration = Duration::from_secs(15);
const JOBS_EVERY: Duration = Duration::from_secs(5);
/// How long paging a log may block. Long enough for a cold 15KB fetch on a bad
/// connection, short enough that a hung network does not feel like a crash.
const PAGER_WAIT: Duration = Duration::from_secs(10);

/// Which runs the list is showing.
#[derive(Clone, PartialEq, Eq)]
pub enum Scope {
    /// Everything the repo has run, which is the right default when you have
    /// just arrived and do not yet know what you are looking for.
    All,
    /// One branch -- normally the one checked out here.
    Branch(String),
    /// One commit. Nothing reaches this yet; it is what the PR screen's "its
    /// runs" becomes, and it is here because the query builder is the only
    /// thing that would have had to change and it may as well be right once.
    Commit(String),
}

impl Scope {
    fn query(&self) -> String {
        let mut q = "per_page=40".to_string();
        match self {
            Scope::All => {}
            Scope::Branch(b) => q.push_str(&format!("&branch={}", urlencode(b))),
            Scope::Commit(sha) => q.push_str(&format!("&head_sha={sha}")),
        }
        q
    }

    fn label(&self) -> String {
        match self {
            Scope::All => "all branches".into(),
            Scope::Branch(b) => format!("\u{2387} {b}"),
            Scope::Commit(sha) => format!("commit {}", &sha[..sha.len().min(7)]),
        }
    }
}

/// Percent-encode a branch name for a query string.
///
/// Branch names legally contain `/`, `#` and `+`, all of which change the
/// meaning of a query parameter -- `feat/x+y` would otherwise ask for the
/// branch `feat/x y`. Only unreserved characters pass through.
pub(crate) fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// A destructive action waiting on one more keystroke.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Confirm {
    Rerun,
    RerunFailed,
    Cancel,
}

pub struct Actions {
    repo: String,
    scope: Scope,
    /// The branch checked out in the clone, so `b` has something to toggle back
    /// to. `None` for a detached HEAD or an unborn branch, which is why the
    /// toggle has to cope with there being no branch scope at all.
    branch: Option<String>,
    /// `HEAD`, for marking the runs of the commit you are actually sitting on.
    head_sha: Option<String>,
    /// Shared with the jobs & steps screen pushed on top, so drilling into
    /// a run reuses the jobs and logs already fetched for its pane instead of
    /// asking for them again one keystroke later.
    fetch: Arc<Fetcher>,
    runs: Vec<Run>,
    /// True when the repo has more than one workflow, which is the only time
    /// naming the workflow distinguishes anything.
    multi: bool,
    error: Option<String>,
    status: String,
    epoch_seen: u64,
    list_due: Option<Instant>,
    jobs_due: Option<Instant>,
    sel: usize,
    pending: Option<Confirm>,
}

impl Actions {
    /// Open on a repo. Costs one `git rev-parse` and no network.
    ///
    /// The git spawn is the one place this crate shells out where `index` reads
    /// a file instead, and the asymmetry is the point: `index` resolves 27
    /// repos at startup, where this resolves one, after the first frame is
    /// already drawn. Reimplementing packed-ref lookup to save 3ms behind a
    /// network request would be the wrong trade.
    pub fn open(repo: &Repo) -> Option<Self> {
        let slug = match &repo.remote {
            crate::index::Remote::GitHub { owner, name } => format!("{owner}/{name}"),
            _ => return None,
        };
        let head_sha = std::process::Command::new("git")
            .arg("-C")
            .arg(&repo.path)
            .args(["rev-parse", "HEAD"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty());
        let branch = repo
            .branch
            .clone()
            .filter(|b| !b.starts_with("detached at "));
        let me = Self {
            fetch: Arc::new(Fetcher::new(&slug)),
            repo: slug,
            // All branches on arrival. A repo you have just opened is one you
            // want the state of, and scoping to the branch you happen to be
            // standing on hides the run that is actually failing.
            scope: Scope::All,
            branch,
            head_sha,
            runs: Vec::new(),
            multi: false,
            error: None,
            status: String::new(),
            epoch_seen: 0,
            list_due: None,
            jobs_due: None,
            sel: 0,
            pending: None,
        };
        me.fetch.request(me.list_req());
        Some(me)
    }

    /// The shared fetcher, so the repo's other screens reuse what this one has
    /// already asked for -- the runs list is the Branches screen's checks
    /// column, so sharing it turns a second call into none.
    pub fn fetcher(&self) -> Arc<Fetcher> {
        Arc::clone(&self.fetch)
    }

    fn list_req(&self) -> Req {
        Req::Runs {
            query: self.scope.query(),
        }
    }

    fn jobs_req(&self, run: &Run) -> Req {
        Req::Jobs {
            run: run.id,
            attempt: run.run_attempt,
            // The list already told us whether this run is finished, so no
            // second call is needed to decide whether the answer may be
            // cached. See the note on `Req::Jobs`.
            persist: run.verdict().done(),
        }
    }

    fn run(&self, sel: usize) -> Option<&Run> {
        self.runs.get(sel)
    }

    /// Pull whatever has landed into our own state.
    fn sync(&mut self) {
        if let Some(got) = self.fetch.get(&self.list_req()) {
            match got {
                Got::Runs(runs) => {
                    self.runs = runs.as_ref().clone();
                    let mut names: Vec<&str> =
                        self.runs.iter().filter_map(|r| r.name.as_deref()).collect();
                    names.sort_unstable();
                    names.dedup();
                    self.multi = names.len() > 1;
                    self.error = None;
                    // Re-armed from what arrived rather than on a fixed
                    // timer: a list of finished runs schedules nothing.
                    self.list_due = self
                        .runs
                        .iter()
                        .any(|r| !r.verdict().done())
                        .then(|| Instant::now() + LIST_EVERY);
                }
                Got::Failed(e) => self.error = Some(e),
                _ => {}
            }
        }
        // Whatever the cursor is on drives the jobs clock, and its own arrival
        // is what re-arms it -- so a run that finished between two polls stops
        // being polled rather than being polled forever.
        let live = self
            .run(self.sel)
            .map(|r| !r.verdict().done())
            .unwrap_or(false);
        self.jobs_due = live.then(|| Instant::now() + JOBS_EVERY);
        self.want_jobs(self.sel);
    }

    /// Ask for the jobs of the run at `sel` and of the one after it, plus the
    /// logs of any failed jobs in them.
    ///
    /// Driven by `focus`, not by `pane`, which is the rule this repo already
    /// paid for in the font browser: a row you skim PAST still has to be
    /// fetched, because that is precisely what makes the next keypress instant
    /// rather than the current one slow.
    ///
    /// One neighbour, not a window. The font browser prefetches several because
    /// a download is slow and a catalogue is browsed slowly; here each row is a
    /// `gh api` call, and scrolling a forty-run list with a window of five
    /// would fire a hundred requests to answer the one you stopped on. Down is
    /// the direction of travel, so the row below is the one worth having.
    fn want_jobs(&self, sel: usize) {
        for i in [sel, sel + 1] {
            let Some(run) = self.run(i) else { continue };
            let req = self.jobs_req(run);
            self.fetch.request(req.clone());
            let Some(Got::Jobs(jobs)) = self.fetch.get(&req) else {
                continue;
            };
            for job in jobs.iter() {
                // Only failed jobs, and only completed ones. GitHub serves
                // nothing for a job still running, so asking is a wasted round
                // trip that comes back looking like an empty log.
                if job.verdict() == crate::model::Verdict::Failed && job.has_log() {
                    self.fetch.request(Req::Log { job: job.id });
                }
            }
        }
    }

    fn jobs_of(&self, run: &Run) -> Option<std::sync::Arc<Vec<crate::model::Job>>> {
        match self.fetch.get(&self.jobs_req(run)) {
            Some(Got::Jobs(j)) => Some(j),
            _ => None,
        }
    }

    fn log_of(&self, job: u64) -> Option<String> {
        match self.fetch.get(&Req::Log { job }) {
            Some(Got::Log(l)) => Some(l.as_ref().clone()),
            _ => None,
        }
    }

    fn toggle_scope(&mut self) -> Flow {
        self.scope = match (&self.scope, &self.branch) {
            (Scope::All, Some(b)) => Scope::Branch(b.clone()),
            (Scope::Branch(_), _) => Scope::All,
            // A commit scope is narrower than either and `b` widens out of it.
            (Scope::Commit(_), _) => Scope::All,
            (Scope::All, None) => {
                self.status = "no branch checked out here to scope to".into();
                return Flow::Dirty;
            }
        };
        // The runs on screen belong to the old scope. Clearing them is what
        // stops the list showing one scope while its label claims another.
        self.runs.clear();
        self.sel = 0;
        self.list_due = None;
        self.fetch.request(self.list_req());
        Flow::Dirty
    }

    fn refresh(&mut self) -> Flow {
        self.fetch.refresh(self.list_req());
        if let Some(run) = self.run(self.sel) {
            self.fetch.refresh(self.jobs_req(run));
        }
        self.status = "refreshing\u{2026}".into();
        Flow::Dirty
    }

    fn browse(&mut self, sel: usize) -> Flow {
        let Some(run) = self.run(sel) else {
            return Flow::Continue;
        };
        let url = run.html_url.clone();
        let opener = if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        };
        match std::process::Command::new(opener).arg(&url).spawn() {
            Ok(_) => self.status = format!("opened {url}"),
            Err(e) => self.status = format!("could not run {opener}: {e}"),
        }
        Flow::Dirty
    }

    /// Ask before doing something that costs runner minutes or kills a build.
    ///
    /// A screen-local two-key confirm rather than a `reticle` dialog, because
    /// there is no dialog in `reticle` yet and this needs no text entry -- it
    /// needs one yes. It is safe by construction rather than by bookkeeping:
    /// the ONLY key that acts is `y`, and any other key the screen sees clears
    /// the prompt, so a stale prompt can never turn a later keystroke into a
    /// rerun. Moving the cursor clears it too, via `focus`.
    ///
    /// A shared confirm is still the right eventual home -- `pr-create`,
    /// `secret-set` and every delete need one WITH text entry, and that is a
    /// framework change rather than five screen-local copies of this.
    fn ask(&mut self, what: Confirm, run: &Run) -> Flow {
        let (verb, detail) = match what {
            Confirm::RerunFailed => ("rerun the failed jobs of", "they will run again"),
            Confirm::Rerun => ("rerun ALL jobs of", "the whole workflow runs again"),
            Confirm::Cancel => ("cancel", "jobs still running will be stopped"),
        };
        self.pending = Some(what);
        self.status = format!(
            "{verb} #{} \u{2014} {detail}.  y to confirm, any other key to leave it",
            run.run_number
        );
        Flow::Dirty
    }

    fn act(&mut self, what: Confirm, sel: usize) -> Flow {
        let Some(run) = self.run(sel) else {
            return Flow::Continue;
        };
        let id = run.id.to_string();
        let args: Vec<&str> = match what {
            Confirm::RerunFailed => vec!["run", "rerun", &id, "--failed"],
            Confirm::Rerun => vec!["run", "rerun", &id],
            Confirm::Cancel => vec!["run", "cancel", &id],
        };
        let out = std::process::Command::new("gh").args(&args).output();
        self.status = match out {
            Ok(o) if o.status.success() => match what {
                Confirm::Cancel => "cancel requested".into(),
                _ => "rerun triggered".into(),
            },
            Ok(o) => String::from_utf8_lossy(&o.stderr)
                .lines()
                .find(|l| !l.trim().is_empty())
                .unwrap_or("gh refused")
                .trim()
                .to_string(),
            Err(e) => format!("could not run gh: {e}"),
        };
        // A rerun makes a NEW attempt of the same id, so the list has to be
        // re-read before anything else is believed about this run. The jobs
        // cache needs no eviction -- it is keyed by attempt, so the new
        // attempt is simply a key nothing has answered yet.
        self.fetch.refresh(self.list_req());
        Flow::Dirty
    }

    /// Every completed job's log, concatenated, for the pager.
    fn whole_log(&mut self, sel: usize) -> Option<String> {
        let run = self.run(sel)?.clone();
        let jobs = self.jobs_of(&run)?;
        let reqs: Vec<Req> = jobs
            .iter()
            .filter(|j| j.has_log())
            .map(|j| Req::Log { job: j.id })
            .collect();
        if reqs.is_empty() {
            self.status = "no completed job has a log yet".into();
            return None;
        }
        let all = self.fetch.block_on(&reqs, PAGER_WAIT);
        let mut out = String::new();
        for job in jobs.iter().filter(|j| j.has_log()) {
            out.push_str(&format!(
                "\n\u{2501}\u{2501}\u{2501} {} \u{2501}\u{2501}\u{2501}\n\n",
                job.name
            ));
            match self.log_of(job.id) {
                Some(log) => {
                    for line in crate::logs::fmt_log(log.lines()) {
                        out.push_str(&line);
                        out.push('\n');
                    }
                }
                None => out.push_str("(log did not arrive)\n"),
            }
        }
        if !all {
            self.status = "some logs timed out".into();
        }
        Some(out)
    }
}

/// Write `body` somewhere a pager can read it, and return the argv to page it.
///
/// A temp FILE rather than a pipe, because `Flow::Detach` runs one command with
/// arguments and deliberately goes nowhere near a shell -- so there is nothing
/// to pipe into. `less -R` to keep the ANSI the log already carries.
pub fn pager(name: &str, body: &str) -> Option<Vec<String>> {
    let path = std::env::temp_dir().join(format!("github-{}-{name}.log", std::process::id()));
    std::fs::write(&path, body).ok()?;
    Some(vec![
        "less".into(),
        "-R".into(),
        path.to_string_lossy().into_owned(),
    ])
}

impl Screen for Actions {
    fn title(&self) -> String {
        format!("{} \u{b7} actions \u{b7} {}", self.repo, self.scope.label())
    }

    fn initial_sel(&self) -> usize {
        0
    }

    fn focus(&mut self, sel: usize) {
        if sel != self.sel {
            // Any cursor movement withdraws a pending confirm. The cheapest
            // honest rule: the prompt names a run, and the cursor is no longer
            // on it.
            self.pending = None;
            self.status.clear();
        }
        self.sel = sel;
        self.want_jobs(sel);
        // The jobs clock follows the cursor, because it is the SELECTED run
        // being watched -- moving to a finished run must stop the polling that
        // the live one started.
        self.jobs_due = self
            .run(sel)
            .map(|r| !r.verdict().done())
            .unwrap_or(false)
            .then(|| Instant::now() + JOBS_EVERY);
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
        let t = Instant::now();
        if self.list_due.is_some_and(|d| t >= d) {
            self.list_due = Some(t + LIST_EVERY);
            self.fetch.refresh(self.list_req());
            return Tick::Wake(IN_FLIGHT);
        }
        if self.jobs_due.is_some_and(|d| t >= d) {
            self.jobs_due = Some(t + JOBS_EVERY);
            if let Some(run) = self.run(self.sel) {
                self.fetch.refresh(self.jobs_req(run));
            }
            return Tick::Wake(IN_FLIGHT);
        }
        // Whichever clock is nearer, and nothing at all if neither is running.
        match [self.list_due, self.jobs_due]
            .into_iter()
            .flatten()
            .min()
            .map(|d| d.saturating_duration_since(t))
        {
            Some(d) => Tick::Wake(d),
            None => Tick::Idle,
        }
    }

    fn rows(&mut self) -> Vec<Row> {
        if let Some(e) = &self.error {
            return vec![Row::leaf("could not list runs").detail(e.clone())];
        }
        if self.runs.is_empty() {
            let waiting = self.fetch.pending();
            return vec![Row::leaf(if waiting {
                "asking github\u{2026}"
            } else {
                "no workflow runs here yet"
            })];
        }
        // Showing the branch only when looking ACROSS branches: inside one
        // scope it is in the title bar and repeating it down the column says
        // nothing. Same rule as the root screen's slug.
        let across = matches!(self.scope, Scope::All);
        self.runs
            .iter()
            .map(|run| {
                let (badge, color) = run.verdict().badge();
                // The HEAD marker is a two-column prefix on every row, present
                // or blank, so the titles stay aligned. A marker that shifted
                // the column would be harder to scan than no marker at all.
                let here = self
                    .head_sha
                    .as_deref()
                    .is_some_and(|sha| sha == run.head_sha);
                let label = format!(
                    "{}{}",
                    if here { "\u{25cf} " } else { "  " },
                    run.display_title.replace(['\t', '\n'], " ")
                );
                let mut detail = time::age(run.age());
                if across {
                    if let Some(br) = &run.head_branch {
                        detail.push_str(&format!(" \u{b7} {br}"));
                    }
                }
                Row::leaf(label).detail(detail).badged(badge, color)
            })
            .collect()
    }

    fn pane(&mut self, sel: usize, cols: u16, rows: u16) -> Pane {
        let mut lines: Vec<String> = Vec::new();
        if let Some(e) = &self.error {
            lines.push(format!("{}{e}{OFF}", crate::paint::RED));
            lines.push(String::new());
            lines.push(format!(
                "{DIM}`gh auth status` is the first thing to check.{OFF}"
            ));
            return Pane { image: None, lines };
        }
        if let Some(run) = self.run(sel).cloned() {
            lines.extend(render::run_header(&run, cols, self.multi));
            let jobs = self.jobs_of(&run);
            // The header is already drawn, so the body is told how much room
            // is actually LEFT -- not how tall the pane is. A body that
            // budgeted against the whole pane would overflow by exactly the
            // header and lose its summary line.
            let room = rows.saturating_sub(lines.len() as u16);
            lines.extend(render::run_body(
                &run,
                jobs.as_deref().map(|v| v.as_slice()),
                &|id| self.log_of(id),
                cols,
                room,
            ));
        } else {
            lines.push(format!("{DIM}Nothing has run here yet.{OFF}"));
            lines.push(String::new());
            lines.push(format!(
                "{DIM}A workflow in .github/workflows and a push is all{OFF}"
            ));
            lines.push(format!("{DIM}it takes.{OFF}"));
        }
        if !self.status.is_empty() {
            lines.push(String::new());
            lines.push(format!("{ORG}{}{OFF}", self.status));
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        // A pending confirm consumes the very next key the screen sees,
        // whatever it is. `y` acts; everything else withdraws.
        if let Some(what) = self.pending.take() {
            self.status.clear();
            return match action {
                Action::Key('y') | Action::Key('Y') => self.act(what, sel),
                _ => {
                    self.status = "left alone".into();
                    Flow::Dirty
                }
            };
        }
        self.status.clear();
        match action {
            // `Activate` only; `l` moves into the pane. The pane IS this
            // screen's answer -- the run body with the failing step's log --
            // so being able to scroll it matters more than a second way to
            // drill in.
            Action::Activate => {
                let Some(run) = self.run(sel).cloned() else {
                    return Flow::Continue;
                };
                Flow::Push(Box::new(Steps::open(
                    &self.repo,
                    run,
                    self.multi,
                    Arc::clone(&self.fetch),
                )))
            }
            Action::Key('o') => self.browse(sel),
            Action::Key('r') => self.refresh(),
            Action::Key('b') => self.toggle_scope(),
            Action::Key('e') => {
                let Some(run) = self.run(sel).cloned() else {
                    return Flow::Continue;
                };
                // Rerunning only the failures is both cheaper and what you
                // nearly always mean, so it is what `e` offers when there ARE
                // failures -- and the prompt says which it is about to do.
                let failed = self
                    .jobs_of(&run)
                    .map(|j| {
                        j.iter()
                            .any(|j| j.verdict() == crate::model::Verdict::Failed)
                    })
                    .unwrap_or(false);
                let what = if failed {
                    Confirm::RerunFailed
                } else {
                    Confirm::Rerun
                };
                self.ask(what, &run)
            }
            Action::Key('x') => {
                let Some(run) = self.run(sel).cloned() else {
                    return Flow::Continue;
                };
                if run.verdict().done() {
                    self.status = "that run has already finished".into();
                    return Flow::Dirty;
                }
                self.ask(Confirm::Cancel, &run)
            }
            Action::Key('L') => {
                let name = self
                    .run(sel)
                    .map(|r| format!("run-{}", r.id))
                    .unwrap_or_default();
                match self.whole_log(sel).and_then(|body| pager(&name, &body)) {
                    Some(argv) => Flow::Detach(argv),
                    None => Flow::Dirty,
                }
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        if self.pending.is_some() {
            return "y confirm \u{b7} any other key leave it".into();
        }
        let scope = match (&self.scope, &self.branch) {
            (Scope::All, Some(b)) => format!("b just {b}"),
            (Scope::Branch(_), _) => "b all branches".into(),
            _ => "b all branches".into(),
        };
        format!("enter jobs & steps \u{b7} o browser \u{b7} r refresh \u{b7} {scope}\ne rerun \u{b7} x cancel \u{b7} L whole log")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::RunList;

    fn runs(states: &[(&str, Option<&str>)]) -> Vec<Run> {
        let items: Vec<String> = states
            .iter()
            .enumerate()
            .map(|(i, (status, concl))| {
                let c = concl
                    .map(|c| format!(r#","conclusion":"{c}""#))
                    .unwrap_or_default();
                format!(
                    r#"{{"id":{i},"display_title":"r{i}","head_sha":"sha{i}","event":"push",
                       "status":"{status}"{c},"html_url":"https://x",
                       "created_at":"2026-08-25T19:30:00Z","run_number":{i},"run_attempt":1}}"#
                )
            })
            .collect();
        serde_json::from_str::<RunList>(&format!(r#"{{"workflow_runs":[{}]}}"#, items.join(",")))
            .expect("parses")
            .workflow_runs
    }

    /// Built without touching the network: these tests are about the clocks,
    /// and a screen that needed the API to be examined would not be testable.
    fn screen(states: &[(&str, Option<&str>)]) -> Actions {
        let runs = runs(states);
        let mut me = Actions {
            fetch: Arc::new(Fetcher::new("roest1/dotfiles")),
            repo: "roest1/dotfiles".into(),
            scope: Scope::All,
            branch: Some("main".into()),
            head_sha: Some("sha0".into()),
            runs,
            multi: false,
            error: None,
            status: String::new(),
            epoch_seen: 0,
            list_due: None,
            jobs_due: None,
            sel: 0,
            pending: None,
        };
        // What `sync` does with what arrived, minus the arriving.
        me.list_due = me
            .runs
            .iter()
            .any(|r| !r.verdict().done())
            .then(|| Instant::now() + LIST_EVERY);
        me.jobs_due = me
            .run(0)
            .map(|r| !r.verdict().done())
            .unwrap_or(false)
            .then(|| Instant::now() + JOBS_EVERY);
        me
    }

    /// The property that keeps this screen off the CPU, and the one a live
    /// refresh is most likely to break: a list of finished runs schedules
    /// NOTHING, so `reticle`'s poll blocks for an hour and the process costs
    /// nothing until a key is pressed.
    #[test]
    fn a_finished_list_arms_no_clock_at_all() {
        let mut s = screen(&[
            ("completed", Some("success")),
            ("completed", Some("failure")),
        ]);
        assert!(s.list_due.is_none());
        assert!(s.jobs_due.is_none());
        assert!(matches!(s.tick(), Tick::Idle));
    }

    /// And the other direction: something in flight asks to be woken, on the
    /// slow clock rather than the frame clock.
    #[test]
    fn a_live_run_asks_to_be_woken_on_the_slow_clock() {
        let mut s = screen(&[("in_progress", None), ("completed", Some("success"))]);
        assert!(s.list_due.is_some());
        assert!(s.jobs_due.is_some());
        match s.tick() {
            // The nearer of the two clocks, which is the jobs one.
            Tick::Wake(d) => assert!(d <= JOBS_EVERY, "woke on {d:?}"),
            _ => panic!("a live run must schedule a wake"),
        }
    }

    /// The jobs clock follows the CURSOR, not the list. Moving onto a finished
    /// run has to stop the polling the live one started, or every run visited
    /// during a build leaves a timer behind it.
    #[test]
    fn moving_off_a_live_run_stops_polling_its_jobs() {
        let mut s = screen(&[("in_progress", None), ("completed", Some("success"))]);
        s.focus(1);
        assert!(s.jobs_due.is_none(), "still polling a finished run");
        // The LIST clock stays armed: run 0 is still going, and it is still on
        // the list whether or not the cursor is on it.
        assert!(s.list_due.is_some());
        s.focus(0);
        assert!(s.jobs_due.is_some(), "stopped polling a live run");
    }

    /// A confirm must not survive the keystroke after it. `y` is the only key
    /// that acts, so the dangerous direction is a prompt that stays up -- and
    /// the cheapest rule that closes it is that any key the screen sees, and
    /// any cursor movement, withdraws.
    #[test]
    fn a_confirm_is_withdrawn_by_anything_that_is_not_yes() {
        let mut s = screen(&[("in_progress", None)]);
        s.pending = Some(Confirm::Cancel);
        s.on_action(Action::Key('j'), 0);
        assert!(s.pending.is_none(), "a stray key left the prompt up");

        s.pending = Some(Confirm::Cancel);
        s.focus(1);
        assert!(s.pending.is_none(), "moving the cursor left the prompt up");
    }

    /// Cancelling something already finished is a no-op the screen should name
    /// rather than ask about.
    #[test]
    fn a_finished_run_is_not_offered_a_cancel() {
        let mut s = screen(&[("completed", Some("success"))]);
        s.on_action(Action::Key('x'), 0);
        assert!(s.pending.is_none());
        assert!(s.status.contains("already finished"), "{}", s.status);
    }

    /// Switching scope must drop the runs it was showing. Keeping them would
    /// leave the list showing one scope while the title bar claims another,
    /// which is the kind of wrong that gets believed.
    #[test]
    fn changing_scope_discards_the_runs_of_the_old_one() {
        let mut s = screen(&[
            ("completed", Some("success")),
            ("completed", Some("failure")),
        ]);
        assert_eq!(s.runs.len(), 2);
        s.on_action(Action::Key('b'), 0);
        assert!(matches!(s.scope, Scope::Branch(_)));
        assert!(s.runs.is_empty(), "showed the old scope's runs");
        assert_eq!(s.sel, 0);
    }

    /// A detached HEAD has no branch to scope to, and saying so beats building
    /// a query for the branch `HEAD`.
    #[test]
    fn with_no_branch_the_scope_toggle_explains_itself() {
        let mut s = screen(&[("completed", Some("success"))]);
        s.branch = None;
        s.on_action(Action::Key('b'), 0);
        assert!(matches!(s.scope, Scope::All));
        assert!(s.status.contains("no branch"), "{}", s.status);
    }

    /// The marker that answers "is this MY run". It is on the row whose head
    /// sha is the checked-out commit and on no other.
    #[test]
    fn the_head_marker_lands_on_the_commit_you_are_standing_on() {
        let mut s = screen(&[
            ("completed", Some("success")),
            ("completed", Some("success")),
        ]);
        let rows = s.rows();
        assert!(rows[0].label.starts_with('\u{25cf}'), "{:?}", rows[0].label);
        // Blank rather than absent, so the titles stay in one column.
        assert!(rows[1].label.starts_with("  "), "{:?}", rows[1].label);
    }

    #[test]
    fn a_branch_scope_encodes_the_characters_a_branch_name_may_hold() {
        // `/` and `+` both change the meaning of a query parameter, and both
        // are legal in a branch name -- `feat/x+y` must not ask for `feat/x y`.
        assert_eq!(
            Scope::Branch("feat/github-tui".into()).query(),
            "per_page=40&branch=feat%2Fgithub-tui"
        );
        assert_eq!(
            Scope::Branch("fix+more".into()).query(),
            "per_page=40&branch=fix%2Bmore"
        );
        assert_eq!(Scope::All.query(), "per_page=40");
        assert_eq!(
            Scope::Commit("deadbeef".into()).query(),
            "per_page=40&head_sha=deadbeef"
        );
    }

    /// The label is what the title bar claims the list is, so it has to track
    /// the query exactly -- a short sha reads as a sha, not as a branch.
    #[test]
    fn the_label_names_the_scope_it_fetched() {
        assert_eq!(Scope::All.label(), "all branches");
        assert!(Scope::Branch("main".into()).label().contains("main"));
        assert_eq!(
            Scope::Commit("deadbeefcafe".into()).label(),
            "commit deadbee"
        );
        // A sha shorter than seven characters must not panic the slice.
        assert_eq!(Scope::Commit("abc".into()).label(), "commit abc");
    }
}
