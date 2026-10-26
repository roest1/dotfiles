//! One job's log: cutting one step out of it, and colouring what comes back.
//!
//! This is the most hard-won logic in the screen it serves, and the only part
//! of the port with its tests written before its implementation. The reason is
//! the failure mode rather than the difficulty: a slice that is off by a step
//! boundary returns plausible log output for the wrong step, and nothing about
//! the result looks wrong. A subtle regression here would be believed.
//!
//! ## Why a log has to be cut up at all
//!
//! GitHub does not serve per-step logs. The run archive is one file per JOB
//! now, which is why `gh run view --log` prints `UNKNOWN STEP` against lines it
//! cannot attribute. So a step's output is reconstructed from the job's log in
//! three passes, each narrowing the last:
//!
//!   1. **the window** — lines whose timestamp falls inside the step's
//!      `[started_at, completed_at]`. Second precision only, so a sub-second
//!      step shares its second with its neighbours and this window can hold
//!      three steps' worth of output. It is a bound, not an answer.
//!   2. **the anchor** — the step's own `##[group]Run …` line inside that
//!      window, preferring one whose text is exactly the step's name. That
//!      preference is what makes `uses:` steps work: an unnamed step is called
//!      `Run actions/checkout@v4` and opens a group of precisely that name.
//!   3. **the cut** — the last `##[error]` before the next step's marker, since
//!      a failed step always ends on one. Failing that, the line before the
//!      next step's marker; failing that, the end of the window.
//!
//! Steps that never open a `Run` group at all — `Set up job`, `Post …`,
//! `Stop containers` — have no anchor, so they get the whole window. That is
//! the honest answer for them rather than a fallback: their output genuinely is
//! everything in their time range.
//!
//! Ported from `_ghw_step_slice` in `bash/bash_github_tui`, line for line
//! deliberately. The awk original compares timestamps as STRINGS, and this
//! does too: ISO 8601 with a fixed-width prefix sorts lexicographically, so
//! parsing them into instants would be slower and no more correct.

/// The marker a step's own log group opens with.
const RUN_GROUP: &str = "Z ##[group]Run ";

/// Lines that mean "the next step has started". The three besides a new `Run`
/// group are the post-job phases, which do not open one.
const NEXT_STEP: &[&str] = &[
    RUN_GROUP,
    "Z Post job cleanup.",
    "Z Cleaning up orphan processes",
    "Z Stop and remove container",
];

/// A log line's timestamp, to second precision.
///
/// The first 19 characters, which is `2026-08-25T19:30:42` — deliberately
/// dropping the fractional part the API sends, because the step boundaries we
/// compare against are themselves only second-accurate. Short lines return
/// what they have, as awk's `substr` does, rather than being skipped.
fn stamp(line: &str) -> &str {
    let end = line
        .char_indices()
        .nth(19)
        .map(|(i, _)| i)
        .unwrap_or(line.len());
    &line[..end]
}

/// A UTF-8 BOM, which GitHub puts at the head of a log file and nowhere else.
/// Stripped per line rather than once, because it has also turned up after a
/// chunk boundary.
fn strip_bom(line: &str) -> &str {
    line.strip_prefix('\u{feff}').unwrap_or(line)
}

/// The text a `##[group]` line opens, with its timestamp removed.
///
/// `^[^ ]+ ##\[group\]` in the original: one unbroken token, a space, then the
/// marker. Anchored, so a line merely containing the marker later does not
/// masquerade as a group header.
fn group_title(line: &str) -> Option<&str> {
    let (first, rest) = line.split_once(' ')?;
    if first.is_empty() {
        return None;
    }
    rest.strip_prefix("##[group]")
}

/// The lines of `log` belonging to the step that ran between `start` and `end`.
///
/// `end` may be empty for a step still in progress: the window then runs to the
/// end of the log, which is the right answer while output is still arriving.
pub fn step_slice<'a>(log: &'a str, start: &str, end: &str, name: &str) -> Vec<&'a str> {
    let (s, e) = (stamp(start), stamp(end));

    // ── 1. the window ──
    let mut win: Vec<&str> = Vec::new();
    for raw in log.lines() {
        let line = strip_bom(raw);
        let ts = stamp(line);
        if ts < s {
            continue;
        }
        // The log is in timestamp order, so the first line past the end is the
        // end -- scanning the remainder of a 15KB log to find nothing is pure
        // cost.
        if !e.is_empty() && ts > e {
            break;
        }
        win.push(line);
    }
    if win.is_empty() {
        return Vec::new();
    }

    // ── 2. the anchor ──
    let mut first_group: Option<usize> = None;
    let mut exact: Option<usize> = None;
    for (i, line) in win.iter().enumerate() {
        if !line.contains(RUN_GROUP) {
            continue;
        }
        if first_group.is_none() {
            first_group = Some(i);
        }
        if group_title(line) == Some(name) {
            exact = Some(i);
            break;
        }
    }
    // Preferring the exact match over the first group is the whole point: a
    // window can open with the TAIL of the previous step's group.
    let a = exact.or(first_group).unwrap_or(0);

    // ── 3. the cut ──
    let next = win
        .iter()
        .enumerate()
        .skip(a + 1)
        .find(|(_, line)| NEXT_STEP.iter().any(|m| line.contains(m)))
        .map(|(i, _)| i);
    let mut z = match next {
        Some(i) => i - 1,
        None => win.len() - 1,
    };
    // A failed step ends on its last error, which is nearly always well short
    // of the next step's marker -- everything between is the runner winding
    // down, and showing it buries the line you came to read. Searched from the
    // END, since the last match is the one wanted.
    if let Some(last) = (a..=z).rev().find(|&i| win[i].contains("Z ##[error]")) {
        z = last;
    }
    win[a..=z].to_vec()
}

/// Strip a leading `2026-08-25T19:30:42.1234567Z `, if there is one.
///
/// Hand-rolled rather than a regex crate, and the shape is exactly the
/// original's `^[0-9-]+T[0-9:.]+Z ?`: anything that does not match is left
/// alone, because a log line that happens not to carry a timestamp is still a
/// log line.
fn strip_stamp(line: &str) -> &str {
    let b = line.as_bytes();
    let mut i = 0;
    while i < b.len() && (b[i].is_ascii_digit() || b[i] == b'-') {
        i += 1;
    }
    if i == 0 || b.get(i) != Some(&b'T') {
        return line;
    }
    let mut j = i + 1;
    while j < b.len() && (b[j].is_ascii_digit() || b[j] == b':' || b[j] == b'.') {
        j += 1;
    }
    if j == i + 1 || b.get(j) != Some(&b'Z') {
        return line;
    }
    let k = j + 1;
    let k = if b.get(k) == Some(&b' ') { k + 1 } else { k };
    &line[k..]
}

/// GitHub's log markup, rendered.
///
/// `None` for `##[endgroup]`, which exists to close a group and says nothing to
/// a reader. Anything the tool being run coloured itself passes through
/// untouched -- the pane renders ANSI, so a cargo error arrives in cargo's own
/// colours rather than in a reimplementation of them.
pub fn fmt_line(raw: &str) -> Option<String> {
    use crate::paint::{BLU, BOLD, DIM, OFF, RED, YEL};
    let line = strip_bom(raw);
    let line = line.strip_suffix('\r').unwrap_or(line);
    let line = strip_stamp(line);

    if line.starts_with("##[endgroup]") {
        return None;
    }
    for (marker, prefix) in [
        ("##[error]", format!("{BOLD}{RED}\u{2716} ")),
        ("##[warning]", format!("{YEL}\u{26a0} ")),
        ("##[group]", format!("{BLU}\u{25b8} ")),
    ] {
        if let Some(rest) = line.strip_prefix(marker) {
            return Some(format!("{prefix}{rest}{OFF}"));
        }
    }
    for marker in ["##[notice]", "##[debug]", "##[command]", "##[section]"] {
        if let Some(rest) = line.strip_prefix(marker) {
            return Some(format!("{DIM}{rest}{OFF}"));
        }
    }
    Some(line.to_string())
}

/// A whole slice, formatted, with the closing markers dropped.
pub fn fmt_log<'a>(lines: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    lines.into_iter().filter_map(fmt_line).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A two-step job log in the real shape: timestamped lines, `##[group]Run`
    /// headers naming each step, an `##[error]` in the failing one, and the
    /// post-job phases after.
    const LOG: &str = concat!(
        "\u{feff}2026-08-25T19:30:40.0000000Z ##[group]Run actions/checkout@v4\n",
        "2026-08-25T19:30:40.1000000Z with:\n",
        "2026-08-25T19:30:40.2000000Z ##[endgroup]\n",
        "2026-08-25T19:30:41.0000000Z Syncing repository\n",
        "2026-08-25T19:30:42.0000000Z ##[group]Run cargo test --all\n",
        "2026-08-25T19:30:43.0000000Z    Compiling github v0.1.0\n",
        "2026-08-25T19:30:44.0000000Z ##[error]test slicing failed\n",
        "2026-08-25T19:30:45.0000000Z leaving the runner\n",
        "2026-08-25T19:30:46.0000000Z Post job cleanup.\n",
        "2026-08-25T19:30:47.0000000Z Cleaning up orphan processes\n",
    );

    #[test]
    fn it_cuts_at_the_step_whose_name_matches_the_group() {
        let got = step_slice(
            LOG,
            "2026-08-25T19:30:42Z",
            "2026-08-25T19:30:45Z",
            "Run cargo test --all",
        );
        assert!(got[0].contains("##[group]Run cargo test --all"), "{got:?}");
        // Cut at the last error, not at the post-job marker: the line after it
        // is the runner winding down.
        assert!(got.last().unwrap().contains("##[error]test slicing failed"));
        assert!(!got.iter().any(|l| l.contains("leaving the runner")));
    }

    /// The case the second pass exists for. A window opened one second early
    /// holds the tail of the PREVIOUS step, including its group header, so
    /// taking the first group found would return the wrong step's output.
    #[test]
    fn a_window_holding_two_groups_picks_the_one_it_was_asked_for() {
        let got = step_slice(
            LOG,
            "2026-08-25T19:30:40Z",
            "2026-08-25T19:30:45Z",
            "Run cargo test --all",
        );
        assert!(got[0].contains("Run cargo test --all"), "{got:?}");
        assert!(!got.iter().any(|l| l.contains("Syncing repository")));
    }

    /// An unnamed `uses:` step is named after what it runs, and its group says
    /// the same thing -- which is the whole reason the exact-name preference
    /// works at all.
    #[test]
    fn an_unnamed_uses_step_matches_on_its_own_name() {
        let got = step_slice(
            LOG,
            "2026-08-25T19:30:40Z",
            "2026-08-25T19:30:41Z",
            "Run actions/checkout@v4",
        );
        assert!(got[0].contains("Run actions/checkout@v4"));
        assert!(got.iter().any(|l| l.contains("Syncing repository")));
        assert!(!got.iter().any(|l| l.contains("cargo test")));
    }

    /// `Set up job` and the post phases never open a Run group, so they have no
    /// anchor. The whole window is the honest answer, not a failure.
    #[test]
    fn a_step_with_no_group_gets_its_whole_window() {
        let log = concat!(
            "2026-08-25T19:30:10.0000000Z Current runner version: '2.300.0'\n",
            "2026-08-25T19:30:11.0000000Z Operating System\n",
        );
        let got = step_slice(
            log,
            "2026-08-25T19:30:10Z",
            "2026-08-25T19:30:11Z",
            "Set up job",
        );
        assert_eq!(got.len(), 2);
    }

    /// A step still running has no `completed_at`. The window has to stay open
    /// to the end of the log, or a live step shows nothing while it is the one
    /// thing you are watching.
    #[test]
    fn a_running_step_slices_to_the_end_of_what_has_arrived() {
        let got = step_slice(LOG, "2026-08-25T19:30:42Z", "", "Run cargo test --all");
        assert!(got.iter().any(|l| l.contains("Compiling github")));
    }

    #[test]
    fn a_window_that_matches_nothing_is_empty_rather_than_everything() {
        assert!(step_slice(LOG, "2027-01-01T00:00:00Z", "2027-01-02T00:00:00Z", "x").is_empty());
        assert!(step_slice("", "2026-08-25T19:30:42Z", "", "x").is_empty());
    }

    /// The BOM is on the first line of every log GitHub serves. Left in place
    /// it defeats the `##[group]` prefix match on exactly the line that matters
    /// most -- the first step's header.
    #[test]
    fn the_leading_bom_does_not_hide_the_first_group() {
        let got = step_slice(
            LOG,
            "2026-08-25T19:30:40Z",
            "2026-08-25T19:30:41Z",
            "Run actions/checkout@v4",
        );
        assert!(group_title(got[0]).is_some(), "{:?}", got[0]);
    }

    #[test]
    fn formatting_drops_the_timestamp_and_the_closing_marker() {
        assert_eq!(
            fmt_line("2026-08-25T19:30:40.0000000Z hello").as_deref(),
            Some("hello")
        );
        assert_eq!(fmt_line("2026-08-25T19:30:40.0000000Z ##[endgroup]"), None);
        let err = fmt_line("2026-08-25T19:30:44.0000000Z ##[error]boom").unwrap();
        assert!(err.contains("boom") && err.contains("\u{2716}") && !err.contains("##["));
    }

    /// A line without a timestamp is still a line. The original's regex simply
    /// does not match, and anything that reached for `[..k]` unconditionally
    /// would eat the first characters of real output.
    #[test]
    fn a_line_with_no_timestamp_survives_intact() {
        assert_eq!(fmt_line("plain output").as_deref(), Some("plain output"));
        assert_eq!(
            fmt_line("12-34 not a stamp").as_deref(),
            Some("12-34 not a stamp")
        );
    }

    /// Windows runners emit CRLF. A trailing CR left in place puts the cursor
    /// back at column zero and the NEXT pane line overwrites this one.
    #[test]
    fn a_carriage_return_does_not_survive_into_the_pane() {
        assert_eq!(
            fmt_line("2026-08-25T19:30:40.0000000Z done\r").as_deref(),
            Some("done")
        );
    }
}
