//! Asking the terminal what it actually looks like.
//!
//! ─── Why ask rather than read the config ─────────────────────────────────
//!
//! The colours live in `wezterm/wezterm.lua` and the prompt's in
//! `bash/bash_theme`, and both are Lua and shell respectively — parsing either
//! from here would be a second implementation of somebody else's format, wrong
//! the first time either file is rearranged. The terminal already resolved all
//! of it. OSC 10/11/4 ask it what it resolved TO, so a theme change is picked
//! up with no code aware that a theme exists.
//!
//! ─── Why the cell size matters more than it sounds ───────────────────────
//!
//! An inline image is scaled by the terminal to fit the cells it is given. A
//! canvas that is not already the right number of PIXELS therefore gets
//! resampled, and resampled text is the blur you see. Knowing the cell size
//! turns "some canvas, scaled" into "exactly this many pixels, drawn 1:1".
//!
//! ─── Why this cannot hang ────────────────────────────────────────────────
//!
//! Every one of these is a question a terminal is free to ignore, and a read
//! that blocks forever on a terminal that ignored it is a program that never
//! starts. One deadline covers the whole batch; whatever has not answered by
//! then keeps its default, which is the value this repo's config sets anyway.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_millis(120);

#[derive(Debug, Clone)]
pub struct TermInfo {
    /// Cell size in pixels. The fallback is a typical 11pt cell — wrong by a
    /// little on some machines, which costs sharpness and nothing else.
    pub cell: (u32, u32),
    pub fg: [u8; 3],
    pub bg: [u8; 3],
    /// Answers to the 256-colour indices that were asked for.
    pub palette: HashMap<u8, [u8; 3]>,
    /// False when nothing answered — the caller can then avoid promising
    /// pixel-exact rendering it cannot deliver.
    pub measured: bool,
}

impl Default for TermInfo {
    fn default() -> Self {
        Self {
            cell: (10, 22),
            // rose-pine moon, which is what wezterm.lua sets. A fallback that
            // matches the config is a fallback nobody notices.
            fg: [0xe0, 0xde, 0xf4],
            bg: [0x23, 0x21, 0x36],
            palette: HashMap::new(),
            measured: false,
        }
    }
}

impl TermInfo {
    pub fn color(&self, index: u8, fallback: [u8; 3]) -> [u8; 3] {
        self.palette.get(&index).copied().unwrap_or(fallback)
    }
}

/// Parse `rgb:RRRR/GGGG/BBBB` (and the 2- and 1-digit forms terminals also use).
fn parse_rgb(s: &str) -> Option<[u8; 3]> {
    let body = s.strip_prefix("rgb:")?;
    let mut out = [0u8; 3];
    for (i, part) in body.split('/').take(3).enumerate() {
        let hex = part.trim_end_matches(['\x07', '\x1b', '\\']);
        if hex.is_empty() {
            return None;
        }
        let v = u32::from_str_radix(hex, 16).ok()?;
        // Terminals answer in 16-bit-per-channel by convention; scale whatever
        // width they actually used down to 8.
        out[i] = match hex.len() {
            1 => (v * 17) as u8,
            2 => v as u8,
            3 => (v >> 4) as u8,
            _ => (v >> 8) as u8,
        };
    }
    Some(out)
}

/// Must be called with the terminal already in raw mode, so the replies are
/// readable rather than being line-buffered into the void.
pub fn probe(indices: &[u8]) -> TermInfo {
    let mut info = TermInfo::default();

    let mut query = String::from("\x1b[16t\x1b]11;?\x07\x1b]10;?\x07");
    for i in indices {
        query.push_str(&format!("\x1b]4;{i};?\x07"));
    }
    // A primary-device-attributes request goes LAST and is the finish line:
    // every terminal answers it, and it cannot overtake the replies queued
    // before it. Without a known-final reply the only options are waiting the
    // whole deadline every launch, or guessing how many answers to expect.
    query.push_str("\x1b[c");

    let mut out = std::io::stdout();
    if out.write_all(query.as_bytes()).is_err() || out.flush().is_err() {
        return info;
    }

    let stdin = std::io::stdin();
    let fd = stdin.as_raw_fd();
    let start = Instant::now();
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];

    while start.elapsed() < DEADLINE {
        let mut fds = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let left = DEADLINE.saturating_sub(start.elapsed()).as_millis() as i32;
        // SAFETY: one initialised pollfd, count 1, and a non-negative timeout.
        let ready = unsafe { libc::poll(&mut fds, 1, left.max(1)) };
        if ready <= 0 {
            break;
        }
        match stdin.lock().read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
        // DA1 arrived: everything queued ahead of it is already in `buf`.
        if buf.windows(2).any(|w| w == b"?6" || w == b"?1") && buf.contains(&b'c') {
            break;
        }
    }

    let text = String::from_utf8_lossy(&buf);

    // CSI 6 ; height ; width t
    if let Some(rest) = text.split("\x1b[6;").nth(1) {
        let nums: Vec<&str> = rest.split(['t', ';']).collect();
        if nums.len() >= 2 {
            if let (Ok(h), Ok(w)) = (nums[0].parse::<u32>(), nums[1].parse::<u32>()) {
                if w > 0 && h > 0 && w < 100 && h < 200 {
                    info.cell = (w, h);
                    info.measured = true;
                }
            }
        }
    }

    for (marker, slot) in [("\x1b]11;", 0usize), ("\x1b]10;", 1usize)] {
        if let Some(rest) = text.split(marker).nth(1) {
            if let Some(rgb) = parse_rgb(rest.split(['\x07', '\x1b']).next().unwrap_or("")) {
                if slot == 0 {
                    info.bg = rgb;
                } else {
                    info.fg = rgb;
                }
                info.measured = true;
            }
        }
    }

    for part in text.split("\x1b]4;").skip(1) {
        let mut it = part.splitn(2, ';');
        let Some(idx) = it.next().and_then(|s| s.trim().parse::<u8>().ok()) else {
            continue;
        };
        let Some(rest) = it.next() else { continue };
        if let Some(rgb) = parse_rgb(rest.split(['\x07', '\x1b']).next().unwrap_or("")) {
            info.palette.insert(idx, rgb);
        }
    }

    info
}

#[cfg(test)]
mod tests {
    use super::parse_rgb;

    /// Terminals answer in whatever channel width they like; all of them mean
    /// the same colour.
    #[test]
    fn rgb_widths_all_scale_to_eight_bits() {
        assert_eq!(parse_rgb("rgb:e0e0/dede/f4f4"), Some([0xe0, 0xde, 0xf4]));
        assert_eq!(parse_rgb("rgb:e0/de/f4"), Some([0xe0, 0xde, 0xf4]));
        assert_eq!(parse_rgb("rgb:f/f/f"), Some([0xff, 0xff, 0xff]));
    }

    #[test]
    fn a_terminator_riding_along_is_not_part_of_the_number() {
        assert_eq!(
            parse_rgb("rgb:2323/2121/3636\x07"),
            Some([0x23, 0x21, 0x36])
        );
    }

    #[test]
    fn nonsense_is_rejected_rather_than_guessed() {
        assert_eq!(parse_rgb("#e0def4"), None);
        assert_eq!(parse_rgb("rgb:"), None);
    }
}
