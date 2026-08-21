//! `font browse` — try Google's monospace fonts without installing them.
//!
//! Same tree, same keys, same specimen modes as the picker. The only new idea
//! is that a row's font may not exist yet, so the pane has a third state
//! besides "here it is" and "cannot read it": "on its way". See `fetch`.

use std::collections::HashMap;
use std::path::PathBuf;

use reticle::{nav::Action, Flow, Image, Pane, Row, Screen, Tick};

use crate::fetch::{self, Fetch, Fetcher};
use crate::{fonts, render, specimen, Preview};

/// How many rows either side to pull in. Four covers a `ctrl-d` half-page on a
/// short pane and a comfortable j-hold on a tall one; much more and a skim down
/// the list queues fifty downloads nobody asked for.
const PREFETCH_RADIUS: usize = 4;

struct Loaded {
    metrics: fonts::Metrics,
    font: fontdue::Font,
    styles: Vec<String>,
    paths: Vec<PathBuf>,
}

pub struct BrowseScreen {
    items: Vec<(String, String)>, // (slug, family name)
    fetcher: Fetcher,
    loaded: HashMap<String, Option<Loaded>>,
    epoch_seen: u64,
    lane: String,
    preview: Preview,
    size: f32,
    status: String,
}

impl BrowseScreen {
    pub fn new(lane: String) -> Self {
        Self {
            items: fetch::catalogue(),
            fetcher: Fetcher::new(),
            loaded: HashMap::new(),
            epoch_seen: 0,
            lane,
            preview: Preview::Specimen,
            size: 20.0,
            status: String::new(),
        }
    }

    /// Parse on first sight, then keep it. A family's file does not change
    /// under us, and re-parsing on every frame of a specimen would undo the
    /// whole point of holding state in a process.
    fn load(&mut self, slug: &str) -> Option<&Loaded> {
        if !self.loaded.contains_key(slug) {
            let Some(Fetch::Ready(paths)) = self.fetcher.get(slug) else {
                return None;
            };
            // Measure the upright Regular, not whatever sorted first: a family
            // given as four static cuts otherwise reports its BoldItalic.
            let pick = paths
                .iter()
                .find(|p| {
                    let n = p.to_string_lossy().to_ascii_lowercase();
                    !n.contains("italic") && !n.contains("oblique") && n.contains("regular")
                })
                .or_else(|| {
                    paths.iter().find(|p| {
                        let n = p.to_string_lossy().to_ascii_lowercase();
                        !n.contains("italic") && !n.contains("oblique")
                    })
                })
                .or_else(|| paths.first())
                .cloned();

            let value = pick.and_then(|p| {
                let (data, metrics) = fonts::measure(&p.to_string_lossy())?;
                let font = render::load(&data)?;
                let strings: Vec<String> = paths
                    .iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect();
                Some(Loaded {
                    metrics,
                    font,
                    styles: fonts::styles_of_files(&strings),
                    paths: paths.clone(),
                })
            });
            self.loaded.insert(slug.to_string(), value);
        }
        self.loaded.get(slug).and_then(|o| o.as_ref())
    }

    fn install(&mut self, slug: &str, family: &str) {
        let Some(l) = self.loaded.get(slug).and_then(|o| o.as_ref()) else {
            self.status = format!("{family} is not here yet");
            return;
        };
        let key: String = slug.chars().filter(|c| *c != '-').collect();
        let dest = PathBuf::from(std::env::var("HOME").unwrap_or_default())
            .join(".local/share/fonts")
            .join(&key);
        if let Err(e) = std::fs::create_dir_all(&dest) {
            self.status = format!("could not create {}: {e}", dest.display());
            return;
        }
        for p in &l.paths {
            let Some(name) = p.file_name() else { continue };
            if let Err(e) = std::fs::copy(p, dest.join(name)) {
                self.status = format!("copy failed: {e}");
                return;
            }
        }
        let _ = std::process::Command::new("fc-cache")
            .arg("-f")
            .arg(&dest)
            .output();
        self.status = format!(
            "installed {family} → {} · not in deps.conf, so this machine only",
            dest.display()
        );
    }
}

impl Screen for BrowseScreen {
    fn title(&self) -> String {
        format!(
            "  browse — Google monospace via Bunny · judging for {}",
            self.lane
        )
    }

    fn rows(&mut self) -> Vec<Row> {
        // Offline with no cached catalogue. Handled here rather than by
        // refusing to open, so the screen can say WHY it is empty — a list
        // with no rows and no explanation is the worse answer.
        if self.items.is_empty() {
            return vec![Row::leaf("catalogue unavailable").badged("offline?", 210)];
        }
        let items = self.items.clone();
        items
            .iter()
            .map(|(slug, name)| {
                let row = Row::leaf(name.clone());
                match self.fetcher.get(slug) {
                    Some(Fetch::Ready(_)) => match self.load(slug) {
                        Some(l) if l.metrics.critical == fonts::CRITICAL.len() => {
                            row.badged("claude ok", 114)
                        }
                        Some(_) => row.badged("ready", 244),
                        None => row.badged("unreadable", 210),
                    },
                    Some(Fetch::Pending) => row.badged("\u{2026}", 244),
                    Some(Fetch::Failed(_)) => row.badged("failed", 210),
                    None => row,
                }
            })
            .collect()
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
            "j/k move · enter install · p {mode} · +/- size {:.0} · gg/G",
            self.size
        )
    }

    /// Prefetch is driven from here rather than from `pane`, because a row you
    /// skim past without stopping on still has to be fetched — that is what
    /// makes the next keypress instant instead of the current one slow.
    fn focus(&mut self, sel: usize) {
        for i in fetch::window(self.items.len(), sel, PREFETCH_RADIUS) {
            if let Some((slug, _)) = self.items.get(i) {
                self.fetcher.request(slug);
            }
        }
    }

    fn tick(&mut self) -> Tick {
        let epoch = *self.fetcher.epoch.lock().unwrap();
        if epoch != self.epoch_seen {
            self.epoch_seen = epoch;
            return Tick::Changed;
        }
        if self.fetcher.pending() {
            Tick::Busy
        } else {
            Tick::Idle
        }
    }

    fn pane(&mut self, sel: usize, cols: u16, rows: u16) -> Pane {
        let mut pane = Pane::default();
        let Some((slug, family)) = self.items.get(sel).cloned() else {
            pane.lines
                .push("\x1b[1mcatalogue unavailable\x1b[0m".into());
            pane.lines.push(String::new());
            pane.lines
                .push("  Could not reach fonts.bunny.net, and nothing is cached.".into());
            pane.lines.push(String::new());
            pane.lines.push(
                "  \x1b[38;5;244mThe catalogue is one JSON, cached for a week under\x1b[0m".into(),
            );
            pane.lines
                .push("  \x1b[38;5;244m~/.cache/dotfiles-fonts. q goes back.\x1b[0m".into());
            return pane;
        };

        match self.fetcher.get(&slug) {
            Some(Fetch::Ready(_)) => {}
            Some(Fetch::Failed(e)) => {
                pane.lines.push(format!("\x1b[1m{family}\x1b[0m"));
                pane.lines.push(String::new());
                pane.lines.push(format!("  could not fetch: {e}"));
                return pane;
            }
            _ => {
                pane.lines.push(format!("\x1b[1m{family}\x1b[0m"));
                pane.lines.push(String::new());
                pane.lines
                    .push("  \x1b[38;5;244mfetching from google/fonts…\x1b[0m".into());
                pane.lines.push(String::new());
                pane.lines.push(
                    "  \x1b[38;5;244mNothing is installed by this — the file lands in\x1b[0m"
                        .into(),
                );
                pane.lines.push(
                    "  \x1b[38;5;244m~/.cache/dotfiles-fonts and is judged there.\x1b[0m".into(),
                );
                return pane;
            }
        }

        let lane = self.lane.clone();
        let size = self.size;
        let art_rows = rows.saturating_sub(14) as usize;
        if self.preview == Preview::Specimen && art_rows >= 6 && reticle::image::supported() {
            let lines = specimen(&lane);
            let row_h = (size * 1.55) as usize;
            // Exactly the pixels these cells will get, so the image is drawn
            // 1:1 rather than resampled. See the note at the picker's copy.
            let (cw, ch) = reticle::term_info().cell;
            let canvas_w = cols as usize * cw as usize;
            let canvas_h = art_rows * ch as usize;
            let mut c = render::Canvas::new(canvas_w, canvas_h, crate::theme::bg());
            let drew = if let Some(l) = self.load(&slug) {
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

        let Some(l) = self.load(&slug) else {
            pane.lines.push(format!("{family} — unreadable"));
            return pane;
        };
        let m = &l.metrics;
        let d = |a: char, b: char| render::distinct(&l.font, a, b, 64.0) * 100.0;
        pane.lines.push(format!("\x1b[1m{family}\x1b[0m"));
        pane.lines.push(String::new());
        pane.lines.push(format!(
            "  space   {:.3}em wide · {:.3}em line · x-height {:.3}",
            m.advance, m.line, m.x_height
        ));
        pane.lines.push(format!(
            "  glyphs  0/O {:.0}%  1/l {:.0}%  l/I {:.0}%",
            d('0', 'O'),
            d('1', 'l'),
            d('l', 'I')
        ));
        pane.lines
            .push(format!("  cuts    {}", l.styles.join(", ")));
        pane.lines.push(format!(
            "  claude  critical {}/2  frequent {}/2  incidental {}/5",
            m.critical, m.frequent, m.incidental
        ));
        pane.lines.push(format!(
            "  extras  ligatures {} · {} glyphs · box {}/128",
            if m.ligatures.is_empty() {
                "none".into()
            } else {
                m.ligatures.join(", ")
            },
            m.glyphs,
            m.box_drawing
        ));
        pane.lines.push(String::new());
        // Not Nerd-patched, none of them, and it is the one thing the numbers
        // above do not shout: nerd icons will fall back oversized.
        pane.lines
            .push("  \x1b[38;5;221mno nerd glyphs — icons fall back oversized\x1b[0m".into());
        pane.lines
            .push("  \x1b[38;5;244menter installs to ~/.local/share/fonts\x1b[0m".into());
        pane
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        let Some((slug, family)) = self.items.get(sel).cloned() else {
            return Flow::Continue;
        };
        match action {
            Action::Activate => {
                self.install(&slug, &family);
                Flow::Dirty
            }
            Action::Key('p') => {
                self.preview = match self.preview {
                    Preview::Sheet => Preview::Specimen,
                    Preview::Specimen => Preview::Sheet,
                };
                Flow::Dirty
            }
            Action::Key('+') | Action::Key('=') => {
                self.size = (self.size + 2.0).min(48.0);
                Flow::Dirty
            }
            Action::Key('-') => {
                self.size = (self.size - 2.0).max(10.0);
                Flow::Dirty
            }
            _ => Flow::Continue,
        }
    }
}
