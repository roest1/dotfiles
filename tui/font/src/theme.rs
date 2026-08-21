//! The machine's own colours and the machine's own prompt.
//!
//! A specimen is only worth looking at if it shows what you will actually see.
//! A pangram in invented colours tells you about the letterforms; the prompt
//! you look at fifty times a day, in the palette your terminal really resolved,
//! tells you whether you want to live in this font.
//!
//! Colours come from `reticle::term_info()`, which asked the terminal rather
//! than parsing `wezterm/wezterm.lua`. The prompt comes from `~/.bash_theme` —
//! the linked file, not a copy of its contents — so changing PS1 changes the
//! specimen with nothing here aware that it did.

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
/// Handles the subset a prompt actually uses: `\[`/`\]` (zero-width markers,
/// dropped), SGR 38;5;N and 0, and the `\u \h \w \n \$` escapes. `${...}`
/// segments are dropped — they are filled by PROMPT_COMMAND at runtime and
/// there is nothing honest to put there — except the git slot, which gets a
/// representative branch so the specimen shows the width a real prompt has.
pub fn prompt_lines() -> Vec<Line> {
    let path = format!("{}/.bash_theme", home());
    let Ok(text) = std::fs::read_to_string(&path) else {
        return fallback_prompt();
    };
    let Some(raw) = text
        .lines()
        .find(|l| l.starts_with("PS1='"))
        .and_then(|l| l.strip_prefix("PS1='"))
        .and_then(|l| l.strip_suffix('\''))
    else {
        return fallback_prompt();
    };

    let user = std::env::var("USER").unwrap_or_else(|_| "you".into());
    let host = std::fs::read_to_string("/etc/hostname")
        .map(|h| h.trim().to_string())
        .unwrap_or_else(|_| "host".into());

    let lines = parse_ps1(raw, &user, &host);
    if lines.is_empty() {
        return fallback_prompt();
    }
    lines
}

/// Split out from `prompt_lines` so it can be tested against the PS1 this repo
/// actually ships, without a filesystem or a terminal in the way.
fn parse_ps1(raw: &str, user: &str, host: &str) -> Vec<Line> {
    let mut lines: Vec<Line> = vec![Vec::new()];
    let mut color = fg();
    let mut chars = raw.chars().peekable();
    let mut pending = String::new();

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
            '\\' => match chars.next() {
                Some('[') | Some(']') => {}
                Some('u') => pending.push_str(user),
                Some('h') => pending.push_str(host),
                Some('w') => pending.push_str("~/dotfiles"),
                Some('$') => pending.push('$'),
                Some('n') => {
                    flush!();
                    lines.push(Vec::new());
                }
                Some('0') => {
                    // \033[...m — an SGR run.
                    let mut seq = String::new();
                    for d in chars.by_ref() {
                        if d == 'm' {
                            break;
                        }
                        seq.push(d);
                    }
                    flush!();
                    color = match seq.rsplit(';').next().and_then(|n| n.parse::<u8>().ok()) {
                        Some(n) if seq.contains("38;5;") => idx(n, fg()),
                        _ => fg(),
                    };
                }
                Some(other) => pending.push(other),
                None => {}
            },
            '$' if chars.peek() == Some(&'{') => {
                // Skip to the closing brace; substitute only the git slot.
                let mut name = String::new();
                chars.next();
                for d in chars.by_ref() {
                    if d == '}' {
                        break;
                    }
                    name.push(d);
                }
                if name.contains("GIT") {
                    flush!();
                    lines
                        .last_mut()
                        .unwrap()
                        .push((" \u{e0a0} main".into(), idx(108, [0x9c, 0xcf, 0xd8])));
                }
            }
            _ => pending.push(c),
        }
    }
    flush!();
    lines.retain(|l| !l.is_empty());
    lines
}

/// No ~/.bash_theme — not linked, or a machine that never installed the shell.
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
    use super::parse_ps1;

    /// The PS1 this repo actually ships, verbatim from bash/bash_theme.
    const REAL: &str = "${__PS1_CONDA}\\[\\033[38;5;75m\\]\\u@\\h\\[\\033[0m\\] \\[\\033[38;5;110m\\]\\w\\[\\033[0m\\]${__PS1_GIT}\\n\\$ ";

    fn flat(raw: &str) -> String {
        parse_ps1(raw, "roest", "fedora")
            .iter()
            .map(|l| l.iter().map(|(t, _)| t.as_str()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// \\u \\h \\w are substituted, the zero-width \\[ \\] markers vanish, and
    /// \\n really starts a second line — the prompt is two lines and a
    /// specimen that drew it as one would be lying about its shape.
    #[test]
    fn renders_this_machines_prompt() {
        let out = flat(REAL);
        assert!(out.starts_with("roest@fedora ~/dotfiles"), "got {out:?}");
        assert!(out.contains('\n'), "the \\n was not honoured: {out:?}");
        assert!(out.ends_with("$ "), "got {out:?}");
        assert!(!out.contains('['), "zero-width markers leaked: {out:?}");
    }

    /// The git slot is filled with something representative, because a prompt
    /// specimen that omits it understates how wide a real prompt runs.
    #[test]
    fn the_git_segment_is_represented() {
        assert!(flat(REAL).contains("main"));
    }

    /// PROMPT_COMMAND fills these at runtime; there is nothing honest to put
    /// there, so they are dropped rather than printed literally.
    #[test]
    fn runtime_only_segments_are_dropped() {
        assert!(!flat(REAL).contains("__PS1_CONDA"));
        assert!(!flat(REAL).contains('$') || flat(REAL).ends_with("$ "));
    }

    /// Colour runs are split at every SGR change, so each gets its own colour.
    #[test]
    fn colour_changes_split_the_runs() {
        let lines = parse_ps1(REAL, "roest", "fedora");
        let first = &lines[0];
        assert!(first.len() >= 2, "expected several runs, got {first:?}");
        assert!(first[0].1 != first[1].1, "runs share a colour");
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
