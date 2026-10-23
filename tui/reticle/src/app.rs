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
use std::process::Command;
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyEventKind};
use crossterm::{cursor, queue, style, terminal};

use crate::nav::{Action, Keymap};
use crate::reticle::Reticle;
use crate::screen::{Flow, Pane, Row, Screen, Split, Tabs, Tick};
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
    run_stack(vec![root])
}

/// Start with screens ALREADY pushed, topmost last.
///
/// So a command can open where you are standing without that becoming a mode.
/// `github` run inside a repo seeds `[root, org, repo]` and shows the repo; `q`
/// then walks up to the org and the root and quits at it, which is what this
/// function already did for screens pushed by hand. The alternative -- making
/// the repo the root when the cwd is one -- leaves the org and the rest of the
/// account unreachable without leaving the program.
///
/// Screens below the top are NOT asked for rows or a pane until they are
/// reached, so a seeded path costs nothing for the levels skipped past. That is
/// load-bearing rather than incidental: a screen that fetched on construction
/// would make the seeded case slower than the unseeded one.
pub fn run_stack(screens: Vec<Box<dyn Screen>>) -> io::Result<()> {
    let mut term = Terminal::take()?;
    // After raw mode, before anything is drawn: the replies are only readable
    // once the terminal has stopped line-buffering, and they would otherwise
    // land in the middle of the first frame.
    crate::set_term_info(crate::probe::probe(PALETTE_WANTED));
    let res = event_loop(screens, &mut term);
    term.restore()?;
    res
}

/// One entry per screen on the stack. The cursor, the scroll offset and the
/// reticle travel WITH the screen, so coming back lands you on the row you
/// left rather than at the top — the same property the fzf implementation got
/// from running one fzf inside another.
struct Frame {
    screen: Box<dyn Screen>,
    sel: usize,
    top: usize,
    reticle: Reticle,
}

/// Run `argv` with the terminal handed back, then take it again.
///
/// The child's status is deliberately ignored: a failed `make check` is
/// information, not an error for this process, and the user has just watched
/// the output scroll past. What matters is that the terminal comes back even
/// if the child dies badly -- hence resume() on every path.
fn detach(term: &mut Terminal, out: &mut impl Write, argv: &[String]) -> io::Result<()> {
    let Some((program, args)) = argv.split_first() else {
        return Ok(());
    };
    term.suspend()?;
    let status = Command::new(program).args(args).status();
    // A beat to read the last line before the alternate screen swallows it.
    let _ = writeln!(out);
    let _ = match &status {
        Ok(s) if s.success() => writeln!(out, "  done — any key to go back"),
        Ok(s) => writeln!(
            out,
            "  exited {} — any key to go back",
            s.code().unwrap_or(-1)
        ),
        Err(e) => writeln!(out, "  could not run {program}: {e} — any key to go back"),
    };
    let _ = out.flush();
    // Read on the RESTORED terminal, so this is a line-buffered wait rather
    // than a raw keypress. Resuming first would swap the screen out from under
    // the output the user is being asked to read.
    let mut sink = String::new();
    let _ = io::stdin().read_line(&mut sink);
    term.resume()
}

fn event_loop(screens: Vec<Box<dyn Screen>>, term: &mut Terminal) -> io::Result<()> {
    let mut out = io::stdout();
    let mut keys = Keymap::default();
    let mut stack: Vec<Frame> = screens
        .into_iter()
        .map(|screen| Frame {
            screen,
            sel: 0,
            top: 0,
            reticle: Reticle::new(0),
        })
        .collect();
    // An empty stack would index out of bounds on the first frame rather than
    // showing nothing, so the one caller that can produce it gets a root.
    if stack.is_empty() {
        return Ok(());
    }
    // Only the TOP screen is focused and asked for rows. The ones underneath
    // are untouched until popped to, which is what keeps a seeded path free.
    let top = stack.len() - 1;
    let mut rows = stack[top].screen.rows();
    let sel = start_sel(stack[top].screen.as_ref(), &rows);
    stack[top].sel = sel;
    stack[top].reticle = Reticle::new(sel);
    stack[top].screen.focus(sel);
    let mut last = Instant::now();
    let mut pane_dirty = true;
    let mut busy = false;

    loop {
        let depth = stack.len();
        let frame = stack.last_mut().expect("stack is never empty");
        let (cols, screen_rows) = Terminal::size()?;
        let full = matches!(frame.screen.split(), Split::Full);
        // `Full` gives the whole width to the list; there is no divider to
        // leave room for and no pane to leave room beside.
        let left = if full { cols } else { left_width(cols) };
        let tabs = frame.screen.tabs();
        let foot = frame.screen.footer();
        let geo = layout(screen_rows, tabs.is_some(), footer_lines(&foot));
        let list_h = geo.list_h;

        // Keep the selection on screen, with the one-row margin nvim keeps.
        if frame.sel < frame.top {
            frame.top = frame.sel;
        } else if list_h > 0 && frame.sel >= frame.top + list_h {
            frame.top = frame.sel + 1 - list_h;
        }

        if pane_dirty {
            let ph = screen_rows.saturating_sub(geo.header_h + geo.footer_h);
            // Built BEFORE the frame is cleared only when there is one -- a
            // `Full` screen is never asked for a pane at all, so it does not
            // have to implement one it would never draw.
            let pane = if full {
                None
            } else {
                Some(
                    frame
                        .screen
                        .pane(frame.sel, cols.saturating_sub(left + 1), ph),
                )
            };
            draw_frame(
                &mut out,
                frame.screen.as_mut(),
                tabs.as_ref(),
                cols,
                screen_rows,
                if full { None } else { Some(left) },
                &geo,
            )?;
            if let Some(pane) = &pane {
                draw_pane(
                    &mut out,
                    pane,
                    left + 1,
                    geo.header_h,
                    cols.saturating_sub(left + 1),
                    ph,
                )?;
            }
            pane_dirty = false;
        }
        draw_rows(
            &mut out,
            &rows,
            &View {
                top: frame.top,
                sel: frame.sel,
                reticle: &frame.reticle,
            },
            left,
            geo.header_h,
            list_h,
        )?;
        draw_footer(&mut out, &foot, cols, screen_rows, depth, geo.footer_h)?;
        out.flush()?;

        let mut wake: Option<Duration> = None;
        match frame.screen.tick() {
            Tick::Idle => {}
            Tick::Busy => busy = true,
            Tick::Wake(d) => wake = Some(d),
            Tick::Changed => {
                busy = true;
                pane_dirty = true;
                rows = frame.screen.rows();
                continue;
            }
        }
        let timeout = poll_timeout(frame.reticle.moving() || busy, wake);
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
                        Flow::Detach(argv) => {
                            detach(term, &mut out, &argv)?;
                            rows = frame.screen.rows();
                            frame.sel = frame.sel.min(rows.len().saturating_sub(1));
                            pane_dirty = true;
                        }
                        Flow::Dirty => {
                            rows = frame.screen.rows();
                            frame.sel = frame.sel.min(rows.len().saturating_sub(1));
                            pane_dirty = true;
                        }
                        // Every row was replaced, so clamping the old index
                        // would land the cursor somewhere arbitrary. The
                        // screen is asked where to open, exactly as it is on
                        // a push.
                        Flow::Retarget => {
                            rows = frame.screen.rows();
                            frame.sel = start_sel(frame.screen.as_ref(), &rows);
                            frame.top = 0;
                            frame.reticle = Reticle::new(frame.sel);
                            frame.screen.focus(frame.sel);
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
            rows = next.rows();
            // A pushed screen gets asked where to open, exactly as the one the
            // program started on does. It used to be hard-coded to row 0, which
            // was invisible for as long as nothing overrode `initial_sel` --
            // and then silently wrong for the first screen that did: `github`
            // drilling into a failed run opened on the run's first job instead
            // of on the step that failed.
            let sel = start_sel(next.as_ref(), &rows);
            next.focus(sel);
            stack.push(Frame {
                screen: next,
                sel,
                top: 0,
                reticle: Reticle::new(sel),
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
    tabs: Option<&Tabs>,
    cols: u16,
    rows: u16,
    // `left` is where the vertical divider goes, or None for a full-width list.
    left: Option<u16>,
    geo: &Layout,
) -> io::Result<()> {
    queue!(
        out,
        terminal::Clear(terminal::ClearType::All),
        cursor::MoveTo(0, 0)
    )?;
    match tabs {
        None => {
            let title = screen.title();
            queue!(out, style::Print(format!("\x1b[1m{title}\x1b[0m")))?;
        }
        Some(t) => {
            queue!(out, style::Print(tab_strip(t, cols)))?;
            // The rule spans the FULL width, above both columns -- the strip
            // belongs to the screen, not to the list, so the divider starts
            // under it rather than beside it.
            queue!(
                out,
                cursor::MoveTo(0, 1),
                style::Print(format!(
                    "\x1b[38;5;240m{}\x1b[0m",
                    "\u{2500}".repeat(cols as usize)
                ))
            )?;
        }
    }
    if let Some(left) = left {
        for r in geo.header_h..rows.saturating_sub(geo.footer_h) {
            queue!(
                out,
                cursor::MoveTo(left, r),
                style::Print("\x1b[38;5;240m\u{2502}\x1b[0m")
            )?;
        }
    }
    Ok(())
}

/// `[ Repos ] · Orgs · Profile · Keys`
///
/// The active one is bracketed and bright; the rest are dim. Brackets rather
/// than a reverse-video block for the same reason the reticle uses them: this
/// repo's one visual idiom for "here" is a pair of brackets, and a second one
/// would be a second thing to learn.
///
/// Truncated from the RIGHT when it does not fit, so the leftmost tabs -- the
/// ones a screen puts first because they matter most -- survive a narrow
/// terminal.
fn tab_strip(tabs: &Tabs, cols: u16) -> String {
    let mut out = String::from(" ");
    let mut width = 1usize;
    if let Some(label) = &tabs.label {
        out.push_str(&format!("\x1b[38;5;245m{label}\x1b[0m"));
        width += label.chars().count();
    }
    for (i, name) in tabs.names.iter().enumerate() {
        // Width is counted from the PLAIN text, because the SGR codes are
        // zero-width on screen and characters in the string -- the same
        // arithmetic `lib/sgr.sh` and the row renderer both have to do.
        let sep = if i == 0 && tabs.label.is_none() {
            ""
        } else {
            "  "
        };
        let plain = sep.len() + name.chars().count() + if i == tabs.active { 4 } else { 0 };
        if width + plain + 1 > cols as usize {
            out.push_str("\x1b[38;5;240m\u{2026}\x1b[0m");
            break;
        }
        out.push_str(sep);
        if i == tabs.active {
            out.push_str(&format!(
                "\x1b[38;5;211m[\x1b[1;38;5;255m {name} \x1b[0m\x1b[38;5;211m]\x1b[0m"
            ));
        } else {
            out.push_str(&format!("\x1b[38;5;244m{name}\x1b[0m"));
        }
        width += plain;
    }
    out
}

/// One row: reticle room, then marker, label, detail — and the badge pinned to
/// the right edge with everything before it truncated to fit.
///
/// Right-aligning is not cosmetic. Trailing the badge after a variable-length
/// family name put "GOOD" at a different column on every line and pushed the
/// longest ones straight across the divider into the pane.
/// Where the list is looking: the scroll offset, the cursor, and the reticle
/// chasing it. Bundled because they always travel together and are always the
/// same three -- `draw_rows` took eight arguments once the header origin became
/// variable, which is a signal rather than a lint.
struct View<'a> {
    top: usize,
    sel: usize,
    reticle: &'a Reticle,
}

fn draw_rows(
    out: &mut impl Write,
    rows: &[Row],
    view: &View,
    left: u16,
    y0: u16,
    height: usize,
) -> io::Result<()> {
    let View { top, sel, reticle } = *view;
    let spread = reticle.spread();
    let ret_row = reticle.row();
    let blank = " ".repeat(left as usize);

    for i in 0..height {
        let y = y0 + i as u16;
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
        // Every marker plus one space of air between each and one before the
        // divider. Reserved FIRST, so the label is truncated to what is left
        // rather than pushing a badge across the divider.
        let badge_w: u16 = if row.badges.is_empty() {
            0
        } else {
            row.badges
                .iter()
                .map(|(t, _)| t.chars().count() as u16 + 1)
                .sum::<u16>()
                + 1
        };
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

        // Packed against the right edge, but walked in REVERSE -- so the last
        // badge lands rightmost and a screen listing them in reading order gets
        // them in that order on screen. A table that pads each value to a fixed
        // width then comes out as columns.
        let mut bx = left;
        for (badge, color) in row.badges.iter().rev() {
            let w = badge.chars().count() as u16;
            bx = bx.saturating_sub(w + 1);
            queue!(
                out,
                cursor::MoveTo(bx, y),
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

/// Where the four regions sit, given what this screen asked for.
///
/// Both halves are variable now and both used to be assumed. A screen with a
/// `Tabs` strip needs TWO header rows (the strip and the rule under it) where a
/// plain title needs one; and a footer may be several lines, because a screen
/// with eight keys cannot name them on one 80-column row.
///
/// The footer one was a bug, not a feature request. `draw_footer` printed the
/// footer string at `rows - 1`, so a `\n` in it moved the cursor off the bottom
/// of the screen and SCROLLED the alternate screen by a line — every frame.
/// Absolute `MoveTo` on the next frame papered over most of it, which is why it
/// showed up as the pane's divider column appearing on the title row rather
/// than as anything that looked like scrolling.
///
/// A plain screen with a one-line footer gets exactly the geometry it had
/// before, which is what keeps `font` and `dots` pixel-identical.
struct Layout {
    header_h: u16,
    footer_h: u16,
    list_h: usize,
}

fn layout(screen_rows: u16, tabbed: bool, footer_lines: u16) -> Layout {
    let header_h = if tabbed { 2 } else { 1 };
    let footer_h = footer_lines.max(1);
    Layout {
        header_h,
        footer_h,
        // The spare row is the blank line between the last row and the footer,
        // which the original `rows - 3` also left.
        list_h: screen_rows.saturating_sub(header_h + footer_h + 1).max(1) as usize,
    }
}

/// Lines a footer string occupies.
fn footer_lines(footer: &str) -> u16 {
    footer.lines().count().max(1) as u16
}

/// How long to wait for the next keystroke. Three clocks, most urgent first.
///
/// `frame` covers both the reticle animating and work in flight: each wants to
/// be looked at again as soon as possible. A `Tick::Wake` is the slow clock —
/// honoured as asked, floored at one frame so a screen cannot ask for a busy
/// loop by requesting zero. With neither, the poll blocks for an hour, which is
/// what keeps an idle TUI off the CPU entirely.
fn poll_timeout(frame: bool, wake: Option<Duration>) -> Duration {
    if frame {
        FRAME
    } else if let Some(d) = wake {
        d.max(FRAME)
    } else {
        Duration::from_secs(3600)
    }
}

/// Where a screen opens: what it asked for, clamped to what it drew.
///
/// Both guards are load-bearing. A screen computes its answer from its own row
/// walk, so an out-of-range one is a bug in that walk rather than a reason to
/// put the cursor past the end; and a spacer is a legal index that navigation
/// otherwise never lands on, so landing there once at startup would be the one
/// place a blank row can hold the cursor.
fn start_sel(screen: &dyn Screen, rows: &[Row]) -> usize {
    if rows.is_empty() {
        return 0;
    }
    let want = screen.initial_sel().min(rows.len() - 1);
    first_selectable(rows, want, 1)
}

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
    let has_image = pane.image.as_ref().filter(|_| crate::image::supported());
    let text_h = (pane.lines.len() as u16 + 1).min(height);
    // No picture, no picture region. Reserving it regardless pushed every
    // TEXT-ONLY pane to the bottom of the screen, under a rule that separated
    // nothing from nothing -- invisible while the only screen here had an
    // image to put up there, and wrong for every screen since.
    let img_h = match has_image {
        Some(_) => height.saturating_sub(text_h),
        None => 0,
    };

    if let Some(img) = has_image {
        if img_h >= 3 {
            queue!(out, cursor::MoveTo(x, y))?;
            out.write_all(&crate::image::inline(&img.png, img_h.min(img.rows)))?;
        }
    }

    // The rule is a SEPARATOR: it exists to divide the picture from the numbers
    // under it, so it appears only when there is a picture.
    let ruled = img_h >= 3;
    let text_y = if ruled { y + img_h + 1 } else { y + img_h };

    let blank = " ".repeat(width as usize);
    for r in text_y..(y + height) {
        queue!(out, cursor::MoveTo(x, r), style::Print(&blank))?;
    }
    if ruled {
        let rule = "\u{2500}".repeat(width as usize);
        queue!(
            out,
            cursor::MoveTo(x, y + img_h),
            style::Print(format!("\x1b[38;5;240m{rule}\x1b[0m"))
        )?;
    }
    for (i, line) in pane.lines.iter().enumerate() {
        let row = text_y + i as u16;
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

/// The footer, one terminal row per line of it.
///
/// Each line is positioned with its own absolute `MoveTo` and the newlines are
/// never written. Printing the string as-is at `rows - 1` let a `\n` walk the
/// cursor off the bottom and scroll the whole alternate screen, once per frame.
fn draw_footer(
    out: &mut impl Write,
    footer: &str,
    cols: u16,
    rows: u16,
    depth: usize,
    footer_h: u16,
) -> io::Result<()> {
    // The screen says what its own keys do; the stack says what `q` does,
    // which the screen cannot know. It goes on the LAST line, so it is in the
    // same place whether the footer is one line or three.
    let back = if depth > 1 { "q back" } else { "q quit" };
    let lines: Vec<&str> = footer.lines().collect();
    let top = rows.saturating_sub(footer_h);
    for i in 0..footer_h {
        let y = top + i;
        let mut text = lines.get(i as usize).copied().unwrap_or("").to_string();
        if i + 1 == footer_h {
            if text.is_empty() {
                text = back.to_string();
            } else {
                text.push_str(" \u{b7} ");
                text.push_str(back);
            }
        }
        queue!(
            out,
            cursor::MoveTo(0, y),
            style::Print(" ".repeat(cols as usize)),
            cursor::MoveTo(1, y),
            style::Print(format!(
                "\x1b[38;5;244m{}\x1b[0m",
                truncate(&text, cols - 2)
            ))
        )?;
    }
    Ok(())
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
    use super::{
        first_selectable, footer_lines, layout, left_width, poll_timeout, seek, Duration, FRAME,
    };
    use crate::screen::Row;

    /// A plain screen with a one-line footer must get the geometry it had
    /// before any of this was variable -- `font` and `dots` are that screen,
    /// and the numbers here are the ones the loop used to hard-code.
    #[test]
    fn a_plain_screen_keeps_the_layout_it_always_had() {
        let g = layout(48, false, 1);
        assert_eq!(g.header_h, 1);
        assert_eq!(g.footer_h, 1);
        assert_eq!(g.list_h, 45); // the old `rows - 3`
    }

    /// A strip costs one row, and only a screen that has one pays for it.
    #[test]
    fn a_tab_strip_costs_exactly_one_row() {
        assert_eq!(layout(48, true, 1).header_h, 2);
        assert_eq!(layout(48, true, 1).list_h, 44);
    }

    /// The bug this helper exists for. A multi-line footer used to be printed
    /// as one string at `rows - 1`, so its newlines scrolled the alternate
    /// screen once per frame; the visible symptom was the pane's divider
    /// column turning up on the title row. Now the rows are RESERVED.
    #[test]
    fn a_multi_line_footer_takes_rows_from_the_list_instead_of_scrolling() {
        assert_eq!(footer_lines("one line"), 1);
        assert_eq!(footer_lines("first\nsecond"), 2);
        // An empty footer is still one row, not zero.
        assert_eq!(footer_lines(""), 1);
        let g = layout(48, false, 2);
        assert_eq!(g.footer_h, 2);
        assert_eq!(g.list_h, 44);
        // Header, list, slack and footer account for every row.
        assert_eq!(g.header_h as usize + g.list_h + 1 + g.footer_h as usize, 48);
    }

    /// A terminal too short for the chrome must still leave a usable row
    /// rather than wrapping to zero and drawing nothing.
    #[test]
    fn a_tiny_terminal_still_gets_one_row() {
        assert_eq!(layout(3, true, 2).list_h, 1);
        assert_eq!(layout(1, true, 3).list_h, 1);
    }

    /// The three clocks, and which one outranks which. A screen polling a
    /// workflow run asks for seconds; the reticle asks for a frame; an idle
    /// screen asks for nothing and must not be woken for free.
    ///
    /// The third case is the one that matters: `Tick::Wake` is a floor on how
    /// long we may SLEEP, never a ceiling on how often we may draw, or a live
    /// run would make the reticle stutter every time it refreshed.
    #[test]
    fn a_slow_clock_does_not_become_a_frame_loop() {
        assert_eq!(poll_timeout(false, None), Duration::from_secs(3600));
        assert_eq!(
            poll_timeout(false, Some(Duration::from_secs(5))),
            Duration::from_secs(5)
        );
        assert_eq!(poll_timeout(true, Some(Duration::from_secs(5))), FRAME);
        // Asking for zero gets a frame, not a spin.
        assert_eq!(poll_timeout(false, Some(Duration::ZERO)), FRAME);
    }

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
