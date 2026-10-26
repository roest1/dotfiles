//! The pane bodies: a run, a job, a step.
//!
//! Kept apart from the screens for the reason `font` keeps one `measure`: the
//! bash implementation rendered a job line in three places -- the run body, the
//! jobs list and the job preview -- and the three had already drifted on which
//! field decided a job's colour. There is one function per body here and the
//! screens call them.
//!
//! Everything returns `Vec<String>` with ANSI already in it, because that is
//! what `Pane` takes and because a log line the tool coloured itself has to
//! pass through untouched.

use crate::logs;
use crate::model::{Job, Run, Step, Verdict};
use crate::paint::{rule, BOLD, DIM, GRY, OFF, ORG, PUR, RED};
use crate::time;

/// The most log lines to inline under one failed step, however much room there
/// is.
///
/// Eighteen is the fzf implementation's number and worth keeping: enough to
/// hold a Rust panic with its backtrace header or a failed assertion with its
/// diff, short enough that three failed jobs still fit on one screen.
const RUN_TAIL: usize = 18;

/// The fewest worth showing. Below about four lines a tail is a tease -- you
/// can see that something failed and not what -- so a body with no room for
/// that says so and sends you to the pager instead.
const MIN_TAIL: usize = 4;

/// Lines of chrome a body spends on things that are not log: the status line,
/// the blank after it, the blank before the summary, and the summary.
const CHROME: usize = 4;

/// How many log lines each failed step may show.
///
/// **The pane does not scroll.** That is the fact this function exists for, and
/// it is easy to forget because every other log view in this repo's history
/// did: fzf's preview scrolled with the mouse and a pager scrolls by
/// definition, so "print it all and let them scroll" was always available
/// before. Here, a body longer than the pane is silently CUT by `draw_pane` --
/// and a failed step's log is the one thing whose end matters, because that is
/// where the error is. Printing four hundred lines of `apt-get` into a
/// forty-row pane showed the runner installing chromium and hid the assertion
/// that failed.
///
/// So the budget is divided among the failed steps and each gets a TAIL. `L`
/// pages the whole thing, and the marker says so.
fn tail_budget(rows: u16, skeleton: usize, failed: usize) -> usize {
    if failed == 0 {
        return 0;
    }
    let room = (rows as usize).saturating_sub(skeleton + CHROME);
    (room / failed).clamp(0, RUN_TAIL)
}

/// `name ······· ` -- padded to `width` with a leading space and middots.
///
/// The dots are not decoration: a duration right-aligned after a
/// variable-length job name is unreadable as a column, and a run of spaces
/// loses the eye on a wide pane. Same device the fzf body used.
fn dotted(name: &str, width: usize) -> String {
    let n: String = truncate(name, width.saturating_sub(2));
    let pad = width.saturating_sub(n.chars().count());
    if pad > 1 {
        format!("{n} {}", "\u{b7}".repeat(pad - 1))
    } else {
        format!("{n} ")
    }
}

fn truncate(s: &str, w: usize) -> String {
    if s.chars().count() <= w {
        return s.to_string();
    }
    s.chars().take(w.saturating_sub(1)).collect::<String>() + "\u{2026}"
}

fn right(s: &str, w: usize) -> String {
    let n = s.chars().count();
    if n >= w {
        return s.to_string();
    }
    format!("{}{s}", " ".repeat(w - n))
}

/// The lines that never change: workflow, number, branch, title, who and why.
///
/// Printed from the run list alone, so they are on screen before any further
/// request is made. That ordering is the screen's whole claim -- the pane is
/// never empty while something is in flight.
pub fn run_header(run: &Run, cols: u16, show_workflow: bool) -> Vec<String> {
    let w = cols as usize;
    let mut out = Vec::new();
    let mut top = String::new();
    if show_workflow {
        if let Some(name) = &run.name {
            top.push_str(&format!("{BOLD}{PUR}{name}{OFF} "));
        }
    }
    top.push_str(&format!("{DIM}#{}{OFF}", run.run_number));
    if run.run_attempt > 1 {
        top.push_str(&format!(" {DIM}(attempt {}){OFF}", run.run_attempt));
    }
    if let Some(br) = &run.head_branch {
        top.push_str(&format!("  {ORG}{br}{OFF}"));
    }
    out.push(top);
    out.push(format!("{BOLD}{}{OFF}", truncate(&run.display_title, w)));
    out.push(format!(
        "{GRY}{} \u{b7} {} \u{b7} {} ago{OFF}",
        run.event.replace('_', " "),
        run.actor_login(),
        time::age(run.age())
    ));
    out.push(rule(cols));
    out
}

/// The status line: verdict, how long, and when it started.
fn status_line(run: &Run) -> String {
    let v = run.verdict();
    let mut s = format!("{} {BOLD}{}{}{OFF}", v.glyph(), v.color(), run.state());
    if let Some(d) = run.elapsed() {
        s.push_str(&format!("{DIM} \u{b7} {}", time::dur(d)));
        if !v.done() {
            s.push_str(" so far");
        }
        // The clock time, not the date: you are looking at this because
        // something happened today.
        if let Some(hhmm) = run.started().get(11..16) {
            s.push_str(&format!(" \u{b7} started {hhmm} UTC"));
        }
        s.push_str(OFF);
    }
    s
}

/// A one-line tally, which is the answer to "is it green" without reading the
/// job list. Only the non-zero buckets appear.
fn summary(jobs: &[Job]) -> String {
    if jobs.is_empty() {
        return format!("{DIM}no jobs yet \u{2014} waiting for a runner{OFF}");
    }
    let count = |v: Verdict| jobs.iter().filter(|j| j.verdict() == v).count();
    let mut parts: Vec<String> = Vec::new();
    for (v, word) in [
        (Verdict::Passed, "passed"),
        (Verdict::Failed, "failed"),
        (Verdict::Running, "running"),
        (Verdict::Queued, "queued"),
        (Verdict::Cancelled, "cancelled"),
        (Verdict::Skipped, "skipped"),
        (Verdict::Other, "other"),
    ] {
        let n = count(v);
        if n > 0 {
            parts.push(format!("{} {n} {word}", v.glyph()));
        }
    }
    parts.join("   ")
}

/// A failed step's log tail, indented under its line.
///
/// `log` is `None` while the fetch is in flight, and that is a different thing
/// from a step with no output -- saying so is the difference between "wait a
/// moment" and "there is nothing here".
fn step_tail(log: Option<&str>, step: &Step, name_hint: &str, tail: usize) -> Vec<String> {
    let bar = format!("     {RED}\u{2503}{OFF} ");
    let Some(log) = log else {
        return vec![format!("     {DIM}\u{2503} fetching the log\u{2026}{OFF}")];
    };
    let slice = logs::step_slice(
        log,
        step.started_at.as_deref().unwrap_or(""),
        step.completed_at.as_deref().unwrap_or(""),
        name_hint,
    );
    if slice.is_empty() {
        return vec![format!(
            "     {DIM}\u{2503} (no output captured for this step){OFF}"
        )];
    }
    let mut out = Vec::new();
    if tail < MIN_TAIL {
        return vec![format!(
            "     {DIM}\u{2503} {} lines \u{2014} no room here, L pages it{OFF}",
            slice.len()
        )];
    }
    if slice.len() > tail {
        out.push(format!(
            "     {DIM}\u{2503} \u{25b4} {} earlier lines \u{2014} L pages the whole log{OFF}",
            slice.len() - tail + 1
        ));
    }
    // The marker occupies one of the lines it is accounting for, so the tail
    // shrinks by one rather than overflowing the budget it was given.
    let tail = if slice.len() > tail { tail - 1 } else { tail };
    let from = slice.len().saturating_sub(tail);
    out.extend(
        logs::fmt_log(slice[from..].iter().copied())
            .into_iter()
            .map(|l| format!("{bar}{l}")),
    );
    out
}

/// One job's line, plus its steps when they are worth showing.
///
/// Steps are expanded for a FAILED or RUNNING job only. A passing job's twelve
/// green steps are twelve lines saying the same thing as its own line, and on a
/// matrix build they push the failure off the pane -- which is the one thing
/// this body exists to show.
fn job_block(job: &Job, log: Option<&str>, width: usize, tail: usize) -> Vec<String> {
    let v = job.verdict();
    let mut out = Vec::new();
    let emphasis = match v {
        Verdict::Failed => format!("{BOLD}{RED}"),
        Verdict::Running | Verdict::Queued => v.color().to_string(),
        _ => String::new(),
    };
    out.push(format!(
        "{} {emphasis}{}{OFF} {DIM}{}{OFF}",
        v.glyph(),
        dotted(&job.name, width.saturating_sub(12)),
        right(&job.elapsed().map(time::dur).unwrap_or_default(), 6)
    ));
    if !expands(v) {
        return out;
    }
    for step in &job.steps {
        let sv = step.verdict();
        let mark = match sv {
            Verdict::Running => format!("{}\u{25b6} ", sv.color()),
            Verdict::Queued => format!("{DIM}\u{25cb} "),
            _ => format!("{} ", sv.glyph()),
        };
        let tint = match sv {
            Verdict::Failed => RED,
            Verdict::Running => sv.color(),
            Verdict::Queued => DIM,
            _ => "",
        };
        out.push(format!(
            "   {mark}{tint}{}{OFF} {DIM}{}{OFF}",
            dotted(&step.name, width.saturating_sub(15)),
            right(&step.elapsed().map(time::dur).unwrap_or_default(), 6)
        ));
        if sv == Verdict::Failed && step.started_at.is_some() {
            out.extend(step_tail(log, step, &step.name, tail));
        }
    }
    out
}

/// A run's whole body: status, every job, the failures opened up, and a tally.
///
/// `jobs` is `None` until the fetch lands. The header is already on screen by
/// then, so this is the only part that has to say it is waiting.
pub fn run_body(
    run: &Run,
    jobs: Option<&[Job]>,
    log_for: &dyn Fn(u64) -> Option<String>,
    cols: u16,
    rows: u16,
) -> Vec<String> {
    let width = (cols as usize).clamp(24, 96);
    let mut out = vec![status_line(run), String::new()];
    let Some(jobs) = jobs else {
        out.push(format!("{DIM}fetching jobs\u{2026}{OFF}"));
        return out;
    };
    // Measured before anything is rendered, because the budget each failed step
    // gets depends on how much room the STRUCTURE needs -- and the structure is
    // what must survive a pane too small for everything.
    let tail = tail_budget(rows, skeleton_lines(jobs), failed_steps(jobs));
    for job in jobs {
        let log = if job.verdict() == Verdict::Failed && job.has_log() {
            log_for(job.id)
        } else {
            None
        };
        out.extend(job_block(job, log.as_deref(), width, tail));
    }
    out.push(String::new());
    out.push(summary(jobs));
    out
}

/// Rows the job/step structure of a run body needs, logs excluded.
fn skeleton_lines(jobs: &[Job]) -> usize {
    jobs.iter()
        .map(|j| {
            1 + if expands(j.verdict()) {
                j.steps.len()
            } else {
                0
            }
        })
        .sum()
}

/// Failed steps that will be asked for a log, which is what the budget splits
/// between.
fn failed_steps(jobs: &[Job]) -> usize {
    jobs.iter()
        .filter(|j| expands(j.verdict()))
        .flat_map(|j| j.steps.iter())
        .filter(|s| s.verdict() == Verdict::Failed && s.started_at.is_some())
        .count()
}

/// Whether a job's steps are listed under it. Failures and anything still
/// going; not a pass, a skip or a cancellation.
fn expands(v: Verdict) -> bool {
    !matches!(v, Verdict::Passed | Verdict::Skipped | Verdict::Cancelled)
}

/// The word for a job's or step's current state: its conclusion once it has
/// one, its status while it does not, underscores spelled out.
fn state_word(status: Option<&str>, conclusion: Option<&str>) -> String {
    conclusion.or(status).unwrap_or("unknown").replace('_', " ")
}

/// One job, with every failed step's log in full rather than tailed.
pub fn job_body(job: &Job, log: Option<&str>, cols: u16, rows: u16) -> Vec<String> {
    let width = (cols as usize).clamp(24, 96);
    let v = job.verdict();
    let mut detail = state_word(job.status.as_deref(), job.conclusion.as_deref());
    if let Some(d) = job.elapsed() {
        detail.push_str(&format!(" \u{b7} {}", time::dur(d)));
        if !v.done() {
            detail.push_str(" so far");
        }
    }
    if let Some(runner) = &job.runner_name {
        detail.push_str(&format!(" \u{b7} {runner}"));
    }
    let mut out = vec![
        format!("{} {BOLD}{}{OFF}", v.glyph(), truncate(&job.name, width)),
        format!("{}{detail}{OFF}", v.color()),
        rule(cols),
    ];
    // `job_block` opens with the job's own line, which is already the header
    // here -- so the steps are taken and the line is dropped.
    //
    // The tail is budgeted exactly as the run body's is, and for the same
    // reason: this pane does not scroll either. Asking one job about itself
    // simply leaves more room per failed step than asking a whole run did.
    let one = std::slice::from_ref(job);
    let tail = tail_budget(rows, skeleton_lines(one), failed_steps(one));
    let mut body = job_block(job, log, width, tail);
    if !body.is_empty() {
        body.remove(0);
    }
    out.extend(body);
    out
}

/// One step: where it sits, what it did, and its whole log.
pub fn step_body(job: &Job, step: &Step, log: Option<&str>, cols: u16, rows: u16) -> Vec<String> {
    let v = step.verdict();
    let mut out = vec![
        format!(
            "{GRY}{}{OFF} {DIM}\u{203a}{OFF} {BOLD}{}{OFF}",
            job.name, step.name
        ),
        format!(
            "{} {}{}{OFF}{DIM}{}{OFF}",
            v.glyph(),
            v.color(),
            state_word(step.status.as_deref(), step.conclusion.as_deref()),
            step.elapsed()
                .map(|d| format!(" \u{b7} {}", time::dur(d)))
                .unwrap_or_default()
        ),
        rule(cols),
    ];
    match v {
        Verdict::Skipped => out.push(format!("{DIM}skipped{OFF}")),
        Verdict::Running | Verdict::Queued => out.push(format!(
            "{} {}\u{2014} the log lands when the job completes{OFF}",
            v.glyph(),
            v.color()
        )),
        _ => match log {
            None => out.push(format!("{DIM}fetching the log\u{2026}{OFF}")),
            Some(log) => {
                let slice = logs::step_slice(
                    log,
                    step.started_at.as_deref().unwrap_or(""),
                    step.completed_at.as_deref().unwrap_or(""),
                    &step.name,
                );
                if slice.is_empty() {
                    out.push(format!("{DIM}(no output captured for this step){OFF}"));
                } else {
                    // One step, the whole pane: the most room any of these
                    // bodies has. Still a tail, because this pane does not
                    // scroll and a step's error is at its end.
                    let room = (rows as usize).saturating_sub(out.len() + 2);
                    if slice.len() > room && room > 0 {
                        out.push(format!(
                            "{DIM}\u{25b4} {} earlier lines \u{2014} L pages the whole log{OFF}",
                            slice.len() - room + 1
                        ));
                        let from = slice.len() - room + 1;
                        out.extend(logs::fmt_log(slice[from..].iter().copied()));
                    } else {
                        out.extend(logs::fmt_log(slice));
                    }
                }
            }
        },
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{JobList, RunList};

    fn run(status: &str, concl: Option<&str>) -> Run {
        let c = concl
            .map(|c| format!(r#","conclusion":"{c}""#))
            .unwrap_or_default();
        let json = format!(
            r#"{{"workflow_runs":[{{"id":1,"name":"ci","display_title":"fix the thing",
            "head_branch":"feat/x","head_sha":"abc","event":"push","status":"{status}"{c},
            "html_url":"https://x","created_at":"2026-08-25T19:30:00Z",
            "run_started_at":"2026-08-25T19:30:02Z","updated_at":"2026-08-25T19:35:02Z",
            "run_number":12,"run_attempt":1,"actor":{{"login":"roest1"}}}}]}}"#
        );
        serde_json::from_str::<RunList>(&json)
            .expect("parses")
            .workflow_runs
            .remove(0)
    }

    fn jobs() -> Vec<Job> {
        serde_json::from_str::<JobList>(
            r#"{"jobs":[
              {"id":10,"name":"build","status":"completed","conclusion":"success",
               "started_at":"2026-08-25T19:30:02Z","completed_at":"2026-08-25T19:31:02Z",
               "steps":[{"number":1,"name":"Set up job","status":"completed","conclusion":"success",
                         "started_at":"2026-08-25T19:30:02Z","completed_at":"2026-08-25T19:30:03Z"}]},
              {"id":11,"name":"test","status":"completed","conclusion":"failure",
               "started_at":"2026-08-25T19:31:02Z","completed_at":"2026-08-25T19:35:02Z",
               "steps":[{"number":1,"name":"Run cargo test","status":"completed","conclusion":"failure",
                         "started_at":"2026-08-25T19:31:10Z","completed_at":"2026-08-25T19:35:00Z"}]}
            ]}"#,
        )
        .expect("parses")
        .jobs
    }

    fn plain(lines: &[String]) -> String {
        let joined = lines.join("\n");
        let mut out = String::new();
        let mut chars = joined.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for c in chars.by_ref() {
                    if c == 'm' {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    /// The header is built from the LIST alone, so it must be complete before
    /// any further request -- that is what makes the pane never empty.
    #[test]
    fn the_header_needs_nothing_fetched() {
        let r = run("completed", Some("failure"));
        let text = plain(&run_header(&r, 60, true));
        assert!(text.contains("ci"));
        assert!(text.contains("#12"));
        assert!(text.contains("feat/x"));
        assert!(text.contains("fix the thing"));
        assert!(text.contains("roest1"));
    }

    /// A rerun is the fact most easily missed when reading a failure, because
    /// everything else about the run looks identical.
    #[test]
    fn a_second_attempt_says_so() {
        let mut r = run("completed", Some("failure"));
        r.run_attempt = 3;
        assert!(plain(&run_header(&r, 60, true)).contains("attempt 3"));
    }

    /// The pane says what it is doing rather than going blank, in both the
    /// states where something is outstanding.
    #[test]
    fn a_body_with_nothing_fetched_says_it_is_fetching() {
        let r = run("in_progress", None);
        let text = plain(&run_body(&r, None, &|_| None, 60, 40));
        assert!(text.contains("in progress"));
        assert!(text.contains("so far"), "{text}");
        assert!(text.contains("fetching jobs"));
    }

    /// Steps open for the failure and stay shut for the pass. On a matrix build
    /// the passing jobs' steps are what push the failure off the pane.
    #[test]
    fn only_the_failing_job_opens_its_steps() {
        let text = plain(&run_body(
            &run("completed", Some("failure")),
            Some(&jobs()),
            &|_| None,
            60,
            40,
        ));
        assert!(!text.contains("Set up job"), "passing job expanded: {text}");
        assert!(text.contains("Run cargo test"));
        assert!(text.contains("1 passed"));
        assert!(text.contains("1 failed"));
    }

    /// "Waiting for the log" and "there was no output" are different answers
    /// and the pane must not use one to mean the other.
    #[test]
    fn a_missing_log_reads_differently_from_an_empty_one() {
        let waiting = plain(&run_body(
            &run("completed", Some("failure")),
            Some(&jobs()),
            &|_| None,
            60,
            40,
        ));
        assert!(waiting.contains("fetching the log"));
        let empty = plain(&run_body(
            &run("completed", Some("failure")),
            Some(&jobs()),
            &|_| Some(String::new()),
            60,
            40,
        ));
        assert!(empty.contains("no output captured"));
    }

    /// The tail is a tail: the last lines, with a count of what it hid. A body
    /// that silently dropped the earlier lines would read as the whole log.
    #[test]
    fn a_long_failure_is_tailed_and_says_how_much_it_hid() {
        let mut log = String::new();
        for i in 0..60 {
            log.push_str(&format!(
                "2026-08-25T19:31:{:02}.0000000Z line {i}\n",
                10 + i % 50
            ));
        }
        let text = plain(&run_body(
            &run("completed", Some("failure")),
            Some(&jobs()),
            &|_| Some(log.clone()),
            60,
            40,
        ));
        assert!(text.contains("earlier lines"), "{text}");
        assert!(text.contains("line 59"));
        assert!(!text.contains("line 0\n"));
    }

    fn long_log() -> String {
        let mut log = String::new();
        for i in 0..400 {
            log.push_str(&format!(
                "2026-08-25T19:31:{:02}.0000000Z line {i}\n",
                10 + i % 50
            ));
        }
        log
    }

    /// **The pane does not scroll.** `draw_pane` cuts whatever does not fit and
    /// says nothing, so a body longer than its pane loses its own tail -- which
    /// for a failed run is the summary and, worse, the error. This is the
    /// invariant that stops a four-hundred-line `apt-get` transcript from
    /// pushing the assertion that failed off the bottom.
    #[test]
    fn a_body_never_outgrows_the_pane_it_was_given() {
        for rows in [12u16, 20, 30, 46, 80] {
            let body = run_body(
                &run("completed", Some("failure")),
                Some(&jobs()),
                &|_| Some(long_log()),
                60,
                rows,
            );
            assert!(
                body.len() <= rows as usize,
                "{} lines in a {rows}-row pane",
                body.len()
            );
        }
    }

    /// And what survives the squeeze is the STRUCTURE. A pane with no room for
    /// a log still has to answer "is it green" and "which step".
    #[test]
    fn the_summary_and_the_step_names_survive_a_small_pane() {
        let text = plain(&run_body(
            &run("completed", Some("failure")),
            Some(&jobs()),
            &|_| Some(long_log()),
            60,
            14,
        ));
        assert!(text.contains("1 failed"), "lost the summary: {text}");
        assert!(text.contains("Run cargo test"), "lost the step: {text}");
        // Either phrasing is fine -- a tail with a count, or the "no room"
        // line when there is not even room for that. What must survive is a
        // route to the whole log.
        assert!(text.contains("L pages"), "no route to the log: {text}");

        // And at the point where a tail stops being worth printing, it says so
        // instead of showing two lines of a four-hundred-line log.
        let tiny = plain(&run_body(
            &run("completed", Some("failure")),
            Some(&jobs()),
            &|_| Some(long_log()),
            60,
            9,
        ));
        assert!(tiny.contains("1 failed"), "lost the summary: {tiny}");
        assert!(tiny.contains("no room here, L pages it"), "{tiny}");
    }

    /// A step body has the whole pane to itself and still tails, for the same
    /// reason -- and still says how to reach the rest.
    #[test]
    fn a_step_body_tails_rather_than_overflowing() {
        let js = jobs();
        let body = step_body(&js[1], &js[1].steps[0], Some(&long_log()), 60, 24);
        assert!(body.len() <= 24, "{} lines in a 24-row pane", body.len());
        assert!(plain(&body).contains("L pages the whole log"));
    }

    #[test]
    fn a_run_with_no_jobs_yet_says_what_it_is_waiting_for() {
        let text = plain(&run_body(
            &run("queued", None),
            Some(&[]),
            &|_| None,
            60,
            40,
        ));
        assert!(text.contains("waiting for a runner"));
    }

    #[test]
    fn a_step_still_running_explains_why_it_has_no_log() {
        let js = jobs();
        let mut step = js[0].steps[0].clone();
        step.status = Some("in_progress".into());
        step.conclusion = None;
        let text = plain(&step_body(&js[0], &step, None, 60, 40));
        assert!(text.contains("the log lands when the job completes"));
    }
}
