//! `font` — pick the font for each of wezterm's lanes.
//!
//! The tree is the four lanes; opening one lists the installed families under
//! it with a fit verdict, and Enter sets it. That shape is not decoration: it
//! is the same tree `make it` needs, exercised on a screen small enough to get
//! right, so the model is proven before the bigger screen leans on it.
//!
//! Why a lane has a VERDICT rather than a score: a font is not good or bad on
//! its own, it is good or bad AT A JOB. The same family is the right pick for
//! `shell` and the wrong one for `claude`, and no single number says so.

mod browse;
mod fetch;
mod fonts;
mod lanes;
mod render;
mod theme;

use std::collections::HashMap;

use reticle::{app, nav::Action, Flow, Image, Pane, Row, Screen};

struct Loaded {
    metrics: fonts::Metrics,
    font: fontdue::Font,
    cuts: Vec<String>,
}

#[derive(PartialEq, Clone, Copy)]
pub enum Preview {
    /// Every family in view, one row each, for comparing.
    Sheet,
    /// One family doing the lane's actual job, for committing.
    Specimen,
}

struct FontScreen {
    families: Vec<String>,
    state: Vec<(String, String)>,
    open: Option<usize>,
    cache: HashMap<String, Option<Loaded>>,
    status: String,
    preview: Preview,
    size: f32,
}

impl FontScreen {
    fn new() -> Self {
        Self {
            families: fonts::families(),
            state: lanes::read(),
            open: None,
            cache: HashMap::new(),
            status: String::new(),
            preview: Preview::Sheet,
            size: 20.0,
        }
    }

    fn load(&mut self, family: &str) -> Option<&Loaded> {
        if !self.cache.contains_key(family) {
            let cuts = fonts::cuts_of(family);
            let regular = cuts
                .get("Regular")
                .or_else(|| cuts.values().next())
                .cloned();
            let loaded = regular.and_then(|path| {
                let (data, metrics) = fonts::measure(&path)?;
                let font = render::load(&data)?;
                Some(Loaded {
                    metrics,
                    font,
                    cuts: cuts.keys().cloned().collect(),
                })
            });
            self.cache.insert(family.to_string(), loaded);
        }
        self.cache.get(family).and_then(|o| o.as_ref())
    }

    fn ui_advance(&mut self) -> f32 {
        let ui = self
            .state
            .iter()
            .find(|(l, _)| l == "nvim.ui")
            .map(|(_, v)| v.clone());
        ui.and_then(|f| self.load(&f).map(|l| l.metrics.advance))
            .unwrap_or(0.0)
    }

    /// Which rows are lane headers and which are fonts, in display order.
    fn layout(&self) -> Vec<Entry> {
        let mut out = Vec::new();
        for (i, (lane, current)) in self.state.iter().enumerate() {
            if i > 0 {
                out.push(Entry::Gap);
            }
            out.push(Entry::Lane(i, lane.clone(), current.clone()));
            if self.open == Some(i) {
                for f in &self.families {
                    out.push(Entry::Font(i, f.clone()));
                }
                out.push(Entry::Browse(i));
            }
        }
        out
    }
}

#[derive(Clone)]
enum Entry {
    /// A blank row between lanes. They are categories; spacing is what says so.
    Gap,
    Lane(usize, String, String),
    Font(usize, String),
    /// The last row under an open lane. A row rather than a keybinding because
    /// the screen is supposed to explain itself — a key you have to be told
    /// about is a key nobody finds.
    Browse(usize),
}

fn verdict(lane: &str, l: &Loaded, ui_advance: f32) -> (&'static str, u8, String) {
    let m = &l.metrics;
    if !m.fixed {
        return (
            "POOR",
            210,
            "not fixed-pitch — columns will not line up".into(),
        );
    }
    match lane {
        "claude" => {
            if m.critical < fonts::CRITICAL.len() {
                (
                    "POOR",
                    210,
                    format!(
                        "missing {} — drawn on every tool call",
                        m.missing.join(", ")
                    ),
                )
            } else if m.frequent < fonts::FREQUENT.len() {
                ("OK", 221, "the per-tool-call glyphs are native".into())
            } else if m.incidental < fonts::INCIDENTAL.len() {
                (
                    "OK",
                    221,
                    "critical and frequent native; some punctuation falls back".into(),
                )
            } else {
                ("GOOD", 114, "all nine TUI glyphs native".into())
            }
        }
        "nvim.editor" => {
            let italic = l.cuts.iter().any(|c| c == "Italic");
            if !italic {
                (
                    "POOR",
                    210,
                    "no Italic cut — every comment loses its slant".into(),
                )
            } else if ui_advance > 0.0 && m.advance > ui_advance + 1e-4 {
                (
                    "POOR",
                    210,
                    format!(
                        "wider than the ui cell ({:.3}em) — glyphs collide",
                        ui_advance
                    ),
                )
            } else {
                ("GOOD", 114, "has Italic and fits the ui cell".into())
            }
        }
        _ => {
            if m.nerd {
                ("GOOD", 114, "nerd icons native, at cell width".into())
            } else {
                (
                    "OK",
                    221,
                    "no nerd glyphs — the fallback draws them oversized".into(),
                )
            }
        }
    }
}

const SAMPLE: &str = "The quick brown fox 0O1lI {}[]";

/// What the pane draws in SPECIMEN mode: the lane's actual job, in the
/// candidate face.
///
/// A pangram tells you the letterforms and nothing about whether the font can
/// do the WORK. For `claude` that work is a tool-call transcript, and the two
/// glyphs it leans on -- U+23FA and U+23BF -- are exactly the ones most coding
/// fonts lack. Seeing them in place beats reading "critical 0/2": a fallback at
/// the wrong cell width is something you recognise instantly and would struggle
/// to predict from a number.
/// What the pane draws in SPECIMEN mode: the lane's actual job, in the
/// candidate face and THIS MACHINE'S colours.
///
/// A pangram tells you the letterforms and nothing about whether the font can
/// do the work. For `claude` that work is a tool-call transcript, and the two
/// glyphs it leans on — U+23FA and U+23BF — are exactly the ones most coding
/// fonts lack. For `shell` it is the real PS1 out of ~/.bash_theme, because a
/// prompt you look at fifty times a day is the honest test.
pub fn specimen(lane: &str) -> Vec<theme::Line> {
    let fg = theme::fg();
    let dim = theme::dim();
    let ok = theme::idx(114, [0xa6, 0xe3, 0xa1]);
    let warm = theme::idx(221, [0xf9, 0xe2, 0xaf]);
    let cyan = theme::idx(110, [0x9c, 0xcf, 0xd8]);

    let line = |text: &str, c: [u8; 3]| -> theme::Line { vec![(text.to_string(), c)] };
    let blank = || -> theme::Line { vec![] };

    match lane {
        "claude" => vec![
            line("\u{2733} claude \u{00b7} ~/dotfiles", warm),
            blank(),
            line("\u{23FA} Bash(cargo build --release)", ok),
            line("  \u{23BF}  Finished `release` in 0.83s", dim),
            blank(),
            line("\u{23FA} Read(tui/font/src/main.rs)", ok),
            line("  \u{23BF}  Read 312 lines", dim),
            blank(),
            line(
                "\u{25D0} Thinking\u{2026}   \u{2610} draft  \u{2612} build  \u{2713} test",
                dim,
            ),
            blank(),
            line("> how do I try it?", fg),
        ],
        "nvim.editor" => vec![
            line("-- lanes.rs \u{00b7} 42:8", dim),
            blank(),
            line("pub fn read() -> Vec<(String, String)> {", fg),
            line(
                "    // truncate-and-write, not rename \u{2014} see the note",
                dim,
            ),
            line("    let text = fs::read_to_string(path)", fg),
            line("        .unwrap_or_default();", fg),
            line("    let name = \"0xProto Nerd Font\";", ok),
            line("    if a != b && c >= d || e <= f { .. }", fg),
            line("}", fg),
        ],
        "nvim.ui" => vec![
            line("\u{f07b} nvim  \u{f0e7} oil \u{00b7} ~/dotfiles/tui", cyan),
            blank(),
            line("  ../", dim),
            line("  \u{f115} font/", cyan),
            line("  \u{f115} reticle/", cyan),
            line("  \u{f15b} Cargo.toml         412 B", fg),
            line("  \u{f15b} deps.sh            1.1 K", fg),
            blank(),
            line("  NORMAL   tui/font/src   42:8   utf-8", dim),
        ],
        // The shell lane gets the real prompt, then a session around it.
        _ => {
            let mut out: Vec<theme::Line> = Vec::new();
            for l in theme::prompt_lines() {
                out.push(l);
            }
            if let Some(last) = out.last_mut() {
                last.push(("eza -la --icons --git".into(), fg));
            }
            out.push(blank());
            out.push(line("  \u{f15b} deps.conf      2.1K  M", dim));
            out.push(line("  \u{f115} tui/           4.0K", cyan));
            out.push(line("  \u{f15b} Makefile       8.7K", dim));
            out.push(blank());
            out.push(line(
                "  \u{2713} font  ok   0O1lI {}[] => != === \u{f408}",
                ok,
            ));
            out
        }
    }
}

impl Screen for FontScreen {
    fn title(&self) -> String {
        "  fonts — the four lanes wezterm draws with".into()
    }

    fn rows(&mut self) -> Vec<Row> {
        let ui_adv = self.ui_advance();
        let entries = self.layout();
        let mut out = Vec::new();
        for e in entries {
            match e {
                Entry::Gap => out.push(Row::spacer()),
                Entry::Lane(i, lane, current) => {
                    // Label and value are separate columns so the label can be
                    // bold and aligned while the value stays dim behind it.
                    let mut r = Row::leaf(format!("{lane:<11}")).detail(current);
                    r.group = true;
                    r.expanded = self.open == Some(i);
                    out.push(r);
                }
                Entry::Browse(_) => {
                    let mut r = Row::leaf("browse Google fonts\u{2026}");
                    r.depth = 1;
                    out.push(r);
                }
                Entry::Font(i, family) => {
                    let lane = self.state[i].0.clone();
                    let badge = self
                        .load(&family)
                        .map(|l| verdict(&lane, l, ui_adv))
                        .map(|(v, c, _)| (v.to_string(), c));
                    let mut r = Row::leaf(family);
                    r.depth = 1;
                    r.badge = badge;
                    out.push(r);
                }
            }
        }
        out
    }

    fn footer(&self) -> String {
        if !self.status.is_empty() {
            return self.status.clone();
        }
        let mode = match self.preview {
            Preview::Sheet => "specimen",
            Preview::Specimen => "sheet",
        };
        format!(
            "j/k move · l open · enter set · p {mode} · +/- size {:.0} · gg/G",
            self.size
        )
    }

    fn pane(&mut self, sel: usize, cols: u16, rows: u16) -> Pane {
        let entries = self.layout();
        let ui_adv = self.ui_advance();
        let mut pane = Pane::default();

        let Some(entry) = entries.get(sel).cloned() else {
            return pane;
        };
        let (lane, family) = match entry {
            Entry::Gap => return pane,
            Entry::Browse(i) => {
                let lane = self.state[i].0.clone();
                pane.lines.push("\x1b[1mbrowse Google fonts\x1b[0m".into());
                pane.lines.push(String::new());
                pane.lines
                    .push(format!("  ~50 monospace families, judged for {lane}."));
                pane.lines.push(String::new());
                pane.lines.push(
                    "  \x1b[38;5;244mNothing is installed by looking. Each family is\x1b[0m".into(),
                );
                pane.lines.push(
                    "  \x1b[38;5;244mfetched to ~/.cache/dotfiles-fonts and previewed\x1b[0m"
                        .into(),
                );
                pane.lines.push(
                    "  \x1b[38;5;244mthere; the rows around the cursor come too, so the\x1b[0m"
                        .into(),
                );
                pane.lines
                    .push("  \x1b[38;5;244mnext one has already arrived.\x1b[0m".into());
                pane.lines.push(String::new());
                pane.lines.push(
                    "  \x1b[38;5;221mNone are Nerd-patched — icons fall back oversized.\x1b[0m"
                        .into(),
                );
                return pane;
            }
            Entry::Lane(i, lane, current) => {
                pane.lines.push(format!("\x1b[1m{lane}\x1b[0m"));
                pane.lines
                    .push(format!("\x1b[38;5;244m{}\x1b[0m", lanes::covers(&lane)));
                pane.lines.push(String::new());
                pane.lines.push(format!("  now: {current}"));
                pane.lines.push(String::new());
                pane.lines
                    .push("\x1b[38;5;244m  l or → to list the installed families\x1b[0m".into());
                let _ = i;
                return pane;
            }
            Entry::Font(i, f) => (self.state[i].0.clone(), f),
        };

        // The contact sheet: every font this lane could take, each row drawn in
        // ITS OWN face, the current one marked. Comparing by scrolling beats
        // landing on each one in turn.
        let art_rows = rows.saturating_sub(16) as usize;

        // SPECIMEN: one family doing the lane's actual job. Exclusive with the
        // sheet below, because the pane holds one image.
        //
        // `supported()` is checked here as well as in the framework so a
        // terminal without inline images does not pay to rasterise something it
        // cannot show.
        if self.preview == Preview::Specimen && art_rows >= 6 && reticle::image::supported() {
            let lines = specimen(&lane);
            let size = self.size;
            let row_h = (size * 1.55) as usize;
            // EXACTLY the pixels the terminal will give these cells, so the
            // image is drawn 1:1 instead of resampled. Resampled text is the
            // blur; nothing else about the rasteriser was ever the problem.
            let (cw, ch) = reticle::term_info().cell;
            let canvas_w = cols as usize * cw as usize;
            let canvas_h = art_rows * ch as usize;
            let mut c = render::Canvas::new(canvas_w, canvas_h, theme::bg());
            let drew = if let Some(l) = self.load(&family) {
                for (n, runs) in lines.iter().enumerate() {
                    let base = (ch as usize / 2 + n * row_h) as i32 + size as i32;
                    let mut x = (cw as i32) * 2;
                    for (text, color) in runs {
                        x = c.text(&l.font, size, x, base, text, *color);
                    }
                }
                true
            } else {
                false
            };
            if drew {
                if let Some(png) = c.to_png() {
                    pane.image = Some(Image {
                        png,
                        rows: art_rows as u16,
                    });
                }
            }
        }

        let sheet_rows = art_rows.min(self.families.len());
        if self.preview == Preview::Sheet && sheet_rows >= 3 && reticle::image::supported() {
            let idx = self.families.iter().position(|f| *f == family).unwrap_or(0);
            let lo = idx
                .saturating_sub(sheet_rows / 2)
                .min(self.families.len() - sheet_rows);
            let window: Vec<String> = self.families[lo..lo + sheet_rows].to_vec();
            // The canvas aspect decides the rendered width, because the image
            // is sized by HEIGHT and the terminal derives the rest. A fixed
            // 900px canvas therefore filled a fixed fraction of the pane
            // whatever its width. Scaling by `cols` makes a wide pane actually
            // use its width -- ~14px of canvas per cell is the ratio that lands
            // near full width at a typical cell aspect, and the clamp keeps a
            // very wide terminal from encoding a needlessly large PNG.
            // One font per terminal ROW, at the terminal's own cell size, so
            // the sheet is drawn 1:1 rather than squeezed into whatever the
            // scaler makes of a 34px row.
            let (cw, ch) = reticle::term_info().cell;
            let row_h = ch as usize;
            let canvas_w = cols as usize * cw as usize;
            let mut c = render::Canvas::new(canvas_w, row_h * window.len(), theme::bg());
            let sample_x = (canvas_w as f32 * 0.42) as i32;
            let sheet_size = ch as f32 * 0.72;
            for (n, fam) in window.iter().enumerate() {
                let y = n * row_h;
                if *fam == family {
                    c.fill(0, y, canvas_w, row_h, theme::selection());
                }
                let Some(l) = self.load(fam) else { continue };
                let base = (y + row_h) as i32 - (row_h as i32 / 5);
                let f = &l.font;
                c.text(f, sheet_size, (cw as i32) * 2, base, fam, theme::fg());
                c.text(f, sheet_size, sample_x, base, SAMPLE, theme::dim());
            }
            if let Some(png) = c.to_png() {
                pane.image = Some(Image {
                    png,
                    rows: sheet_rows as u16,
                });
            }
        }

        if !reticle::image::supported() {
            pane.lines.push(
                "\x1b[38;5;244m  (the contact sheet needs wezterm — metrics only here)\x1b[0m"
                    .into(),
            );
            pane.lines.push(String::new());
        }

        let Some(l) = self.load(&family) else {
            pane.lines.push(format!("{family} — unreadable"));
            return pane;
        };
        let m = &l.metrics;
        let (v, color, why) = verdict(&lane, l, ui_adv);
        let d = |a: char, b: char| render::distinct(&l.font, a, b, 64.0) * 100.0;
        let (oo, il, li) = (d('0', 'O'), d('1', 'l'), d('l', 'I'));
        let cuts = l.cuts.join(", ");
        let ligs = if m.ligatures.is_empty() {
            "none".to_string()
        } else {
            m.ligatures.join(", ")
        };

        pane.lines.push(format!("\x1b[1m{family}\x1b[0m"));
        pane.lines.push(String::new());
        pane.lines.push(format!(
            "  space   {:.3}em wide · {:.3}em line · x-height {:.3}",
            m.advance, m.line, m.x_height
        ));
        if let Some((lo, hi)) = m.variable {
            pane.lines
                .push(format!("  weight  {} · variable {lo:.0}–{hi:.0}", m.weight));
        } else {
            pane.lines.push(format!("  weight  {}", m.weight));
        }
        pane.lines.push(format!(
            "  glyphs  0/O {oo:.0}%  1/l {il:.0}%  l/I {li:.0}%"
        ));
        pane.lines
            .push(format!("  extras  ligatures {ligs} · {} glyphs", m.glyphs));
        pane.lines.push(format!(
            "          powerline {} · {} · box {}/128",
            m.powerline,
            if m.braille { "braille" } else { "no braille" },
            m.box_drawing
        ));
        pane.lines.push(format!("  cuts    {cuts}"));
        pane.lines.push(format!(
            "  claude  critical {}/2  frequent {}/2  incidental {}/5",
            m.critical, m.frequent, m.incidental
        ));
        pane.lines.push(String::new());
        pane.lines.push(format!(
            "  fit \x1b[38;5;{color}m{v}\x1b[0m for {lane} — {why}"
        ));
        pane
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        let entries = self.layout();
        let Some(entry) = entries.get(sel).cloned() else {
            return Flow::Continue;
        };
        self.status.clear();
        match (action, entry) {
            (_, Entry::Gap) => Flow::Continue,
            (Action::Open, Entry::Lane(i, ..)) => {
                self.open = Some(i);
                Flow::Dirty
            }
            (Action::Close, Entry::Lane(..)) => {
                self.open = None;
                Flow::Dirty
            }
            (Action::Close, Entry::Font(i, _)) => {
                self.open = None;
                let _ = i;
                Flow::Dirty
            }
            (Action::Activate, Entry::Lane(i, ..)) => {
                self.open = if self.open == Some(i) { None } else { Some(i) };
                Flow::Dirty
            }
            (Action::Activate, Entry::Browse(i)) | (Action::Open, Entry::Browse(i)) => {
                let lane = self.state[i].0.clone();
                Flow::Push(Box::new(browse::BrowseScreen::new(lane)))
            }
            (Action::Close, Entry::Browse(_)) => {
                self.open = None;
                Flow::Dirty
            }
            (Action::Activate, Entry::Font(i, family)) => {
                self.state[i].1 = family.clone();
                match lanes::write(&self.state) {
                    Ok(()) => self.status = format!("{} → {family}", self.state[i].0),
                    Err(e) => self.status = format!("could not write: {e}"),
                }
                Flow::Dirty
            }
            // Screen-local keys arrive as Action::Key rather than being added to
            // the shared table in reticle::nav, so a key added here can never
            // change what it means in gh-tui or the make-it console.
            (Action::Key('p'), _) => {
                self.preview = match self.preview {
                    Preview::Sheet => Preview::Specimen,
                    Preview::Specimen => Preview::Sheet,
                };
                Flow::Dirty
            }
            (Action::Key('+'), _) | (Action::Key('='), _) => {
                self.size = (self.size + 2.0).min(48.0);
                Flow::Dirty
            }
            (Action::Key('-'), _) => {
                self.size = (self.size - 2.0).max(10.0);
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }
}

fn main() -> std::io::Result<()> {
    // Rust ignores SIGPIPE and turns the resulting write error into a PANIC, so
    // `font inspect x.ttf | head` printed a backtrace instead of stopping. Every
    // other command-line tool on the machine dies quietly there; restoring the
    // default handler is what makes this one behave the same.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    match std::env::args().nth(1).as_deref() {
        Some("show") => {
            for (lane, value) in lanes::read() {
                println!("  {lane:<12}{value:<28} {}", lanes::covers(&lane));
            }
            println!("\n  state: {}", lanes::state_path().display());
        }
        Some("reset") => {
            let _ = std::fs::remove_file(lanes::state_path());
            println!("Fonts reset to the defaults in wezterm/wezterm.lua");
        }
        // Undocumented, for the CI check that the Rust list matches the bash
        // one it replaces. Not in --help: it is a test hook, not a feature.
        Some("-h") | Some("--help") => {
            println!("font           pick the font for each of wezterm's lanes");
            println!("font show      what is set now");
            println!("font reset     back to the defaults wezterm.lua ships");
            println!();
            println!("Browsing Google's fonts is inside the picker: open a lane,");
            println!("then the last row under it. The screen explains its own keys.");
            println!();
            println!("in the picker: j/k move · h/l close/open · gg/G ends");
            println!("               ctrl-d/u page · enter set · q quit");
        }
        _ => {
            app::run(Box::new(FontScreen::new()))?;
        }
    }
    Ok(())
}
