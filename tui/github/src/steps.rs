//! Jobs and steps of one run, as a tree.
//!
//! The fzf implementation listed these FLAT -- a job line, then its steps
//! indented under it, all in one unfilterable column -- because fzf has no
//! tree. `reticle` does, and a matrix build is the case that makes the
//! difference: twelve jobs of fifteen steps is 180 rows flat, against twelve
//! rows with the one you care about opened.
//!
//! ## Which jobs open on arrival
//!
//! The failed ones, and only those. You reached this screen from a run whose
//! pane already showed the failure; the reason to come further is to see more
//! of it. A passing job's fifteen green steps are fifteen rows saying what its
//! own row said, and on a matrix build they bury the failure -- the same
//! argument that keeps the run body from expanding passing jobs, applied to a
//! tree instead of a transcript.
//!
//! If nothing failed, everything opens: a run you drilled into for curiosity
//! rather than for a failure should not present as a list of closed boxes.

use std::sync::Arc;
use std::time::{Duration, Instant};

use reticle::{nav::Action, Flow, Pane, Row, Screen, Tick};

use crate::gh::{Fetcher, Got, Req};
use crate::model::{Job, Run, Verdict};
use crate::paint::{DIM, OFF, ORG};
use crate::runs::pager;
use crate::{logs, render, time};

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

const JOBS_EVERY: Duration = Duration::from_secs(5);
const PAGER_WAIT: Duration = Duration::from_secs(10);

/// What the cursor is on, resolved once.
///
/// The same device as `dots::console::At` and `root::At`, for the same reason:
/// `pane`, `on_action` and `footer` each need to know, and three independent
/// row walks is three chances to disagree about which row is which.
enum At {
    Job(usize),
    Step(usize, usize),
    Nothing,
}

pub struct Steps {
    repo: String,
    run: Run,
    multi: bool,
    fetch: Arc<Fetcher>,
    jobs: Vec<Job>,
    open: Vec<bool>,
    epoch_seen: u64,
    jobs_due: Option<Instant>,
    sel: usize,
    status: String,
}

impl Steps {
    pub fn open(repo: &str, run: Run, multi: bool, fetch: Arc<Fetcher>) -> Self {
        let mut me = Self {
            repo: repo.to_string(),
            run,
            multi,
            fetch,
            jobs: Vec::new(),
            open: Vec::new(),
            epoch_seen: 0,
            jobs_due: None,
            sel: 0,
            status: String::new(),
        };
        // Already in hand whenever the parent screen's pane had it, which is
        // every time you arrive by pressing enter on a run you were looking at.
        me.fetch.request(me.jobs_req());
        me.sync();
        me
    }

    fn jobs_req(&self) -> Req {
        Req::Jobs {
            run: self.run.id,
            attempt: self.run.run_attempt,
            persist: self.run.verdict().done(),
        }
    }

    fn sync(&mut self) {
        let Some(Got::Jobs(jobs)) = self.fetch.get(&self.jobs_req()) else {
            return;
        };
        let first = self.jobs.is_empty();
        self.jobs = jobs.as_ref().clone();
        // Opened on the FIRST arrival only. Recomputing it on every five-second
        // refresh would reopen a job you had just closed, which is the kind of
        // bug that reads as the keyboard not working.
        if first {
            let any_failed = self.jobs.iter().any(|j| j.verdict() == Verdict::Failed);
            self.open = self
                .jobs
                .iter()
                .map(|j| !any_failed || j.verdict() == Verdict::Failed)
                .collect();
            self.sel = self.initial_sel();
        } else if self.open.len() != self.jobs.len() {
            // A run can grow jobs while it runs -- a `needs:` chain creates
            // them as its dependencies finish -- so the flags have to follow
            // the list rather than assume its length.
            self.open.resize(self.jobs.len(), false);
        }
        self.jobs_due = (!self.run.verdict().done()).then(|| Instant::now() + JOBS_EVERY);
        self.want_logs();
    }

    /// Fetch the logs worth having: the failed jobs', plus whichever job the
    /// cursor is in. Both are completed-only, since GitHub serves nothing for a
    /// job still running.
    fn want_logs(&self) {
        for job in &self.jobs {
            if job.verdict() == Verdict::Failed && job.has_log() {
                self.fetch.request(Req::Log { job: job.id });
            }
        }
        if let Some(j) = self.job_under_cursor() {
            if self.jobs[j].has_log() {
                self.fetch.request(Req::Log {
                    job: self.jobs[j].id,
                });
            }
        }
    }

    fn job_under_cursor(&self) -> Option<usize> {
        match self.at(self.sel) {
            At::Job(j) | At::Step(j, _) => Some(j),
            At::Nothing => None,
        }
    }

    fn at(&self, sel: usize) -> At {
        let mut row = 0;
        for (j, job) in self.jobs.iter().enumerate() {
            if sel == row {
                return At::Job(j);
            }
            row += 1;
            if self.open.get(j).copied().unwrap_or(false) {
                for s in 0..job.steps.len() {
                    if sel == row {
                        return At::Step(j, s);
                    }
                    row += 1;
                }
            }
        }
        At::Nothing
    }

    /// The row to open on: the first failed step, else the first failed job,
    /// else the top.
    ///
    /// Asked of the screen rather than computed by the caller for the reason
    /// `Screen::initial_sel` exists -- the answer depends on which jobs this
    /// screen decided to open, and nothing outside it knows that.
    fn initial_sel(&self) -> usize {
        let mut row = 0;
        let mut first_failed_job = None;
        for (j, job) in self.jobs.iter().enumerate() {
            let job_row = row;
            if job.verdict() == Verdict::Failed && first_failed_job.is_none() {
                first_failed_job = Some(job_row);
            }
            row += 1;
            if self.open.get(j).copied().unwrap_or(false) {
                for step in &job.steps {
                    if step.verdict() == Verdict::Failed {
                        return row;
                    }
                    row += 1;
                }
            }
        }
        first_failed_job.unwrap_or(0)
    }

    fn log_of(&self, job: u64) -> Option<String> {
        match self.fetch.get(&Req::Log { job }) {
            Some(Got::Log(l)) => Some(l.as_ref().clone()),
            _ => None,
        }
    }

    /// Fetch-and-wait, for the pager. See `Fetcher::block_on`.
    fn log_now(&mut self, job: u64) -> Option<String> {
        self.fetch.block_on(&[Req::Log { job }], PAGER_WAIT);
        let got = self.log_of(job);
        if got.is_none() {
            self.status = "the log did not arrive".into();
        }
        got
    }

    fn browse(&mut self, at: &At) -> Flow {
        let url = match at {
            At::Job(j) => self.jobs[*j]
                .html_url
                .clone()
                .unwrap_or_else(|| self.run.html_url.clone()),
            _ => self.run.html_url.clone(),
        };
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
}

impl Screen for Steps {
    fn title(&self) -> String {
        format!(
            "{} \u{b7} #{} \u{b7} {}",
            self.repo,
            self.run.run_number,
            self.run.display_title.replace(['\t', '\n'], " ")
        )
    }

    fn initial_sel(&self) -> usize {
        Steps::initial_sel(self)
    }

    fn focus(&mut self, sel: usize) {
        self.sel = sel;
        self.status.clear();
        self.want_logs();
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
        if self.jobs_due.is_some_and(|d| t >= d) {
            self.jobs_due = Some(t + JOBS_EVERY);
            self.fetch.refresh(self.jobs_req());
            return Tick::Wake(IN_FLIGHT);
        }
        match self.jobs_due.map(|d| d.saturating_duration_since(t)) {
            Some(d) => Tick::Wake(d),
            None => Tick::Idle,
        }
    }

    fn rows(&mut self) -> Vec<Row> {
        if self.jobs.is_empty() {
            return vec![Row::leaf(if self.fetch.pending() {
                "fetching jobs\u{2026}"
            } else {
                "no jobs yet \u{2014} waiting for a runner"
            })];
        }
        let mut rows = Vec::new();
        for (j, job) in self.jobs.iter().enumerate() {
            let (badge, color) = job.verdict().badge();
            let mut r = Row::leaf(&job.name);
            r.group = true;
            r.expanded = self.open.get(j).copied().unwrap_or(false);
            rows.push(
                r.detail(job.elapsed().map(time::dur).unwrap_or_default())
                    .badged(badge, color),
            );
            if !self.open.get(j).copied().unwrap_or(false) {
                continue;
            }
            for step in &job.steps {
                let (badge, color) = step.verdict().badge();
                let mut r = Row::leaf(&step.name);
                r.depth = 1;
                rows.push(
                    r.detail(step.elapsed().map(time::dur).unwrap_or_default())
                        .badged(badge, color),
                );
            }
        }
        rows
    }

    fn pane(&mut self, sel: usize, cols: u16, rows: u16) -> Pane {
        let mut lines = render::run_header(&self.run, cols, self.multi);
        let room = rows.saturating_sub(lines.len() as u16);
        match self.at(sel) {
            At::Job(j) => {
                let job = self.jobs[j].clone();
                let log = job.has_log().then(|| self.log_of(job.id)).flatten();
                lines.extend(render::job_body(&job, log.as_deref(), cols, room));
            }
            At::Step(j, s) => {
                let job = self.jobs[j].clone();
                let step = job.steps[s].clone();
                let log = job.has_log().then(|| self.log_of(job.id)).flatten();
                lines.extend(render::step_body(&job, &step, log.as_deref(), cols, room));
            }
            At::Nothing => lines.push(format!("{DIM}nothing selected{OFF}")),
        }
        if !self.status.is_empty() {
            lines.push(String::new());
            lines.push(format!("{ORG}{}{OFF}", self.status));
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        self.status.clear();
        let at = self.at(sel);
        match (action, &at) {
            (Action::Activate | Action::Open, At::Job(j)) => {
                let j = *j;
                if let Some(flag) = self.open.get_mut(j) {
                    *flag = !*flag;
                }
                Flow::Dirty
            }
            (Action::Close, At::Job(j)) => {
                let j = *j;
                if let Some(flag) = self.open.get_mut(j) {
                    *flag = false;
                }
                Flow::Dirty
            }
            // On a step, `h` closes the job it belongs to -- the nvim thing to
            // do, and it beats making you move up to the parent row first.
            (Action::Close, At::Step(j, _)) => {
                let j = *j;
                if let Some(flag) = self.open.get_mut(j) {
                    *flag = false;
                }
                Flow::Dirty
            }
            (Action::Key('o'), _) => self.browse(&at),
            (Action::Key('r'), _) => {
                self.fetch.refresh(self.jobs_req());
                self.status = "refreshing\u{2026}".into();
                Flow::Dirty
            }
            // One key, one meaning, in both screens: `L` pages whatever the
            // cursor is on. The pane already shows a step's whole log, so this
            // is for the ones too long to fit -- which is exactly when the run
            // body said "enter to browse" and you came here.
            (Action::Key('L'), At::Job(j)) => {
                let job = self.jobs[*j].clone();
                if !job.has_log() {
                    self.status = "no log until the job completes".into();
                    return Flow::Dirty;
                }
                let name = format!("job-{}", job.id);
                match self.log_now(job.id) {
                    Some(log) => {
                        let body = logs::fmt_log(log.lines()).join("\n");
                        match pager(&name, &body) {
                            Some(argv) => Flow::Detach(argv),
                            None => Flow::Dirty,
                        }
                    }
                    None => Flow::Dirty,
                }
            }
            (Action::Key('L'), At::Step(j, s)) => {
                let job = self.jobs[*j].clone();
                let step = job.steps[*s].clone();
                if !job.has_log() {
                    self.status = "no log until the job completes".into();
                    return Flow::Dirty;
                }
                let name = format!("step-{}-{}", job.id, step.number);
                match self.log_now(job.id) {
                    Some(log) => {
                        let slice = logs::step_slice(
                            &log,
                            step.started_at.as_deref().unwrap_or(""),
                            step.completed_at.as_deref().unwrap_or(""),
                            &step.name,
                        );
                        let body = logs::fmt_log(slice).join("\n");
                        match pager(&name, &body) {
                            Some(argv) => Flow::Detach(argv),
                            None => Flow::Dirty,
                        }
                    }
                    None => Flow::Dirty,
                }
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        let what = match self.at(self.sel) {
            At::Job(_) => "enter open/close \u{b7} L whole job log",
            At::Step(_, _) => "L this step's log in a pager",
            At::Nothing => "j/k move",
        };
        format!("{what} \u{b7} o browser \u{b7} r refresh \u{b7} q back")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{JobList, RunList};

    fn run(concl: &str) -> Run {
        serde_json::from_str::<RunList>(&format!(
            r#"{{"workflow_runs":[{{"id":1,"display_title":"t","head_sha":"a","event":"push",
            "status":"completed","conclusion":"{concl}","html_url":"https://x",
            "created_at":"2026-08-25T19:30:00Z","run_number":1,"run_attempt":1}}]}}"#
        ))
        .expect("parses")
        .workflow_runs
        .remove(0)
    }

    const JOBS: &str = r#"{"jobs":[
      {"id":10,"name":"build","status":"completed","conclusion":"success",
       "started_at":"2026-08-25T19:30:02Z","completed_at":"2026-08-25T19:31:02Z",
       "steps":[{"number":1,"name":"checkout","status":"completed","conclusion":"success"},
                {"number":2,"name":"compile","status":"completed","conclusion":"success"}]},
      {"id":11,"name":"test","status":"completed","conclusion":"failure",
       "started_at":"2026-08-25T19:31:02Z","completed_at":"2026-08-25T19:35:02Z",
       "steps":[{"number":1,"name":"checkout","status":"completed","conclusion":"success"},
                {"number":2,"name":"cargo test","status":"completed","conclusion":"failure"}]}
    ]}"#;

    /// Built without a fetcher: these tests are about the tree, and a screen
    /// that needed the network to be walked would not be testable at all.
    fn screen(concl: &str, jobs_json: &str) -> Steps {
        let jobs = serde_json::from_str::<JobList>(jobs_json)
            .expect("parses")
            .jobs;
        let any_failed = jobs.iter().any(|j| j.verdict() == Verdict::Failed);
        let open = jobs
            .iter()
            .map(|j| !any_failed || j.verdict() == Verdict::Failed)
            .collect();
        Steps {
            repo: "roest1/dotfiles".into(),
            run: run(concl),
            multi: false,
            fetch: Arc::new(Fetcher::new("roest1/dotfiles")),
            jobs,
            open,
            epoch_seen: 0,
            jobs_due: None,
            sel: 0,
            status: String::new(),
        }
    }

    /// The invariant every tree screen in this repo carries: each selectable
    /// index resolves to the row actually drawn at it. Jobs collapse, so the
    /// mapping moves under it.
    fn walk_agrees(s: &mut Steps) {
        let rows = s.rows();
        for (i, row) in rows.iter().enumerate() {
            match s.at(i) {
                At::Job(j) => assert_eq!(row.label, s.jobs[j].name, "row {i}"),
                At::Step(j, k) => assert_eq!(row.label, s.jobs[j].steps[k].name, "row {i}"),
                At::Nothing => panic!("selectable row {i} ({}) resolves to nothing", row.label),
            }
        }
    }

    #[test]
    fn the_walk_matches_the_rows_in_every_shape() {
        let mut s = screen("failure", JOBS);
        walk_agrees(&mut s);
        s.open = vec![true, true];
        walk_agrees(&mut s);
        s.open = vec![false, false];
        walk_agrees(&mut s);
        s.open = vec![true, false];
        walk_agrees(&mut s);
    }

    /// You came here from a failure. The passing job's steps are rows that say
    /// what its own row said; on a matrix build they bury the one that matters.
    #[test]
    fn only_the_failed_job_opens_when_something_failed() {
        let s = screen("failure", JOBS);
        assert_eq!(s.open, vec![false, true]);
    }

    /// And a run opened out of curiosity should not be a list of closed boxes.
    #[test]
    fn everything_opens_when_nothing_failed() {
        let all_green = JOBS.replace("\"failure\"", "\"success\"");
        let s = screen("success", &all_green);
        assert_eq!(s.open, vec![true, true]);
    }

    /// The cursor lands on the failed STEP, not on the job holding it -- the
    /// reason you drilled in is one row further down.
    #[test]
    fn it_opens_on_the_failed_step() {
        let mut s = screen("failure", JOBS);
        let want = Steps::initial_sel(&s);
        let rows = s.rows();
        assert_eq!(rows[want].label, "cargo test");
    }

    /// A `needs:` chain creates jobs as its dependencies finish, so the flags
    /// have to follow the list rather than assume its length -- indexing
    /// `open` by a job that arrived later would panic mid-refresh.
    #[test]
    fn a_run_that_grows_jobs_does_not_lose_its_open_flags() {
        let mut s = screen("failure", JOBS);
        s.open = vec![true];
        walk_agrees(&mut s);
        s.open = vec![true, true, true, true];
        walk_agrees(&mut s);
    }

    #[test]
    fn a_run_with_no_jobs_says_so_rather_than_drawing_nothing() {
        let mut s = screen("success", r#"{"jobs":[]}"#);
        let rows = s.rows();
        assert_eq!(rows.len(), 1);
        assert!(matches!(s.at(0), At::Nothing));
    }
}
