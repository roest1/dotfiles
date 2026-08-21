//! The loop: draw, wait, move, repeat.
//!
//! ─── Why this is two redraws and not one ─────────────────────────────────
//!
//! The reticle animates at 60fps. The right-hand pane can contain a PNG that
//! base64s to ~65KB. Re-sending that every frame is 4MB/s down a pty for an
//! animation the image is not part of, which is not a rounding error — it is
//! the difference between smooth and unusable.
//!
//! So the panes are redrawn on different clocks. `draw_rows` runs per frame and
//! writes only the left column. `draw_pane` runs when the SELECTION changes,
//! and is the only thing that ever emits an image. The terminal keeps the
//! pixels in between, which is exactly what an alternate screen is for.
//!
//! ─── Why it blocks ───────────────────────────────────────────────────────
//!
//! When nothing is moving, `poll` waits indefinitely and the process costs
//! nothing. A TUI that spins at 60fps to show a static list is a laptop fan.

use std::io::{self, Write};
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyEventKind};
use crossterm::{cursor, queue, style, terminal};

use crate::nav::{Action, Keymap};
use crate::reticle::Reticle;
use crate::screen::{Flow, Pane, Row, Screen, Tick};
use crate::term::Terminal;

const FRAME: Duration = Duration::from_millis(16);
/// Left column width. Wide enough for a long family name, its badge and the
/// brackets at full spread; the pane gets the rest. Adaptive, because a fixed
/// 52 on an 80-column terminal leaves a pane too narrow to hold a sentence,
/// and a fixed one that fits an 80-column terminal truncates every value on a
/// wide one.
fn left_width(cols: u16) -> u16 {
    52.min(cols.saturating_sub(30)).max(24)
}

/// 256-colour indices worth resolving up front: the ones this repo's PS1
/// actually uses (75 for user@host, 110 for the path), plus the greens and
/// reds a specimen tends to want.
const PALETTE_WANTED: &[u8] = &[75, 110, 108, 114, 210, 221, 244, 250];

pub fn run(root: Box<dyn Screen>) -> io::Result<()> {
    let mut term = Terminal::take()?;
    // After raw mode, before anything is drawn: the replies are only readable
    // once the terminal has stopped line-buffering, and they would otherwise
    // land in the middle of the first frame.
    crate::set_term_info(crate::probe::probe(PALETTE_WANTED));
    let res = event_loop(root);
    term.restore()?;
    res
}

/// One entry per screen on the stack. The cursor, the scroll offset and the
/// reticle travel WITH the screen, so coming back lands you on the row you
/// left rather than at the top — the same property gh-tui's nested fzf gets
/// from running one inside the other.
struct Frame {
    screen: Box<dyn Screen>,
    sel: usize,
    top: usize,
    reticle: Reticle,
}

fn event_loop(root: Box<dyn Screen>) -> io::Result<()> {
    let mut out = io::stdout();
    let mut keys = Keymap::default();
    let mut stack = vec![Frame {
        screen: root,
        sel: 0,
        top: 0,
        reticle: Reticle::new(0),
    }];
    stack[0].screen.focus(0);
    let mut rows = stack[0].screen.rows();
    let mut last = Instant::now();
    let mut pane_dirty = true;
    let mut busy = false;

    loop {
        let depth = stack.len();
        let frame = stack.last_mut().expect("stack is never empty");
        let (cols, screen_rows) = Terminal::size()?;
        let left = left_width(cols);
        let list_h = screen_rows.saturating_sub(3) as usize;

        // Keep the selection on screen, with the one-row margin nvim keeps.
        if frame.sel < frame.top {
            frame.top = frame.sel;
        } else if list_h > 0 && frame.sel >= frame.top + list_h {
            frame.top = frame.sel + 1 - list_h;
        }

        if pane_dirty {
            let pw = cols.saturating_sub(left + 1);
            let ph = screen_rows.saturating_sub(2);
            let pane = frame.screen.pane(frame.sel, pw, ph);
            draw_frame(&mut out, frame.screen.as_mut(), screen_rows, left)?;
            draw_pane(&mut out, &pane, left + 1, 1, pw, ph)?;
            pane_dirty = false;
        }
        draw_rows(
            &mut out,
            &rows,
            frame.top,
            list_h,
            &frame.reticle,
            frame.sel,
            left,
        )?;
        draw_footer(&mut out, frame.screen.as_mut(), cols, screen_rows, depth)?;
        out.flush()?;

        match frame.screen.tick() {
            Tick::Idle => {}
            Tick::Busy => busy = true,
            Tick::Changed => {
                busy = true;
                pane_dirty = true;
                rows = frame.screen.rows();
                continue;
            }
        }
        let timeout = if frame.reticle.moving() || busy {
            FRAME
        } else {
            Duration::from_secs(3600)
        };
        busy = false;

        let mut pushed: Option<Box<dyn Screen>> = None;
        let mut popped = false;

        if event::poll(timeout)? {
            if let Event::Key(k) = event::read()? {
                if k.kind != KeyEventKind::Press {
                    continue;
                }
                let Some(action) = keys.resolve(k) else {
                    continue;
                };
                let before = frame.sel;
                let len = rows.len();
                match action {
                    // At the root this leaves; anywhere else it goes back one
                    // screen, which is what every other pane-and-list tool in
                    // this repo trained your fingers to expect.
                    Action::Quit => {
                        if depth == 1 {
                            return Ok(());
                        }
                        popped = true;
                    }
                    // Every motion lands on a SELECTABLE row. Spacers exist
                    // to group things visually; a cursor that can rest in one
                    // turns them into potholes.
                    Action::Down => frame.sel = seek(&rows, frame.sel, 1),
                    Action::Up => frame.sel = seek(&rows, frame.sel, -1),
                    Action::Top => frame.sel = first_selectable(&rows, 0, 1),
                    Action::Bottom => {
                        frame.sel = first_selectable(&rows, len.saturating_sub(1), -1)
                    }
                    Action::PageDown => {
                        let want = (frame.sel + list_h / 2).min(len.saturating_sub(1));
                        frame.sel = first_selectable(&rows, want, -1);
                    }
                    Action::PageUp => {
                        let want = frame.sel.saturating_sub(list_h / 2);
                        frame.sel = first_selectable(&rows, want, 1);
                    }
                    other => match frame.screen.on_action(other, frame.sel) {
                        Flow::Quit => return Ok(()),
                        Flow::Pop => popped = depth > 1,
                        Flow::Push(next) => pushed = Some(next),
                        Flow::Dirty => {
                            rows = frame.screen.rows();
                            frame.sel = frame.sel.min(rows.len().saturating_sub(1));
                            pane_dirty = true;
                        }
                        Flow::Continue => {}
                    },
                }
                if frame.sel != before {
                    frame.reticle.aim(frame.sel);
                    // Separate from `pane` on purpose: a row you skim past
                    // still gets prefetched, which is the whole point.
                    frame.screen.focus(frame.sel);
                    pane_dirty = true;
                }
            }
        }

        let now = Instant::now();
        frame.reticle.step(now.duration_since(last));
        last = now;

        if let Some(mut next) = pushed {
            next.focus(0);
            rows = next.rows();
            stack.push(Frame {
                screen: next,
                sel: 0,
                top: 0,
                reticle: Reticle::new(0),
            });
            pane_dirty = true;
        } else if popped {
            stack.pop();
            let back = stack.last_mut().expect("root is never popped");
            rows = back.screen.rows();
            back.sel = back.sel.min(rows.len().saturating_sub(1));
            pane_dirty = true;
        }
    }
}

fn draw_frame(
    out: &mut impl Write,
    screen: &mut dyn Screen,
    rows: u16,
    left: u16,
) -> io::Result<()> {
    queue!(
        out,
        terminal::Clear(terminal::ClearType::All),
        cursor::MoveTo(0, 0)
    )?;
    let title = screen.title();
    queue!(out, style::Print(format!("\x1b[1m{title}\x1b[0m")))?;
    for r in 1..rows.saturating_sub(1) {
        queue!(
            out,
            cursor::MoveTo(left, r),
            style::Print("\x1b[38;5;240m\u{2502}\x1b[0m")
        )?;
    }
    Ok(())
}

/// One row: reticle room, then marker, label, detail — and the badge pinned to
/// the right edge with everything before it truncated to fit.
///
/// Right-aligning is not cosmetic. Trailing the badge after a variable-length
/// family name put "GOOD" at a different column on every line and pushed the
/// longest ones straight across the divider into the pane.
fn draw_rows(
    out: &mut impl Write,
    rows: &[Row],
    top: usize,
    height: usize,
    reticle: &Reticle,
    sel: usize,
    left: u16,
) -> io::Result<()> {
    let spread = reticle.spread();
    let ret_row = reticle.row();
    let blank = " ".repeat(left as usize);

    for i in 0..height {
        let y = (i + 1) as u16;
        queue!(out, cursor::MoveTo(0, y), style::Print(&blank))?;
        let Some(row) = rows.get(top + i) else {
            continue;
        };
        if !row.selectable && row.label.is_empty() {
            continue;
        }

        // The label's column never depends on the reticle -- only the brackets
        // move. See the note in reticle.rs.
        let indent = 2 + row.depth * 2 + SPREAD_ROOM;

        // Reserve the badge's column first; everything else lives in what is
        // left. One space of air before the divider.
        let badge_w = row
            .badge
            .as_ref()
            .map(|(t, _)| t.chars().count() as u16 + 2)
            .unwrap_or(0);
        let avail = left.saturating_sub(indent + badge_w + 1) as usize;

        let marker = if row.group {
            if row.expanded {
                "\u{25be} "
            } else {
                "\u{25b8} "
            }
        } else {
            ""
        };
        let label = format!("{marker}{}", row.label);
        let label = truncate(&label, avail as u16);
        let label_cols = label.chars().count();
        // The reticle hugs the NAME, not the padding. A header padded for
        // column alignment would otherwise read `[ claude      ]`, with the
        // frame closing around whitespace.
        let name_cols = label.trim_end().chars().count();

        queue!(out, cursor::MoveTo(indent, y))?;
        let styled = if row.group {
            format!("\x1b[1m{label}\x1b[0m")
        } else if top + i == sel {
            format!("\x1b[1;38;5;255m{label}\x1b[0m")
        } else {
            format!("\x1b[38;5;250m{label}\x1b[0m")
        };
        queue!(out, style::Print(styled))?;

        // The detail starts a full SPREAD_ROOM past the label, because that is
        // exactly where the reticle's closing bracket can reach at full
        // spread. Butting it up against the label instead meant the bracket
        // landed ON the first characters of the value — `[ nvim.editor ]etBrains…`.
        if let Some(detail) = &row.detail {
            let dx = indent + label_cols as u16 + SPREAD_ROOM;
            let room = left.saturating_sub(dx + badge_w + 1);
            if room > 2 {
                queue!(
                    out,
                    cursor::MoveTo(dx, y),
                    style::Print(format!("\x1b[38;5;244m{}\x1b[0m", truncate(detail, room)))
                )?;
            }
        }

        if let Some((badge, color)) = &row.badge {
            let x = left.saturating_sub(badge.chars().count() as u16 + 1);
            queue!(
                out,
                cursor::MoveTo(x, y),
                style::Print(format!("\x1b[38;5;{color}m{badge}\x1b[0m"))
            )?;
        }

        if top + i == ret_row && row.selectable {
            let open = indent.saturating_sub(spread + 1);
            let close = indent + name_cols as u16 + spread;
            if close < left {
                queue!(
                    out,
                    cursor::MoveTo(open, y),
                    style::Print("\x1b[38;5;211m[\x1b[0m"),
                    cursor::MoveTo(close, y),
                    style::Print("\x1b[38;5;211m]\x1b[0m")
                )?;
            }
        }
    }
    Ok(())
}

const SPREAD_ROOM: u16 = 5;

/// The nearest selectable row at or after `from`, searching in `dir`. Falls
/// back to `from` so a list that is entirely spacers cannot hang the caller.
fn first_selectable(rows: &[Row], from: usize, dir: isize) -> usize {
    let mut i = from as isize;
    while i >= 0 && (i as usize) < rows.len() {
        if rows[i as usize].selectable {
            return i as usize;
        }
        i += dir;
    }
    from.min(rows.len().saturating_sub(1))
}

/// One step in `dir`, skipping spacers, staying put at the ends.
fn seek(rows: &[Row], from: usize, dir: isize) -> usize {
    let mut i = from as isize + dir;
    while i >= 0 && (i as usize) < rows.len() {
        if rows[i as usize].selectable {
            return i as usize;
        }
        i += dir;
    }
    from
}

/// Two regions with a rule between them: the picture on top, the numbers below.
///
/// The ORDER is the fix, not the arithmetic. An inline image is a negotiation —
/// the terminal scales it by rules this process cannot see, and the first
/// version's contact sheet came back more than twice as tall as the rows
/// reserved for it and painted straight over every metric. So the text region
/// is cleared AFTER the image is placed, which overwrites whatever it spilled,
/// and a divider says where one ends and the other begins.
fn draw_pane(
    out: &mut impl Write,
    pane: &Pane,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
) -> io::Result<()> {
    let text_h = (pane.lines.len() as u16 + 1).min(height);
    let img_h = height.saturating_sub(text_h);

    if let Some(img) = pane.image.as_ref().filter(|_| crate::image::supported()) {
        if img_h >= 3 {
            queue!(out, cursor::MoveTo(x, y))?;
            out.write_all(&crate::image::inline(&img.png, img_h.min(img.rows)))?;
        }
    }

    let blank = " ".repeat(width as usize);
    let top = y + img_h;
    for r in 0..text_h {
        queue!(out, cursor::MoveTo(x, top + r), style::Print(&blank))?;
    }
    if img_h >= 3 {
        let rule = "\u{2500}".repeat(width as usize);
        queue!(
            out,
            cursor::MoveTo(x, top),
            style::Print(format!("\x1b[38;5;240m{rule}\x1b[0m"))
        )?;
    }
    for (i, line) in pane.lines.iter().enumerate() {
        let row = top + 1 + i as u16;
        if row >= y + height {
            break;
        }
        queue!(
            out,
            cursor::MoveTo(x, row),
            style::Print(truncate(line, width))
        )?;
    }
    Ok(())
}

fn draw_footer(
    out: &mut impl Write,
    screen: &mut dyn Screen,
    cols: u16,
    rows: u16,
    depth: usize,
) -> io::Result<()> {
    let y = rows.saturating_sub(1);
    queue!(
        out,
        cursor::MoveTo(0, y),
        style::Print(" ".repeat(cols as usize)),
        cursor::MoveTo(1, y),
        // The screen says what its own keys do; the stack says what `q`
        // does, which the screen cannot know.
        style::Print(format!(
            "\x1b[38;5;244m{}{}\x1b[0m",
            screen.footer(),
            if depth > 1 {
                " \u{b7} q back"
            } else {
                " \u{b7} q quit"
            }
        ))
    )
}

/// Truncates on CHARACTERS, not bytes -- the labels here are font family names
/// and the pane carries box-drawing and arrows.
fn truncate(s: &str, width: u16) -> String {
    let w = width as usize;
    if s.chars().count() <= w {
        return s.to_string();
    }
    s.chars().take(w.saturating_sub(1)).collect::<String>() + "\u{2026}"
}

#[cfg(test)]
mod tests {
    use super::{first_selectable, left_width, seek};
    use crate::screen::Row;

    fn list() -> Vec<Row> {
        vec![
            Row::leaf("shell"),
            Row::spacer(),
            Row::leaf("nvim.ui"),
            Row::spacer(),
            Row::leaf("claude"),
        ]
    }

    /// The invariant spacers depend on. A cursor that can rest in a blank row
    /// turns a grouping device into a pothole: j would appear to do nothing.
    #[test]
    fn motion_never_lands_on_a_spacer() {
        let rows = list();
        assert_eq!(seek(&rows, 0, 1), 2);
        assert_eq!(seek(&rows, 2, 1), 4);
        assert_eq!(seek(&rows, 4, -1), 2);
        assert_eq!(seek(&rows, 2, -1), 0);
    }

    /// At the ends, staying put beats wrapping or landing on a blank.
    #[test]
    fn motion_stops_at_the_ends() {
        let rows = list();
        assert_eq!(seek(&rows, 0, -1), 0);
        assert_eq!(seek(&rows, 4, 1), 4);
    }

    /// G aims at the last row, which is not necessarily a selectable one.
    #[test]
    fn ends_seek_backwards_to_something_selectable() {
        let mut rows = list();
        rows.push(Row::spacer());
        assert_eq!(first_selectable(&rows, rows.len() - 1, -1), 4);
        assert_eq!(first_selectable(&rows, 1, 1), 2);
    }

    /// The left column has to leave a usable pane on a small terminal and stop
    /// growing on a large one.
    #[test]
    fn left_column_stays_sane() {
        assert!(left_width(80) <= 50);
        assert_eq!(left_width(200), 52);
        assert!(left_width(40) >= 24);
    }
}
