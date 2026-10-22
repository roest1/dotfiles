//! Talking to GitHub, off the main thread, with the immutable half kept.
//!
//! ## Why it still shells out to `gh`
//!
//! Auth is solved over there, and solved for cases this would otherwise have to
//! learn: a token in the keyring, a token in the environment, an enterprise
//! host, a refresh mid-session. `gh api` returns the same JSON a direct call
//! would, and serde does not care who fetched it. Going direct would buy
//! nothing and cost an auth implementation -- which is the one kind of code
//! that fails for other people and not for you.
//!
//! ## Why it is threaded
//!
//! Every call here is a network round trip of 100ms to several seconds, and
//! `reticle`'s loop must stay at 60fps through all of them. So requests go to
//! a small pool and results come back through a shared map, with an epoch
//! counter so the screen can tell "something landed" from "still waiting"
//! without diffing it. That is `font::fetch::Fetcher`'s shape, deliberately:
//! it is the same problem with a different payload, and a second design for it
//! would be a second thing to get wrong.
//!
//! ## What is cached across sessions, and why only that
//!
//! A COMPLETED run's jobs and a COMPLETED job's log can never change. They are
//! written to `~/.cache/dotfiles-github` and read from there forever, so
//! revisiting last week's failure is instant in a shell that has never seen
//! it. Nothing else is cached at all: a run list is a question about now, and
//! a live run's jobs are the thing you are watching change.
//!
//! The cache is keyed by `(run, attempt)`, not by run. A rerun is the SAME run
//! id with a new attempt and entirely new jobs, so a key on id alone would
//! serve the previous attempt's results for as long as the cache survived --
//! and the bash implementation had to delete cache files on rerun to avoid
//! exactly that. Putting the attempt in the key retires the deletion.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::model::{Job, JobList, Run, RunList};

/// How long a cached artifact stays useful. Two weeks is long enough to cover
/// "what broke when I was away" and short enough that the directory does not
/// become a disk-space question nobody asked for.
const KEEP_DAYS: u64 = 14;

pub fn cache_dir() -> PathBuf {
    let base = std::env::var("XDG_CACHE_HOME")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache"));
    base.join("dotfiles-github")
}

/// One `gh api` call. Errors come back as the first line of stderr, which is
/// where `gh` puts the thing worth reading -- `gh: Not Found (HTTP 404)` rather
/// than a stack of request detail.
fn api(args: &[String]) -> Result<Vec<u8>, String> {
    let out = Command::new("gh")
        .arg("api")
        .args(args)
        .output()
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => "gh is not installed".to_string(),
            _ => format!("could not run gh: {e}"),
        })?;
    if out.status.success() {
        return Ok(out.stdout);
    }
    let msg = String::from_utf8_lossy(&out.stderr);
    Err(msg
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("gh api failed")
        .trim()
        .to_string())
}

/// What a screen can ask for.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Req {
    /// The run list. `query` is everything after the `?`, built by the screen
    /// so the scope it is showing and the scope it fetched cannot disagree.
    Runs { query: String },
    /// One run's jobs and their steps.
    ///
    /// `persist` is the caller's promise that this run has REACHED a terminal
    /// state, so the answer is immutable and may be written to disk. The screen
    /// knows it from the list it is already showing, which saves the second
    /// `gh api` call the bash implementation made to ask the run its own
    /// status. The staleness is safe in the one direction that matters: a list
    /// up to fifteen seconds old can say "running" about a run that has just
    /// finished, and then we merely decline to cache something we could have
    /// cached. It can never say "completed" about a run that is still going,
    /// because completed is terminal.
    Jobs {
        run: u64,
        attempt: u32,
        persist: bool,
    },
    /// One completed job's log, whole.
    Log { job: u64 },
}

impl Req {
    fn key(&self) -> String {
        match self {
            Req::Runs { query } => format!("runs?{query}"),
            Req::Jobs { run, attempt, .. } => format!("jobs:{run}:{attempt}"),
            Req::Log { job } => format!("log:{job}"),
        }
    }

    /// Where this answer lives between sessions, if it is allowed to.
    fn cache_path(&self, repo: &str) -> Option<PathBuf> {
        let dir = cache_dir().join(repo);
        match self {
            Req::Jobs {
                run,
                attempt,
                persist,
            } if *persist => Some(dir.join(format!("run-{run}-a{attempt}.jobs.json"))),
            // Only ever requested for a completed job, so it is already
            // immutable by the time we are here -- `Job::has_log` is the guard.
            Req::Log { job } => Some(dir.join(format!("job-{job}.log"))),
            _ => None,
        }
    }
}

#[derive(Clone)]
pub enum Got {
    Pending,
    Runs(Arc<Vec<Run>>),
    Jobs(Arc<Vec<Job>>),
    Log(Arc<String>),
    Failed(String),
}

type Shared = Arc<Mutex<HashMap<String, Got>>>;

pub struct Fetcher {
    repo: String,
    tx: Sender<Req>,
    state: Shared,
    /// Bumped by a worker whenever anything lands, so a screen can notice in
    /// one atomic read instead of walking the map every frame.
    epoch: Arc<AtomicU64>,
}

fn parse(req: &Req, bytes: Vec<u8>) -> Got {
    match req {
        Req::Runs { .. } => match serde_json::from_slice::<RunList>(&bytes) {
            Ok(l) => Got::Runs(Arc::new(l.workflow_runs)),
            Err(e) => Got::Failed(format!("unreadable run list: {e}")),
        },
        Req::Jobs { .. } => match serde_json::from_slice::<JobList>(&bytes) {
            Ok(l) => Got::Jobs(Arc::new(l.jobs)),
            Err(e) => Got::Failed(format!("unreadable job list: {e}")),
        },
        // A log is bytes, not JSON, and is not necessarily valid UTF-8 -- a
        // test printing raw output can put anything in it. Lossy rather than
        // an error: the surrounding lines are still what you came to read.
        Req::Log { .. } => Got::Log(Arc::new(String::from_utf8_lossy(&bytes).into_owned())),
    }
}

fn fetch(repo: &str, req: &Req) -> Got {
    let args: Vec<String> = match req {
        Req::Runs { query } => vec![format!("repos/{repo}/actions/runs?{query}")],
        Req::Jobs { run, .. } => vec![format!("repos/{repo}/actions/runs/{run}/jobs?per_page=100")],
        Req::Log { job } => vec![
            "--allow-escape-sequences".into(),
            format!("repos/{repo}/actions/jobs/{job}/logs"),
        ],
    };
    match api(&args) {
        Ok(bytes) => {
            // Written only after it parses. A truncated or error-page body
            // cached as if it were an answer is a failure that survives
            // restarts, which is the worst kind this file can produce.
            let got = parse(req, bytes.clone());
            if !matches!(got, Got::Failed(_)) {
                if let Some(path) = req.cache_path(repo) {
                    if let Some(dir) = path.parent() {
                        let _ = std::fs::create_dir_all(dir);
                    }
                    let tmp = path.with_extension("part");
                    if std::fs::write(&tmp, &bytes).is_ok() {
                        let _ = std::fs::rename(&tmp, &path);
                    }
                }
            }
            got
        }
        Err(e) => Got::Failed(e),
    }
}

impl Fetcher {
    /// Four workers. A run's body wants its jobs and the logs of two or three
    /// failed jobs at once, so a pool of one would serialise exactly the case
    /// the screen is built around; much more than four and a repo with twenty
    /// failed jobs would open twenty connections to be polite about.
    pub fn new(repo: &str) -> Self {
        let (tx, rx) = mpsc::channel::<Req>();
        let state: Shared = Arc::new(Mutex::new(HashMap::new()));
        let epoch = Arc::new(AtomicU64::new(0));
        let rx = Arc::new(Mutex::new(rx));
        for _ in 0..4 {
            let rx = Arc::clone(&rx);
            let state = Arc::clone(&state);
            let epoch = Arc::clone(&epoch);
            let repo = repo.to_string();
            thread::spawn(move || loop {
                // The lock is held only for the recv, never across the fetch,
                // or the pool would be a queue of one.
                let req = {
                    let guard = match rx.lock() {
                        Ok(g) => g,
                        Err(_) => return,
                    };
                    match guard.recv() {
                        Ok(r) => r,
                        Err(_) => return,
                    }
                };
                let got = fetch(&repo, &req);
                if let Ok(mut g) = state.lock() {
                    g.insert(req.key(), got);
                }
                epoch.fetch_add(1, Ordering::Relaxed);
            });
        }
        prune(repo);
        Self {
            repo: repo.to_string(),
            tx,
            state,
            epoch,
        }
    }

    pub fn epoch(&self) -> u64 {
        self.epoch.load(Ordering::Relaxed)
    }

    pub fn get(&self, req: &Req) -> Option<Got> {
        self.state.lock().ok()?.get(&req.key()).cloned()
    }

    pub fn pending(&self) -> bool {
        self.state
            .lock()
            .map(|g| g.values().any(|v| matches!(v, Got::Pending)))
            .unwrap_or(false)
    }

    /// Ask once. Idempotent, so a screen can request the same thing on every
    /// cursor move -- which is exactly what prefetching around the selection
    /// does -- without re-fetching anything.
    pub fn request(&self, req: Req) {
        let Ok(mut guard) = self.state.lock() else {
            return;
        };
        let key = req.key();
        if guard.contains_key(&key) {
            return;
        }
        // Resolved from disk HERE rather than in the worker, which is the
        // lesson `Fetcher::request` in `font` already paid for: leaving it to
        // the thread meant something cached in a previous session still went
        // Pending -> queue -> thread -> Ready, so every revisit flashed
        // "fetching…" for no reason. A file read costs microseconds.
        if let Some(got) = self.cached(&req) {
            guard.insert(key, got);
            return;
        }
        guard.insert(key, Got::Pending);
        drop(guard);
        let _ = self.tx.send(req);
    }

    /// Ask again, ignoring what we already have.
    ///
    /// For the two clocks the Actions screen runs on: the run list going stale,
    /// and a live run's jobs changing under the cursor. It deliberately does
    /// NOT clear the existing answer -- the screen keeps rendering the last
    /// good one while the new one is in flight, so a refresh is invisible
    /// rather than a flicker through an empty pane.
    pub fn refresh(&self, req: Req) {
        let Ok(mut guard) = self.state.lock() else {
            return;
        };
        if matches!(guard.get(&req.key()), Some(Got::Pending)) {
            return; // already in flight; a second copy would just race it
        }
        guard.entry(req.key()).or_insert(Got::Pending);
        drop(guard);
        let _ = self.tx.send(req);
    }

    /// Ask for all of these and WAIT, up to `limit`.
    ///
    /// The one blocking call here, and it exists for one caller: paging a log.
    /// Everything else resolves into the pane asynchronously because the pane
    /// is redrawn constantly anyway, but a pager has to hand the terminal over
    /// with the whole text in hand -- there is no later frame to fill in.
    ///
    /// Blocking on an explicit keypress is honest in a way that blocking on
    /// cursor movement is not: you pressed a key and asked for a thing. The
    /// requests still go through the pool, so several logs arrive in parallel
    /// rather than one after another, and the timeout means a hung network
    /// costs a few seconds rather than the session.
    pub fn block_on(&self, reqs: &[Req], limit: std::time::Duration) -> bool {
        for r in reqs {
            self.request(r.clone());
        }
        let deadline = std::time::Instant::now() + limit;
        loop {
            let settled = reqs
                .iter()
                .all(|r| !matches!(self.get(r), Some(Got::Pending) | None));
            if settled {
                return true;
            }
            if std::time::Instant::now() >= deadline {
                return false;
            }
            thread::sleep(std::time::Duration::from_millis(25));
        }
    }

    fn cached(&self, req: &Req) -> Option<Got> {
        let path = req.cache_path(&self.repo)?;
        let bytes = std::fs::read(&path).ok()?;
        if bytes.is_empty() {
            return None;
        }
        let got = parse(req, bytes);
        // A cache file that no longer parses -- a format change, a truncated
        // write from a killed process -- is treated as absent rather than as
        // an error, so the next request repairs it.
        (!matches!(got, Got::Failed(_))).then_some(got)
    }
}

/// Drop cached artifacts older than `KEEP_DAYS`, once per process.
///
/// Best-effort throughout: a cache that cannot be pruned is a disk-space
/// question, and failing to open a screen over it would be the wrong trade.
fn prune(repo: &str) {
    let dir = cache_dir().join(repo);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return;
    };
    let cutoff = std::time::Duration::from_secs(KEEP_DAYS * 86_400);
    for e in entries.flatten() {
        let stale = e
            .metadata()
            .and_then(|m| m.modified())
            .map(|t| t.elapsed().map(|age| age > cutoff).unwrap_or(false))
            .unwrap_or(false);
        if stale {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The key is the cache's correctness. Two attempts of one run are two
    /// different sets of jobs, and `persist` must not be part of the key --
    /// a run fetched while live and again once finished is the same question,
    /// and keying on it would fetch twice and cache neither.
    #[test]
    fn a_rerun_is_a_different_key_but_persistence_is_not() {
        let live = Req::Jobs {
            run: 7,
            attempt: 1,
            persist: false,
        };
        let done = Req::Jobs {
            run: 7,
            attempt: 1,
            persist: true,
        };
        let again = Req::Jobs {
            run: 7,
            attempt: 2,
            persist: true,
        };
        assert_eq!(live.key(), done.key());
        assert_ne!(done.key(), again.key());
    }

    /// Only the immutable answers get a file. A run list is a question about
    /// now, and a live run's jobs are the thing being watched change -- caching
    /// either would show yesterday's CI with total confidence.
    #[test]
    fn only_what_cannot_change_is_written_to_disk() {
        let repo = "roest1/dotfiles";
        assert!(Req::Runs {
            query: "per_page=40".into()
        }
        .cache_path(repo)
        .is_none());
        assert!(Req::Jobs {
            run: 7,
            attempt: 1,
            persist: false
        }
        .cache_path(repo)
        .is_none());
        let jobs = Req::Jobs {
            run: 7,
            attempt: 2,
            persist: true,
        }
        .cache_path(repo)
        .expect("completed jobs are cached");
        assert!(
            jobs.ends_with("roest1/dotfiles/run-7-a2.jobs.json"),
            "{jobs:?}"
        );
        let log = Req::Log { job: 99 }
            .cache_path(repo)
            .expect("logs are cached");
        assert!(log.ends_with("roest1/dotfiles/job-99.log"), "{log:?}");
    }
}
