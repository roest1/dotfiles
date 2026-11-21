//! The machine's own colours and the machine's own prompt.
//!
//! A specimen is only worth looking at if it shows what you will actually see.
//! A pangram in invented colours tells you about the letterforms; the prompt
//! you look at fifty times a day, in the palette your terminal really resolved,
//! tells you whether you want to live in this font.
//!
//! Colours come from `reticle::term_info()`, which asked the terminal rather
//! than parsing `wezterm/wezterm.lua`. The prompt is `~/.bash_prompt` as bash
//! itself expands it — not a copy of its contents, and not a parse of its PS1
//! line — so changing PS1 or its colours changes the specimen with nothing
//! here aware that it did.

use reticle::term_info;

pub type Line = Vec<(String, [u8; 3])>;

pub fn fg() -> [u8; 3] {
    term_info().fg
}

pub fn bg() -> [u8; 3] {
    term_info().bg
}

/// Dim text — a comment, a tool result. Mixed toward the background rather
/// than hardcoded, so it stays dim on a light theme too.
pub fn dim() -> [u8; 3] {
    let (f, b) = (fg(), bg());
    let mut out = [0u8; 3];
    for i in 0..3 {
        out[i] = ((f[i] as u16 * 55 + b[i] as u16 * 45) / 100) as u8;
    }
    out
}

/// A 256-colour index, resolved by the terminal where it answered and
/// COMPUTED where it did not.
///
/// Indices 16-255 are not a matter of opinion: 16-231 are a 6x6x6 cube on the
/// levels {0,95,135,175,215,255} and 232-255 are an even grey ramp, both fixed
/// by xterm and followed by everything since. Only 0-15 are the terminal's to
/// theme, so those are the only ones that genuinely need an answer.
///
/// Doing this properly is what keeps the OSC 4 query an IMPROVEMENT rather
/// than a requirement. Falling back to the foreground colour instead made the
/// prompt specimen monochrome on any terminal that stayed quiet — every run
/// the same colour, which a test caught only because it asserted they differed.
pub fn xterm256(i: u8) -> [u8; 3] {
    const LEVELS: [u8; 6] = [0, 95, 135, 175, 215, 255];
    match i {
        0..=15 => {
            // No local truth for these; ask, or take a reasonable ANSI guess.
            const BASE: [[u8; 3]; 16] = [
                [0, 0, 0],
                [128, 0, 0],
                [0, 128, 0],
                [128, 128, 0],
                [0, 0, 128],
                [128, 0, 128],
                [0, 128, 128],
                [192, 192, 192],
                [128, 128, 128],
                [255, 0, 0],
                [0, 255, 0],
                [255, 255, 0],
                [0, 0, 255],
                [255, 0, 255],
                [0, 255, 255],
                [255, 255, 255],
            ];
            BASE[i as usize]
        }
        16..=231 => {
            let n = i - 16;
            [
                LEVELS[(n / 36) as usize],
                LEVELS[((n % 36) / 6) as usize],
                LEVELS[(n % 6) as usize],
            ]
        }
        _ => {
            let v = 8 + 10 * (i as u16 - 232);
            [v as u8, v as u8, v as u8]
        }
    }
}

pub fn idx(i: u8, _fallback: [u8; 3]) -> [u8; 3] {
    term_info().color(i, xterm256(i))
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

/// Render this machine's PS1 as coloured runs.
///
/// Bash expands it, not this file. PS1 takes its colours from variables
/// (`PS1_COLOR_*`, see roest1/PS1), so the text of the `PS1='…'` line no
/// longer says what colour anything is; only sourcing the prompt does. A
/// non-interactive bash sources `~/.bash_local` first, as bashrc does, so the
/// specimen shows this machine's overrides and not just the defaults.
///
/// Runtime-only segments are set by hand before `${PS1@P}`: conda to nothing,
/// and the git slot to a representative branch in the branch colour, so the
/// specimen shows the width a real prompt has. Anything going wrong -- no
/// file, no bash, empty output -- falls back to a fixed two-run prompt.
pub fn prompt_lines() -> Vec<Line> {
    let path = format!("{}/.bash_prompt", home());
    let local = format!("{}/.bash_local", home());
    render_prompt(&path, Some(&local)).unwrap_or_else(fallback_prompt)
}

const EXPAND: &str = r#"
[ -n "$2" ] && [ -f "$2" ] && . "$2" >/dev/null 2>&1
. "$1" >/dev/null 2>&1 || exit 1
__PS1_CONDA=""
__PS1_GIT=" ${__NP_ON}${__C_BRANCH}${__NP_OFF}main${__NP_ON}${__C_OFF}${__NP_OFF}"
cd "$HOME/dotfiles" 2>/dev/null || cd "$HOME"
printf '%s' "${PS1@P}"
"#;

fn render_prompt(prompt: &str, local: Option<&str>) -> Option<Vec<Line>> {
    if !std::path::Path::new(prompt).is_file() {
        return None;
    }
    let out = std::process::Command::new("bash")
        .args([
            "--norc",
            "--noprofile",
            "-c",
            EXPAND,
            "bash",
            prompt,
            local.unwrap_or(""),
        ])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let lines = parse_rendered(&String::from_utf8_lossy(&out.stdout));
    (!lines.is_empty()).then_some(lines)
}

/// Split a prompt bash has already expanded into coloured runs: `\x01`/`\x02`
/// (readline's zero-width markers) dropped, `\n` starting a line, and SGR
/// `0`, `38;5;N` and `38;2;R;G;B` changing colour. Bold and anything else in an
/// SGR are ignored -- the specimen shows colour, not weight.
fn parse_rendered(text: &str) -> Vec<Line> {
    let mut lines: Vec<Line> = vec![Vec::new()];
    let mut color = fg();
    let mut pending = String::new();
    let mut chars = text.chars().peekable();

    macro_rules! flush {
        () => {
            if !pending.is_empty() {
                lines.last_mut().unwrap().push((pending.clone(), color));
                pending.clear();
            }
        };
    }

    while let Some(c) = chars.next() {
        match c {
            '\x01' | '\x02' => {}
            '\n' => {
                flush!();
                lines.push(Vec::new());
            }
            '\x1b' if chars.peek() == Some(&'[') => {
                chars.next();
                let mut seq = String::new();
                for d in chars.by_ref() {
                    if d.is_ascii_alphabetic() {
                        if d != 'm' {
                            seq.clear();
                        }
                        break;
                    }
                    seq.push(d);
                }
                if seq.is_empty() {
                    continue;
                }
                flush!();
                color = sgr_color(&seq).unwrap_or_else(fg);
            }
            _ => pending.push(c),
        }
    }
    flush!();
    lines.retain(|l| !l.is_empty());
    lines
}

/// The foreground an SGR parameter list sets, if it sets one.
fn sgr_color(seq: &str) -> Option<[u8; 3]> {
    let p: Vec<u16> = seq.split(';').filter_map(|n| n.parse().ok()).collect();
    let at = p.iter().position(|&n| n == 38)?;
    match p.get(at + 1)? {
        5 => p.get(at + 2).map(|&n| idx(n as u8, fg())),
        2 => match (p.get(at + 2), p.get(at + 3), p.get(at + 4)) {
            (Some(&r), Some(&g), Some(&b)) => Some([r as u8, g as u8, b as u8]),
            _ => None,
        },
        _ => None,
    }
}

/// No ~/.bash_prompt — not linked, or a machine that never installed the shell.
fn fallback_prompt() -> Vec<Line> {
    vec![vec![
        ("you@host".into(), idx(75, [0x5f, 0xaf, 0xff])),
        (" ~/dotfiles".into(), idx(110, [0x87, 0xaf, 0xd7])),
    ]]
}

/// The highlighted row in the contact sheet. Nudged from the background
/// toward the foreground rather than hardcoded, so it reads as "lifted" in
/// whatever palette the terminal is actually using.
pub fn selection() -> [u8; 3] {
    let (f, b) = (fg(), bg());
    let mut out = [0u8; 3];
    for i in 0..3 {
        out[i] = ((f[i] as u16 * 18 + b[i] as u16 * 82) / 100) as u8;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{parse_rendered, render_prompt, xterm256};

    /// The prompt this repo pins: the ps1 submodule, two levels up.
    fn shipped() -> String {
        let p = format!("{}/../../ps1/ps1.bash", env!("CARGO_MANIFEST_DIR"));
        assert!(
            std::path::Path::new(&p).is_file(),
            "{p} is missing -- is the ps1 submodule checked out?"
        );
        p
    }

    fn flat(lines: &[super::Line]) -> String {
        lines
            .iter()
            .map(|l| l.iter().map(|(t, _)| t.as_str()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The real file, expanded by real bash: two lines, the zero-width markers
    /// gone, the git slot filled, and user@host in PS1's default host colour.
    /// This replaced a CI step pinning the PS1 string, which could not survive
    /// the colours moving into variables.
    #[test]
    fn renders_the_shipped_prompt() {
        let lines = render_prompt(&shipped(), None).expect("bash rendered nothing");
        let out = flat(&lines);
        assert_eq!(lines.len(), 2, "the prompt is two lines: {out:?}");
        assert!(out.contains("main"), "git slot missing: {out:?}");
        assert!(out.ends_with("$ "), "got {out:?}");
        assert!(
            !out.contains('\x01') && !out.contains('\x1b'),
            "escapes leaked: {out:?}"
        );
        assert_eq!(
            lines[0][0].1,
            xterm256(75),
            "user@host is not PS1's default colour"
        );
        assert!(lines[0][0].1 != lines[0][1].1, "runs share a colour");
    }

    #[test]
    fn parses_256_truecolor_reset_and_markers() {
        let lines = parse_rendered("\x01\x1b[38;5;75m\x02a\x01\x1b[0m\x02 \x1b[1;38;2;1;2;3mb\nc");
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0][0], ("a".into(), xterm256(75)));
        assert_eq!(lines[0][2], ("b".into(), [1, 2, 3]));
        assert_eq!(flat(&lines), "a b\nc");
    }

    #[test]
    fn a_missing_prompt_file_is_none() {
        assert!(render_prompt("/nonexistent/ps1.bash", None).is_none());
    }
}

#[cfg(test)]
mod palette_tests {
    use super::xterm256;

    /// The two this repo's PS1 actually uses. Computed, not asked for — which
    /// is the point: a quiet terminal still gets the right colours.
    #[test]
    fn the_prompts_own_colours_resolve() {
        assert_eq!(xterm256(75), [95, 175, 255]);
        assert_eq!(xterm256(110), [135, 175, 215]);
    }

    #[test]
    fn cube_and_ramp_endpoints_are_right() {
        assert_eq!(xterm256(16), [0, 0, 0]);
        assert_eq!(xterm256(231), [255, 255, 255]);
        assert_eq!(xterm256(232), [8, 8, 8]);
        assert_eq!(xterm256(255), [238, 238, 238]);
    }
}
