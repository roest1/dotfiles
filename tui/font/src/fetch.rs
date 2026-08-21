//! Fetching fonts you have not installed, ahead of when you look at them.
//!
//! ─── Why there is a cache at all ─────────────────────────────────────────
//!
//! You cannot rasterise a font you do not have. There is no metadata that
//! substitutes for outlines, so "preview without downloading" is not a thing
//! that exists — but "preview without INSTALLING" is, and it is what you
//! actually want. Candidates land in ~/.cache and are judged from there;
//! nothing touches ~/.local/share/fonts until you say so.
//!
//! ─── Why it prefetches neighbours ────────────────────────────────────────
//!
//! Fetching only what the cursor is on makes every j a stall. Fetching the
//! rows AROUND it means the ones you are about to reach are already there:
//! by the time you have read one specimen, its neighbours have arrived. The
//! order is nearest-first (i, i+1, i-1, i+2, …) because the next keystroke is
//! far more likely to be one row away than five.
//!
//! ─── Why curl and not an HTTP crate ──────────────────────────────────────
//!
//! curl is already a dependency of this repo and of the machine. Pulling in
//! reqwest would add a TLS stack and most of a runtime to a binary whose whole
//! appeal is that it starts in a millisecond.
//!
//! ─── Two sources, and the split is load-bearing ──────────────────────────
//!
//! Bunny (fonts.bunny.net) is the CATALOGUE: one JSON, no API key, with the
//! category and weights and styles to filter on. google/fonts on GitHub is the
//! FONT, because Bunny only ships woff2 subset for the web — its Fira Code
//! "latin" file has 226 glyphs and NO BOX DRAWING, against 1551 with box
//! drawing from google/fonts. Measured, not assumed.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Clone, Debug)]
pub enum Fetch {
    Pending,
    Ready(Vec<PathBuf>),
    Failed(String),
}

type Shared = Arc<Mutex<HashMap<String, Fetch>>>;

pub struct Fetcher {
    tx: Sender<String>,
    state: Shared,
    /// Bumped by a worker whenever it finishes, so the UI can tell "something
    /// landed" from "still waiting" without diffing the whole map.
    pub epoch: Arc<Mutex<u64>>,
}

pub fn cache_dir() -> PathBuf {
    let base = std::env::var("XDG_CACHE_HOME")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache"));
    base.join("dotfiles-fonts")
}

fn curl(url: &str) -> Option<Vec<u8>> {
    let out = Command::new("curl")
        .args(["-fsSL", "--max-time", "60", url])
        .output()
        .ok()?;
    out.status.success().then_some(out.stdout)
}

/// Bunny's slug maps to a google/fonts directory by deleting hyphens
/// (fira-code -> firacode). Checked against the repo's full tree: 50 of the 51
/// monospace families resolve, and the one that does not is material-symbols,
/// an icon set rather than a text font.
fn google_ttf_urls(slug: &str) -> Option<Vec<String>> {
    let key: String = slug.chars().filter(|c| *c != '-').collect();
    for licence in ["ofl", "apache", "ufl"] {
        let api = format!("https://api.github.com/repos/google/fonts/contents/{licence}/{key}");
        let body = Command::new("curl")
            .args([
                "-fsSL",
                "--max-time",
                "30",
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                "User-Agent: dotfiles-font-tui",
                &api,
            ])
            .output()
            .ok()?;
        if !body.status.success() {
            continue;
        }
        let Ok(json) = serde_json::from_slice::<serde_json::Value>(&body.stdout) else {
            continue;
        };
        let Some(items) = json.as_array() else {
            continue;
        };
        let urls: Vec<String> = items
            .iter()
            .filter(|i| {
                i.get("name")
                    .and_then(|n| n.as_str())
                    .is_some_and(|n| n.ends_with(".ttf"))
            })
            .filter_map(|i| i.get("download_url")?.as_str().map(str::to_string))
            .collect();
        if !urls.is_empty() {
            return Some(urls);
        }
    }
    None
}

/// What is already on disk for this family, if anything.
///
/// Checked SYNCHRONOUSLY by `request`, not just by the worker. Leaving it to
/// the worker meant a family cached from a previous session still went through
/// Pending -> queue -> thread -> Ready, so moving the cursor across fonts you
/// had already fetched still flashed "fetching…". A read_dir costs microseconds
/// and removes the flash entirely.
fn cached_paths(slug: &str) -> Option<Vec<PathBuf>> {
    let dir = cache_dir().join("browse").join(slug);
    let found: Vec<PathBuf> = std::fs::read_dir(&dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "ttf"))
        .collect();
    (!found.is_empty()).then_some(found)
}

fn fetch_one(slug: &str) -> Result<Vec<PathBuf>, String> {
    let dir = cache_dir().join("browse").join(slug);
    if let Some(found) = cached_paths(slug) {
        return Ok(found);
    }

    let urls = google_ttf_urls(slug).ok_or_else(|| format!("no .ttf for {slug}"))?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for url in urls {
        let name = url.rsplit('/').next().unwrap_or("font.ttf");
        let bytes = curl(&url).ok_or_else(|| format!("download failed: {name}"))?;
        let path = dir.join(name);
        std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
        out.push(path);
    }
    Ok(out)
}

impl Fetcher {
    /// Three workers: enough that a stalled request does not block the queue,
    /// few enough to stay polite to two public APIs.
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel::<String>();
        let state: Shared = Arc::new(Mutex::new(HashMap::new()));
        let epoch = Arc::new(Mutex::new(0u64));
        let rx = Arc::new(Mutex::new(rx));
        for _ in 0..3 {
            let rx = Arc::clone(&rx);
            let state = Arc::clone(&state);
            let epoch = Arc::clone(&epoch);
            thread::spawn(move || loop {
                let slug = {
                    let guard = rx.lock().unwrap();
                    match guard.recv() {
                        Ok(s) => s,
                        Err(_) => return,
                    }
                };
                let result = match fetch_one(&slug) {
                    Ok(paths) => Fetch::Ready(paths),
                    Err(e) => Fetch::Failed(e),
                };
                state.lock().unwrap().insert(slug, result);
                *epoch.lock().unwrap() += 1;
            });
        }
        Self { tx, state, epoch }
    }

    pub fn get(&self, slug: &str) -> Option<Fetch> {
        self.state.lock().unwrap().get(slug).cloned()
    }

    /// Enqueue if this is the first time we have been asked. Idempotent, so a
    /// caller can request the same window on every cursor move without
    /// re-downloading anything.
    pub fn request(&self, slug: &str) {
        let mut guard = self.state.lock().unwrap();
        if guard.contains_key(slug) {
            return;
        }
        // Already downloaded in an earlier session: resolve it here rather than
        // queueing, so a warm cache never shows a spinner it does not need.
        if let Some(found) = cached_paths(slug) {
            guard.insert(slug.to_string(), Fetch::Ready(found));
            return;
        }
        guard.insert(slug.to_string(), Fetch::Pending);
        drop(guard);
        let _ = self.tx.send(slug.to_string());
    }

    pub fn pending(&self) -> bool {
        self.state
            .lock()
            .unwrap()
            .values()
            .any(|f| matches!(f, Fetch::Pending))
    }
}

/// The catalogue, cached for a week. Returns (slug, familyName) for every
/// monospace family, minus material-symbols — categorised monospace, but an
/// icon set, and the one slug that does not resolve in google/fonts.
pub fn catalogue() -> Vec<(String, String)> {
    let path = cache_dir().join("bunny-list.json");
    let fresh = std::fs::metadata(&path)
        .and_then(|m| m.modified())
        .map(|t| {
            t.elapsed()
                .map(|e| e.as_secs() < 7 * 24 * 3600)
                .unwrap_or(false)
        })
        .unwrap_or(false);

    let body = if fresh {
        std::fs::read(&path).ok()
    } else {
        // tmp-then-rename here, unlike wezterm's fonts.conf: nothing watches
        // this file, so there is no inode to preserve, and a half-downloaded
        // catalogue replacing a good one would be the worse failure.
        curl("https://fonts.bunny.net/list")
            .inspect(|b| {
                if let Some(dir) = path.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                let tmp = path.with_extension("json.tmp");
                if std::fs::write(&tmp, b).is_ok() {
                    let _ = std::fs::rename(&tmp, &path);
                }
            })
            // Offline with a stale catalogue beats offline with nothing.
            .or_else(|| std::fs::read(&path).ok())
    };

    let Some(body) = body else { return Vec::new() };
    let Ok(json) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return Vec::new();
    };
    let Some(map) = json.as_object() else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = map
        .iter()
        .filter(|(slug, v)| {
            slug.as_str() != "material-symbols"
                && v.get("category").and_then(|c| c.as_str()) == Some("monospace")
        })
        .map(|(slug, v)| {
            let name = v
                .get("familyName")
                .and_then(|n| n.as_str())
                .unwrap_or(slug)
                .to_string();
            (slug.clone(), name)
        })
        .collect();
    out.sort_by(|a, b| a.1.cmp(&b.1));
    out
}

/// Nearest-first, so the row you are about to reach is fetched before the row
/// five away. `radius` is how far either side to reach.
pub fn window(len: usize, sel: usize, radius: usize) -> Vec<usize> {
    let mut out = vec![sel.min(len.saturating_sub(1))];
    for d in 1..=radius {
        if sel + d < len {
            out.push(sel + d);
        }
        if let Some(i) = sel.checked_sub(d) {
            out.push(i);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::window;

    #[test]
    fn prefetch_order_is_nearest_first() {
        assert_eq!(window(20, 10, 3), vec![10, 11, 9, 12, 8, 13, 7]);
    }

    /// The ends are where an off-by-one shows up as a panic rather than a
    /// missing preview.
    #[test]
    fn edges_do_not_run_off_the_list() {
        assert_eq!(window(5, 0, 3), vec![0, 1, 2, 3]);
        assert_eq!(window(5, 4, 3), vec![4, 3, 2, 1]);
        assert_eq!(window(1, 0, 3), vec![0]);
        assert_eq!(window(0, 0, 2), vec![0]);
    }
}
