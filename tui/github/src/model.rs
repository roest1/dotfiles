//! What the Actions API returns, and the one place that says what it MEANS.
//!
//! Typed structs rather than `serde_json::Value` walking, for the reason the
//! port exists: the fzf implementation spent 67 jq programs restating this
//! shape, and the two renderers of a job line had already drifted on which
//! field decided its colour. One `Status` with one `verdict` is the fix.
//!
//! Every field is optional that the API can actually omit, and several can. A
//! queued run has no `run_started_at`; a job waiting for a runner has no
//! `started_at`; a run triggered by a deleted app has no `actor`. Each of those
//! arrived as a crash in an early draft of this file, so the `Option`s are
//! evidence rather than caution.

use serde::Deserialize;

use crate::paint::{idx, GRN, GRY, RED, YEL};
use crate::time;

#[derive(Debug, Clone, Deserialize)]
pub struct Actor {
    pub login: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Run {
    pub id: u64,
    /// The workflow's name. Shown only when the repo has more than one, which
    /// is the only time it distinguishes anything.
    pub name: Option<String>,
    pub display_title: String,
    pub head_branch: Option<String>,
    pub head_sha: String,
    pub event: String,
    pub status: Option<String>,
    pub conclusion: Option<String>,
    pub html_url: String,
    pub created_at: String,
    pub run_started_at: Option<String>,
    pub updated_at: Option<String>,
    pub run_number: u64,
    /// 1 for a first run; a rerun increments it. Load-bearing for the cache:
    /// a rerun is the SAME id with new jobs, so anything keyed on id alone
    /// would serve the previous attempt's results forever.
    #[serde(default = "one")]
    pub run_attempt: u32,
    pub actor: Option<Actor>,
}

fn one() -> u32 {
    1
}

#[derive(Debug, Clone, Deserialize)]
pub struct RunList {
    #[serde(default)]
    pub workflow_runs: Vec<Run>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Job {
    pub id: u64,
    pub name: String,
    pub status: Option<String>,
    pub conclusion: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub runner_name: Option<String>,
    pub html_url: Option<String>,
    #[serde(default)]
    pub steps: Vec<Step>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Step {
    pub number: u32,
    pub name: String,
    pub status: Option<String>,
    pub conclusion: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct JobList {
    #[serde(default)]
    pub jobs: Vec<Job>,
}

/// Where a run, job or step has got to, collapsed from the API's two fields.
///
/// `status` and `conclusion` together have more states than anyone needs to
/// reason about, and reasoning about them at each call site is what let the
/// bash renderers drift. Everything downstream asks this type instead.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Passed,
    Failed,
    Running,
    Queued,
    Cancelled,
    Skipped,
    /// Completed with something that is neither a pass nor a failure --
    /// `neutral`, `stale`, `action_required`, or a conclusion added to the API
    /// after this was written. Named rather than folded into `Failed` so a new
    /// GitHub state cannot silently turn a list red.
    Other,
}

impl Verdict {
    pub fn of(status: Option<&str>, conclusion: Option<&str>) -> Self {
        match status.unwrap_or("") {
            "completed" => match conclusion.unwrap_or("") {
                "success" => Self::Passed,
                "failure" | "startup_failure" | "timed_out" => Self::Failed,
                "cancelled" => Self::Cancelled,
                "skipped" => Self::Skipped,
                _ => Self::Other,
            },
            "queued" | "waiting" | "pending" | "requested" => Self::Queued,
            // An unknown status is treated as running rather than as an error:
            // the states GitHub adds are stages of being under way, and a row
            // that says "running" while it finishes is briefly imprecise where
            // one that says "failed" is wrong.
            _ => Self::Running,
        }
    }

    pub fn done(self) -> bool {
        !matches!(self, Self::Running | Self::Queued)
    }

    /// Glyph AND word, with its colour index.
    ///
    /// The glyph is back. It was dropped because an emoji is two cells where a
    /// `char` is one, so it shifted every column after it -- but that was an
    /// arithmetic bug, not a reason to lose the one thing in a dense list you
    /// can find without reading. `reticle::width` measures cells properly now,
    /// and a screen building a table pads with `width::rpad`.
    ///
    /// The WORD stays beside it, because several of these are not guessable
    /// from the picture: nobody reads a white circle as "neither passed nor
    /// failed", and a clock and an hourglass are the same thing to anyone who
    /// has not been told which is which.
    pub fn badge(self) -> (&'static str, u8) {
        match self {
            Self::Passed => ("\u{2705} ok", idx::GRN),
            Self::Failed => ("\u{274c} fail", idx::RED),
            Self::Running => ("\u{23f3} run", idx::YEL),
            Self::Queued => ("\u{1f552} queued", idx::YEL),
            Self::Cancelled => ("\u{1f6ab} cancel", idx::GRY),
            // `\u{23ed}` would read better, and is NARROW -- measured, not
            // assumed. It would still line up, because the padding is in
            // cells, but a column of two-cell glyphs with one one-cell hole in
            // it looks like a mistake. `\u{23e9}` is wide and close enough.
            Self::Skipped => ("\u{23e9} skip", idx::DIM),
            Self::Other => ("\u{26aa} other", idx::GRY),
        }
    }

    /// The glyph for inside the pane, where prose can be as wide as it likes.
    pub fn glyph(self) -> &'static str {
        match self {
            Self::Passed => "\u{2705}",
            Self::Failed => "\u{274c}",
            Self::Running => "\u{23f3}",
            Self::Queued => "\u{1f552}",
            Self::Cancelled => "\u{1f6ab}",
            Self::Skipped => "\u{23ed}",
            Self::Other => "\u{26aa}",
        }
    }

    pub fn color(self) -> &'static str {
        match self {
            Self::Passed => GRN,
            Self::Failed => RED,
            Self::Running | Self::Queued => YEL,
            _ => GRY,
        }
    }
}

impl Run {
    pub fn verdict(&self) -> Verdict {
        Verdict::of(self.status.as_deref(), self.conclusion.as_deref())
    }

    /// The word under the status glyph: the conclusion once there is one, the
    /// status while there is not. `in_progress` reads as `in progress`.
    pub fn state(&self) -> String {
        match (self.status.as_deref(), self.conclusion.as_deref()) {
            (Some("completed"), Some(c)) => c.replace('_', " "),
            (Some(s), _) => s.replace('_', " "),
            _ => "unknown".into(),
        }
    }

    /// When the run actually started. `run_started_at` is absent while a run is
    /// queued, and `created_at` is the honest stand-in -- a run queued for ten
    /// minutes has genuinely been waiting ten minutes.
    pub fn started(&self) -> &str {
        self.run_started_at.as_deref().unwrap_or(&self.created_at)
    }

    /// How long it took, or has taken so far.
    pub fn elapsed(&self) -> Option<i64> {
        if self.verdict().done() {
            time::span(Some(self.started()), self.updated_at.as_deref())
        } else {
            time::span(Some(self.started()), None)
        }
    }

    pub fn age(&self) -> i64 {
        time::epoch(&self.created_at)
            .map(|t| (time::now() - t).max(0))
            .unwrap_or(0)
    }

    pub fn actor_login(&self) -> &str {
        self.actor.as_ref().map(|a| a.login.as_str()).unwrap_or("?")
    }

    /// `pull_request` is the long way to say `pr`. The same abbreviations the
    /// fzf list used, so the column reads the same width.
    pub fn event_short(&self) -> &str {
        match self.event.as_str() {
            "pull_request" => "pr",
            "pull_request_target" => "pr-tgt",
            "workflow_dispatch" => "manual",
            "schedule" => "cron",
            "dynamic" => "dyn",
            other => other,
        }
    }
}

impl Job {
    pub fn verdict(&self) -> Verdict {
        Verdict::of(self.status.as_deref(), self.conclusion.as_deref())
    }
    pub fn elapsed(&self) -> Option<i64> {
        time::span(self.started_at.as_deref(), self.completed_at.as_deref())
    }
    /// Only a COMPLETED job has a log. GitHub serves nothing for one still
    /// running, so asking is a wasted round trip and a misleading empty pane.
    pub fn has_log(&self) -> bool {
        self.status.as_deref() == Some("completed")
    }
}

impl Step {
    pub fn verdict(&self) -> Verdict {
        Verdict::of(self.status.as_deref(), self.conclusion.as_deref())
    }
    pub fn elapsed(&self) -> Option<i64> {
        time::span(self.started_at.as_deref(), self.completed_at.as_deref())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_two_api_fields_collapse_to_one_verdict() {
        assert_eq!(
            Verdict::of(Some("completed"), Some("success")),
            Verdict::Passed
        );
        assert_eq!(
            Verdict::of(Some("completed"), Some("failure")),
            Verdict::Failed
        );
        assert_eq!(
            Verdict::of(Some("completed"), Some("timed_out")),
            Verdict::Failed
        );
        assert_eq!(Verdict::of(Some("in_progress"), None), Verdict::Running);
        assert_eq!(Verdict::of(Some("queued"), None), Verdict::Queued);
        assert_eq!(
            Verdict::of(Some("completed"), Some("skipped")),
            Verdict::Skipped
        );
    }

    /// Every badge is glyph + word, and the glyph is two cells. A table pads
    /// these into a column, so one that measured wrong would shift every
    /// column after it -- which is what `reticle::width` exists to prevent.
    #[test]
    fn every_badge_carries_a_glyph_and_a_word() {
        for v in [
            Verdict::Passed,
            Verdict::Failed,
            Verdict::Running,
            Verdict::Queued,
            Verdict::Cancelled,
            Verdict::Skipped,
            Verdict::Other,
        ] {
            let (text, _) = v.badge();
            let mut chars = text.chars();
            let glyph = chars.next().expect("a glyph");
            assert!(!glyph.is_ascii(), "{text:?} has no glyph");
            let rest = chars.as_str();
            assert!(rest.starts_with(' '), "{text:?} has no word");
            assert!(rest.trim().len() >= 2, "{text:?} word too short");
            // The invariant that actually matters: padded into a table column,
            // every badge occupies exactly that many CELLS -- whatever mix of
            // one- and two-cell glyphs they use.
            assert_eq!(
                reticle::width::width(&reticle::width::rpad(text, 9)),
                9,
                "{text:?} does not pad to nine cells"
            );
        }
    }

    /// The two directions that must not be guessed wrong. A conclusion GitHub
    /// adds later must not read as a failure, and a status it adds later must
    /// not read as finished -- a run wrongly called finished stops being
    /// polled, which is the error that does not correct itself.
    #[test]
    fn unknown_states_fail_in_the_safe_direction() {
        assert_eq!(
            Verdict::of(Some("completed"), Some("neutral")),
            Verdict::Other
        );
        assert_eq!(
            Verdict::of(Some("completed"), Some("brand_new")),
            Verdict::Other
        );
        assert!(Verdict::of(Some("completed"), Some("brand_new")).done());
        assert_eq!(Verdict::of(Some("brand_new"), None), Verdict::Running);
        assert!(!Verdict::of(Some("brand_new"), None).done());
    }

    /// The shape that crashed an early draft: a queued run with no
    /// `run_started_at`, no `conclusion`, no `actor` and no `updated_at`.
    #[test]
    fn a_queued_run_parses_and_renders_without_its_missing_fields() {
        let json = r#"{"workflow_runs":[{
            "id":42,"display_title":"wip","head_sha":"abc","event":"push",
            "status":"queued","html_url":"https://x","created_at":"2026-08-25T19:30:42Z",
            "run_number":7
        }]}"#;
        let list: RunList = serde_json::from_str(json).expect("parses");
        let r = &list.workflow_runs[0];
        assert_eq!(r.verdict(), Verdict::Queued);
        assert_eq!(r.state(), "queued");
        assert_eq!(r.actor_login(), "?");
        assert_eq!(r.started(), "2026-08-25T19:30:42Z");
        // Defaulted rather than absent: the cache key is built from it.
        assert_eq!(r.run_attempt, 1);
        assert!(r.elapsed().is_some());
    }

    #[test]
    fn a_job_still_running_is_not_asked_for_its_log() {
        let json = r#"{"jobs":[
            {"id":1,"name":"build","status":"in_progress","steps":[]},
            {"id":2,"name":"test","status":"completed","conclusion":"failure","steps":[]}
        ]}"#;
        let list: JobList = serde_json::from_str(json).expect("parses");
        assert!(!list.jobs[0].has_log());
        assert!(list.jobs[1].has_log());
    }
}
