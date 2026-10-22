//! Timestamps, ages and durations, without a date crate.
//!
//! The API speaks ISO 8601 and the screens want "4m" and "2h18m". That is the
//! whole requirement -- no timezones, no formatting, no calendar arithmetic
//! beyond converting a UTC civil date to an epoch second. A date crate for this
//! would be a dependency and a compile for twenty lines of arithmetic, in a
//! binary whose appeal is that it starts in a millisecond.
//!
//! Ported from the `age`, `dur` and `secs` definitions in `_ghw_jq_defs`, with
//! the same thresholds, so a run that read "3h" in the fzf screens reads "3h"
//! here.

use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// `2026-08-25T19:30:42Z` or `…42.1234567Z` to an epoch second.
///
/// Fractional seconds are truncated rather than rounded, matching jq's
/// `sub("\\.[0-9]+"; "")` -- a half-second either way is invisible in a column
/// that reports minutes, and agreeing with the old implementation is worth more
/// than being righter than it.
pub fn epoch(iso: &str) -> Option<i64> {
    let b = iso.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| iso.get(r)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, s) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    Some(days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s)
}

/// Days since 1970-01-01 for a UTC civil date.
///
/// Howard Hinnant's `days_from_civil`, which is the standard answer and is
/// correct across the leap rules for any year this will ever see. It shifts the
/// year to start in March so the leap day lands at the END of the cycle and
/// February needs no special case.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// How long ago, in the shortest form that is still true: `now`, `4m`, `3h`,
/// `2d`, `5w`. Three characters at most, because this is a list column.
pub fn age(secs: i64) -> String {
    match secs {
        s if s < 60 => "now".into(),
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86_400 => format!("{}h", s / 3600),
        s if s < 604_800 => format!("{}d", s / 86_400),
        s => format!("{}w", s / 604_800),
    }
}

/// How long something took: `45s`, `3m20s`, `1h04m`.
pub fn dur(secs: i64) -> String {
    match secs {
        s if s < 0 => String::new(),
        s if s >= 3600 => format!("{}h{:02}m", s / 3600, (s % 3600) / 60),
        s if s >= 60 => format!("{}m{}s", s / 60, s % 60),
        s => format!("{s}s"),
    }
}

/// Elapsed seconds between two API timestamps, or from `start` until `now` for
/// something still running. `None` when it has not started.
pub fn span(start: Option<&str>, end: Option<&str>) -> Option<i64> {
    let from = epoch(start?)?;
    let to = end.and_then(epoch).unwrap_or_else(now);
    Some((to - from).max(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_parses_both_shapes_the_api_sends() {
        // 2026-08-25T19:30:42Z, checked against `date -u -d … +%s`.
        assert_eq!(epoch("2026-08-25T19:30:42Z"), Some(1_787_686_242));
        assert_eq!(epoch("2026-08-25T19:30:42.1234567Z"), Some(1_787_686_242));
        assert_eq!(epoch("1970-01-01T00:00:00Z"), Some(0));
    }

    /// A leap day and the turn of a century, which is where a hand-rolled
    /// civil-date conversion goes wrong if it goes wrong at all.
    #[test]
    fn the_calendar_arithmetic_survives_the_awkward_dates() {
        assert_eq!(epoch("2024-02-29T00:00:00Z"), Some(1_709_164_800));
        assert_eq!(epoch("2000-03-01T00:00:00Z"), Some(951_868_800));
        assert_eq!(epoch("2100-01-01T00:00:00Z"), Some(4_102_444_800));
    }

    #[test]
    fn a_malformed_stamp_is_none_rather_than_zero() {
        // Zero would render as 1970 and read as a real, very old run.
        assert_eq!(epoch(""), None);
        assert_eq!(epoch("not a date at all"), None);
        assert_eq!(epoch("2026-13-01T00:00:00Z"), None);
    }

    #[test]
    fn ages_and_durations_match_the_thresholds_they_replaced() {
        assert_eq!(age(30), "now");
        assert_eq!(age(300), "5m");
        assert_eq!(age(7200), "2h");
        assert_eq!(age(172_800), "2d");
        assert_eq!(age(1_209_600), "2w");
        assert_eq!(dur(45), "45s");
        assert_eq!(dur(200), "3m20s");
        assert_eq!(dur(3840), "1h04m");
    }

    /// A job whose `completed_at` precedes its `started_at` -- which the API
    /// does emit for a skipped job -- must not render as a negative duration.
    #[test]
    fn a_backwards_span_clamps_to_zero() {
        let s = span(Some("2026-08-25T19:30:42Z"), Some("2026-08-25T19:30:40Z"));
        assert_eq!(s, Some(0));
        assert_eq!(span(None, None), None);
    }
}
