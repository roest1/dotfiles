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
    /// Which region hjkl is acting on. Travels with the screen, so coming back
    /// to one lands you where you were in every sense.
    focus: Focus,
    /// First pane line drawn, for when the pane has focus and more lines than
    /// fit.
    pane_top: usize,
    /// What the list is narrowed to. Persistent per screen, like the focus and
    /// the cursor, so coming back to a filtered list finds it as you left it.
    filter: String,
    /// The text field, when one has the keyboard.
    edit: Option<Edit>,
}

/// A text field with the keyboard.
struct Edit {
    what: Asking,
    text: String,
    /// The cursor position to put back if this is abandoned.
    was: usize,
}

enum Asking {
    /// Narrowing the list. Every keystroke applies, so the list moves under
    /// you as you type -- which is what fzf did and what makes it feel like
    /// filtering rather than like a query box.
    Filter,
    /// A value the SCREEN asked for, with its prompt.
    Screen(String),
}

/// Which region the keys are acting on.
///
/// ─── Why directional focus instead of a key per region ──────────────────
///
/// `Tab` used to be the only way to reach the strip, and a key that exists
/// solely to change what the other keys mean is a mode -- the thing this nav
/// contract is built to avoid. Riley's word for the fix was a smart TV, and it
/// is the right model: hjkl moves you around the screen, and the EDGE of a
/// region is the door to the next one.
///
/// The rule that makes it work without the screens knowing: a direction acts
/// within the focused region, and when it cannot -- the cursor is at the top
/// row, the tree node has nothing to collapse -- focus moves instead. For
/// `h`/`l` that is read straight off `Flow::Continue`, which already means
/// "nothing happened"; no screen had to change to take part.
///
/// `Tab` and shift-`Tab` still work. They are no longer the only way.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Focus {
    /// The header strip. `h`/`l` change tab, `j` drops into the list.
    Tabs,
    /// The row list. The default, and where everything used to happen.
    List,
    /// The right-hand pane, when it has more to say than fits. `j`/`k`
    /// scroll it, `h` goes back to the list.
    Pane,
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
            focus: Focus::List,
            pane_top: 0,
            filter: String::new(),
            edit: None,
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
    let mut vis: Vec<usize> = (0..rows.len()).collect();
    let sel = start_sel(stack[top].screen.as_ref(), &rows, &vis);
    stack[top].sel = sel;
    stack[top].reticle = Reticle::new(sel);
    stack[top].screen.focus(vis.get(sel).copied().unwrap_or(0));
    let mut last = Instant::now();
    let mut pane_dirty = true;
    let mut busy = false;
    let mut pane_lines = 0usize;
    let mut pane_room = 0usize;

    loop {
        let depth = stack.len();
        let frame = stack.last_mut().expect("stack is never empty");
        // `frame.sel` is a POSITION in `vis`, never a row index. The screen is
        // handed `vis[sel]`, which is ITS index -- the translation happens at
        // this boundary and nowhere else, which is why no screen knows a
        // filter exists and why every screen already written gained filtering
        // without a line changing in it.
        vis = crate::filter::visible(&rows, &frame.filter);
        if frame.sel >= vis.len() {
            frame.sel = vis.len().saturating_sub(1);
        }
        let cur = vis.get(frame.sel).copied().unwrap_or(0);
        let (cols, screen_rows) = Terminal::size()?;
        let full = matches!(frame.screen.split(), Split::Full);
        // `Full` gives the whole width to the list; there is no divider to
        // leave room for and no pane to leave room beside.
        let left = if full { cols } else { left_width(cols) };
        let tabs = frame.screen.tabs();
        // Each region says what ITS keys do. The screen only speaks for the
        // list, because that is the only region whose contents it owns -- and a
        // footer that still advertised `enter runs it` while the keys were
        // talking to the pane would be the kind of small lie that gets
        // believed.
        let foot = match &frame.edit {
            // The field IS the footer. A separate line for it would cost a row
            // on every screen to serve the one moment something is being
            // typed, and the footer is already where this program answers
            // "what do the keys do now".
            Some(e) => {
                let label = match &e.what {
                    Asking::Filter => "filter".to_string(),
                    Asking::Screen(l) => l.clone(),
                };
                let hint = match &e.what {
                    Asking::Filter if vis.is_empty() => "  (nothing matches)",
                    Asking::Filter => "  \u{2191}\u{2193} move \u{b7} enter keep \u{b7} esc clear",
                    Asking::Screen(_) => "  enter accept \u{b7} esc cancel",
                };
                format!("{label}: {}\u{2588}{hint}", e.text)
            }
            None if !frame.filter.is_empty() => format!(
                // Said out loud, because a list that is quietly hiding rows is
                // the worst thing a filter can do -- you look for something,
                // it is not there, and nothing says why.
                "{} \u{b7} filtering on \"{}\" \u{b7} / to change \u{b7} esc to clear",
                frame.screen.footer(),
                frame.filter
            ),
            None => match frame.focus {
                Focus::List => frame.screen.footer(),
                Focus::Tabs => {
                    "h/l pick a tab \u{b7} j into it \u{b7} enter takes you there".into()
                }
                // The position, not the visible range: the range would need the
                // pane height, which comes from the layout, which needs this
                // string's line count. Circular for no gain.
                Focus::Pane => format!(
                "j/k scroll \u{b7} ctrl-d/u page \u{b7} h back to the list \u{b7} line {} of {}",
                frame.pane_top + 1,
                pane_lines
            ),
            },
        };
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
                Some(frame.screen.pane(cur, cols.saturating_sub(left + 1), ph))
            };
            draw_frame(
                &mut out,
                frame.screen.as_mut(),
                &Chrome {
                    tabs: tabs.as_ref(),
                    focus: frame.focus,
                    cols,
                    rows: screen_rows,
                    left: if full { None } else { Some(left) },
                    geo: &geo,
                },
            )?;
            pane_lines = pane.as_ref().map(|p| p.lines.len()).unwrap_or(0);
            // How far the pane can scroll: what it holds, less what fits. Zero
            // means focus has no business going in there.
            pane_room = pane_lines.saturating_sub(ph as usize);
            if frame.pane_top > pane_room {
                frame.pane_top = pane_room;
            }
            if let Some(pane) = &pane {
                draw_pane(
                    &mut out,
                    pane,
                    left + 1,
                    geo.header_h,
                    cols.saturating_sub(left + 1),
                    ph,
                    frame.pane_top,
                )?;
            }
            pane_dirty = false;
        }
        draw_rows(
            &mut out,
            &rows,
            &vis,
            &View {
                top: frame.top,
                sel: frame.sel,
                // Only the focused region wears the brackets. Two cursors on
                // screen at once is two answers to "where am I".
                reticle: (frame.focus == Focus::List).then_some(&frame.reticle),
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
        // While a field has the keyboard, bare letters are text. Set from the
        // frame on every iteration rather than tracked alongside it, so a
        // push, a pop, a detach or a tab switch cannot leave the keymap in the
        // wrong mode -- which is the one failure here that would be silent and
        // total: every single-key action firing while you tried to type.
        keys.typing(frame.edit.is_some());

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
                let len = vis.len();

                // A field has the keyboard: everything but motion is text.
                //
                // An `if/else` rather than an early `continue`, which is how
                // the first version was written and was wrong: `continue`
                // skipped the bottom of the loop, so a `Flow::Push` or
                // `Flow::Pop` returned by `answered` was silently dropped --
                // a screen asking for a name and then opening something with
                // it would have done nothing.
                if frame.edit.is_some() {
                    let mut done: Option<Option<String>> = None;
                    {
                        let edit = frame.edit.as_mut().expect("checked");
                        match action {
                            Action::Type(c) => edit.text.push(c),
                            Action::Backspace => {
                                edit.text.pop();
                            }
                            Action::Clear => edit.text.clear(),
                            Action::Accept => done = Some(Some(edit.text.clone())),
                            Action::Cancel => done = Some(None),
                            Action::Quit => return Ok(()),
                            _ => {}
                        }
                    }
                    // A filter applies on every keystroke, so the list moves
                    // under you as you type -- which is what made fzf feel
                    // like filtering rather than like a query box. A screen's
                    // question does not exist until it is accepted.
                    let filtering =
                        matches!(frame.edit.as_ref().map(|e| &e.what), Some(Asking::Filter));
                    let narrowed = if filtering {
                        let next = frame
                            .edit
                            .as_ref()
                            .map(|e| e.text.clone())
                            .unwrap_or_default();
                        let changed = next != frame.filter;
                        frame.filter = next;
                        changed
                    } else {
                        false
                    };
                    // Arrows move through the filtered list without leaving
                    // the field: type a bit, arrow down, enter.
                    vis = crate::filter::visible(&rows, &frame.filter);
                    match action {
                        Action::Down => frame.sel = seek(&rows, &vis, frame.sel, 1),
                        Action::Up => frame.sel = seek(&rows, &vis, frame.sel, -1),
                        _ => {}
                    }
                    if let Some(answer) = done {
                        let edit = frame.edit.take().expect("checked");
                        match edit.what {
                            Asking::Filter => {
                                if answer.is_none() {
                                    // Abandoned: the list comes back whole and
                                    // the cursor returns to the row it was on,
                                    // which is why `was` is recorded at all.
                                    frame.filter.clear();
                                    frame.sel = edit.was;
                                }
                            }
                            Asking::Screen(_) => match frame.screen.answered(answer) {
                                Flow::Quit => return Ok(()),
                                Flow::Pop => popped = depth > 1,
                                Flow::Push(next) => pushed = Some(next),
                                Flow::Detach(argv) => detach(term, &mut out, &argv)?,
                                _ => {}
                            },
                        }
                        rows = frame.screen.rows();
                        vis = crate::filter::visible(&rows, &frame.filter);
                    }
                    if narrowed {
                        // Land on the match, not on the heading above it.
                        frame.sel = crate::filter::first_leaf(&rows, &vis);
                    }
                    frame.sel = frame.sel.min(vis.len().saturating_sub(1));
                    frame.sel = first_selectable(&rows, &vis, frame.sel, -1);
                    pane_dirty = true;
                } else {
                    match action {
                        // At the root this leaves; anywhere else it goes back one
                        // screen, which is what every other pane-and-list tool in
                        // this repo trained your fingers to expect.
                        Action::Quit => {
                            // A filter in force is cleared FIRST. Without this,
                            // `esc` on a narrowed list throws away the screen you
                            // were on -- a surprising amount to lose for a key
                            // pressed meaning "show me everything again" -- and
                            // the footer says it clears.
                            if !frame.filter.is_empty() {
                                frame.filter.clear();
                                vis = crate::filter::visible(&rows, &frame.filter);
                                frame.sel = first_selectable(&rows, &vis, frame.sel, -1);
                                frame.reticle = Reticle::new(frame.sel);
                                pane_dirty = true;
                            } else if depth == 1 {
                                return Ok(());
                            } else {
                                popped = true;
                            }
                        }
                        // ── j: down, or out of the strip into the list ──
                        Action::Down => match frame.focus {
                            Focus::Tabs => {
                                frame.focus = Focus::List;
                                pane_dirty = true;
                            }
                            // Every motion lands on a SELECTABLE row. Spacers exist
                            // to group things visually; a cursor that can rest in
                            // one turns them into potholes.
                            Focus::List => frame.sel = seek(&rows, &vis, frame.sel, 1),
                            Focus::Pane => {
                                frame.pane_top = (frame.pane_top + 1).min(pane_room);
                                pane_dirty = true;
                            }
                        },
                        // ── k: up, and off the top row into the strip ──
                        Action::Up => match frame.focus {
                            Focus::Tabs => {}
                            Focus::List => {
                                let next = seek(&rows, &vis, frame.sel, -1);
                                if next == frame.sel && tabs.is_some() {
                                    // Already at the first selectable row, so `k`
                                    // had nothing to do here -- that is the door.
                                    frame.focus = Focus::Tabs;
                                    pane_dirty = true;
                                } else {
                                    frame.sel = next;
                                }
                            }
                            Focus::Pane => {
                                frame.pane_top = frame.pane_top.saturating_sub(1);
                                pane_dirty = true;
                            }
                        },
                        Action::Top => match frame.focus {
                            Focus::Pane => {
                                frame.pane_top = 0;
                                pane_dirty = true;
                            }
                            _ => {
                                frame.focus = Focus::List;
                                frame.sel = first_selectable(&rows, &vis, 0, 1);
                            }
                        },
                        Action::Bottom => match frame.focus {
                            Focus::Pane => {
                                frame.pane_top = pane_room;
                                pane_dirty = true;
                            }
                            _ => {
                                frame.focus = Focus::List;
                                frame.sel =
                                    first_selectable(&rows, &vis, len.saturating_sub(1), -1);
                            }
                        },
                        Action::PageDown => match frame.focus {
                            Focus::Pane => {
                                frame.pane_top = (frame.pane_top + list_h / 2).min(pane_room);
                                pane_dirty = true;
                            }
                            _ => {
                                let want = (frame.sel + list_h / 2).min(len.saturating_sub(1));
                                frame.sel = first_selectable(&rows, &vis, want, -1);
                            }
                        },
                        Action::PageUp => match frame.focus {
                            Focus::Pane => {
                                frame.pane_top = frame.pane_top.saturating_sub(list_h / 2);
                                pane_dirty = true;
                            }
                            _ => {
                                let want = frame.sel.saturating_sub(list_h / 2);
                                frame.sel = first_selectable(&rows, &vis, want, 1);
                            }
                        },
                        // ── h: collapse, or leftwards out of a region ──
                        Action::Close if frame.focus == Focus::Pane => {
                            frame.focus = Focus::List;
                            pane_dirty = true;
                        }
                        Action::Close if frame.focus == Focus::Tabs => {
                            // In the strip, left and right ARE the tabs.
                            if let Flow::Retarget = frame.screen.on_action(Action::PrevTab, cur) {
                                rows = frame.screen.rows();
                                vis = crate::filter::visible(&rows, &frame.filter);
                                frame.sel = start_sel(frame.screen.as_ref(), &rows, &vis);
                                frame.top = 0;
                                frame.pane_top = 0;
                                frame.reticle = Reticle::new(frame.sel);
                                pane_dirty = true;
                            }
                        }
                        Action::Open if frame.focus == Focus::Tabs => {
                            if let Flow::Retarget = frame.screen.on_action(Action::NextTab, cur) {
                                rows = frame.screen.rows();
                                vis = crate::filter::visible(&rows, &frame.filter);
                                frame.sel = start_sel(frame.screen.as_ref(), &rows, &vis);
                                frame.top = 0;
                                frame.pane_top = 0;
                                frame.reticle = Reticle::new(frame.sel);
                                pane_dirty = true;
                            }
                        }
                        // Enter on the strip commits the tab and drops into it,
                        // which is what a smart TV does and what the hand expects.
                        Action::Activate if frame.focus == Focus::Tabs => {
                            frame.focus = Focus::List;
                            pane_dirty = true;
                        }
                        // `/` narrows the list. Framework-owned, so it works on
                        // every screen including the ones written before it
                        // existed.
                        Action::Find => {
                            frame.edit = Some(Edit {
                                what: Asking::Filter,
                                text: frame.filter.clone(),
                                was: frame.sel,
                            });
                            frame.focus = Focus::List;
                            pane_dirty = true;
                        }
                        other => match frame.screen.on_action(other, cur) {
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
                            Flow::Ask { label, initial } => {
                                frame.edit = Some(Edit {
                                    what: Asking::Screen(label),
                                    text: initial,
                                    was: frame.sel,
                                });
                                pane_dirty = true;
                            }
                            Flow::Retarget => {
                                rows = frame.screen.rows();
                                vis = crate::filter::visible(&rows, &frame.filter);
                                frame.sel = start_sel(frame.screen.as_ref(), &rows, &vis);
                                frame.top = 0;
                                frame.reticle = Reticle::new(frame.sel);
                                frame.screen.focus(vis.get(frame.sel).copied().unwrap_or(0));
                                pane_dirty = true;
                            }
                            // The screen did nothing with it. For `l` that is the
                            // door to the pane.
                            //
                            // Whenever a pane EXISTS, not only when it overflows.
                            // Gating on scrollability was the first attempt and it
                            // reads as a dead key: on a run whose body happens to
                            // fit, `l` silently did nothing, which is exactly the
                            // "why won't it move" the directional model is supposed
                            // to remove. The divider lights up and the footer
                            // changes, so the move is visible even when there is
                            // nothing to scroll once you are there.
                            Flow::Continue => {
                                if other == Action::Open && !full {
                                    frame.focus = Focus::Pane;
                                    pane_dirty = true;
                                }
                            }
                        },
                    }
                }
                if frame.sel != before {
                    frame.reticle.aim(frame.sel);
                    // Separate from `pane` on purpose: a row you skim past
                    // still gets prefetched, which is the whole point.
                    frame.screen.focus(vis.get(frame.sel).copied().unwrap_or(0));
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
            let nvis: Vec<usize> = (0..rows.len()).collect();
            let sel = start_sel(next.as_ref(), &rows, &nvis);
            next.focus(nvis.get(sel).copied().unwrap_or(0));
            stack.push(Frame {
                screen: next,
                sel,
                top: 0,
                reticle: Reticle::new(sel),
                focus: Focus::List,
                pane_top: 0,
                filter: String::new(),
                edit: None,
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

/// Everything about the frame that is not the screen itself.
///
/// Bundled because it reached nine arguments once focus became a thing the
/// chrome had to show -- which is a signal rather than a lint. The strip, the
/// divider and the geometry are one description of "the frame around the
/// content", so they travel as one.
struct Chrome<'a> {
    tabs: Option<&'a Tabs>,
    focus: Focus,
    cols: u16,
    rows: u16,
    /// Where the vertical divider goes, or `None` for a full-width list.
    left: Option<u16>,
    geo: &'a Layout,
}

fn draw_frame(out: &mut impl Write, screen: &mut dyn Screen, c: &Chrome) -> io::Result<()> {
    let Chrome {
        tabs,
        focus,
        cols,
        rows,
        left,
        geo,
    } = *c;
    let tabs_focused = focus == Focus::Tabs;
    let pane_focused = focus == Focus::Pane;
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
            queue!(out, style::Print(tab_strip(t, cols, tabs_focused)))?;
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
        // The divider lights up when the PANE has the keys. It is the border
        // between the two regions, so it is the honest place to say which side
        // you are on -- and it needs no extra row to do it.
        let colour = if pane_focused { "211" } else { "240" };
        for r in geo.header_h..rows.saturating_sub(geo.footer_h) {
            queue!(
                out,
                cursor::MoveTo(left, r),
                style::Print(format!("\x1b[38;5;{colour}m\u{2502}\x1b[0m"))
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
fn tab_strip(tabs: &Tabs, cols: u16, focused: bool) -> String {
    let mut out = String::from(" ");
    let mut width = 1usize;
    if let Some(label) = &tabs.label {
        out.push_str(&format!("\x1b[38;5;245m{label}\x1b[0m"));
        width += crate::width::width(label);
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
        let plain = sep.len() + crate::width::width(name) + if i == tabs.active { 4 } else { 0 };
        if width + plain + 1 > cols as usize {
            out.push_str("\x1b[38;5;240m\u{2026}\x1b[0m");
            break;
        }
        out.push_str(sep);
        if i == tabs.active {
            // The reticle's own pink when the strip HAS focus, dim when it
            // does not -- so "where am I" is answered by the same pair of
            // brackets everywhere in this program, rather than by a second
            // idiom to learn.
            let b = if focused { "211" } else { "240" };
            out.push_str(&format!(
                "\x1b[38;5;{b}m[\x1b[1;38;5;255m {name} \x1b[0m\x1b[38;5;{b}m]\x1b[0m"
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
    /// `None` when another region has focus -- the list keeps its selection
    /// highlight, but the brackets belong to whoever the keys are talking to.
    reticle: Option<&'a Reticle>,
}

fn draw_rows(
    out: &mut impl Write,
    rows: &[Row],
    vis: &[usize],
    view: &View,
    left: u16,
    y0: u16,
    height: usize,
) -> io::Result<()> {
    let View { top, sel, reticle } = *view;
    let spread = reticle.map(|r| r.spread()).unwrap_or(0);
    let ret_row = reticle.map(|r| r.row()).unwrap_or(usize::MAX);
    let blank = " ".repeat(left as usize);

    for i in 0..height {
        let y = y0 + i as u16;
        queue!(out, cursor::MoveTo(0, y), style::Print(&blank))?;
        let Some(row) = vis.get(top + i).map(|&r| &rows[r]) else {
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
                .map(|(t, _)| crate::width::width(t) as u16 + 1)
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
        let label_cols = crate::width::width(&label);
        // The reticle hugs the NAME, not the padding. A header padded for
        // column alignment would otherwise read `[ claude      ]`, with the
        // frame closing around whitespace.
        let name_cols = crate::width::width(label.trim_end());

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
            let w = crate::width::width(badge) as u16;
            bx = bx.saturating_sub(w + 1);
            queue!(
                out,
                cursor::MoveTo(bx, y),
                style::Print(format!("\x1b[38;5;{color}m{badge}\x1b[0m"))
            )?;
        }

        if reticle.is_some() && top + i == ret_row && row.selectable {
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
/// Where a screen opens, as a POSITION in the visible list.
///
/// The screen answers in its own row indices -- it knows nothing about a
/// filter -- so the answer is translated here. A row the filter has hidden
/// falls to the nearest visible one rather than nowhere.
fn start_sel(screen: &dyn Screen, rows: &[Row], vis: &[usize]) -> usize {
    if vis.is_empty() {
        return 0;
    }
    let want_row = screen.initial_sel();
    let at = vis
        .iter()
        .position(|&r| r >= want_row)
        .unwrap_or(vis.len() - 1);
    first_selectable(rows, vis, at, 1)
}

/// The nearest selectable POSITION at or after `from`, searching in `dir`.
///
/// Falls back to `from` so a list that is entirely spacers -- or entirely
/// group headings, which a filter can produce -- cannot hang the caller.
fn first_selectable(rows: &[Row], vis: &[usize], from: usize, dir: isize) -> usize {
    let mut i = from as isize;
    while i >= 0 && (i as usize) < vis.len() {
        if rows[vis[i as usize]].selectable {
            return i as usize;
        }
        i += dir;
    }
    from.min(vis.len().saturating_sub(1))
}

/// One step in `dir` through the VISIBLE list, skipping spacers, staying put
/// at the ends.
fn seek(rows: &[Row], vis: &[usize], from: usize, dir: isize) -> usize {
    let mut i = from as isize + dir;
    while i >= 0 && (i as usize) < vis.len() {
        if rows[vis[i as usize]].selectable {
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
    // First text line to draw, for a pane with focus and more than fits.
    scroll: usize,
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
    for (i, line) in pane.lines.iter().skip(scroll).enumerate() {
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
/// Shorten to fit, measured in CELLS.
///
/// Delegates to `width::truncate`, which knows an emoji is two cells and an
/// ANSI escape is none. The character-counting version this replaces was the
/// reason emoji had to be kept out of every fixed-width column: one `char`
/// that draws two cells shifted everything after it by one.
fn truncate(s: &str, width: u16) -> String {
    crate::width::truncate(s, width as usize)
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
        let all: Vec<usize> = (0..rows.len()).collect();
        assert_eq!(seek(&rows, &all, 0, 1), 2);
        assert_eq!(seek(&rows, &all, 2, 1), 4);
        assert_eq!(seek(&rows, &all, 4, -1), 2);
        assert_eq!(seek(&rows, &all, 2, -1), 0);
    }

    /// At the ends, staying put beats wrapping or landing on a blank.
    #[test]
    fn motion_stops_at_the_ends() {
        let rows = list();
        let all: Vec<usize> = (0..rows.len()).collect();
        assert_eq!(seek(&rows, &all, 0, -1), 0);
        assert_eq!(seek(&rows, &all, 4, 1), 4);
    }

    /// G aims at the last row, which is not necessarily a selectable one.
    #[test]
    fn ends_seek_backwards_to_something_selectable() {
        let mut rows = list();
        rows.push(Row::spacer());
        let all: Vec<usize> = (0..rows.len()).collect();
        assert_eq!(first_selectable(&rows, &all, rows.len() - 1, -1), 4);
        assert_eq!(first_selectable(&rows, &all, 1, 1), 2);
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
