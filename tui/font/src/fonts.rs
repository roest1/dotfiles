//! Finding fonts, and measuring the things that decide a choice.
//!
//! Two sources, split the way the Python previewer split them and for the same
//! reasons. fontconfig answers "what is installed and is it fixed-pitch", which
//! nothing in-process can answer without reimplementing font discovery. The
//! font FILE answers everything else, and is read directly rather than through
//! fontconfig's metadata, which lies about style in two separate ways — see
//! `cuts_of`.

use std::collections::{BTreeMap, BTreeSet};
use std::process::Command;

/// Claude Code's TUI glyphs, in tiers. Counting them flat scores a font that
/// carries five incidental ones above one that carries both of the two drawn
/// on every tool call, which is backwards.
pub const CRITICAL: &[(char, &str)] =
    &[('\u{23FA}', "⏺ tool call"), ('\u{23BF}', "⎿ result elbow")];
pub const FREQUENT: &[(char, &str)] = &[('\u{2733}', "✳ session"), ('\u{25D0}', "◐ spinner")];
pub const INCIDENTAL: &[(char, &str)] = &[
    ('\u{2610}', "☐ todo"),
    ('\u{2612}', "☒ done"),
    ('\u{2713}', "✓ check"),
    ('\u{2192}', "→ arrow"),
    ('\u{2022}', "• bullet"),
];

/// An Octicon from the Nerd Font private use area.
pub const NERD_PROBE: char = '\u{F408}';

fn fc(args: &[&str]) -> String {
    Command::new("fc-list")
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// Every fixed-pitch family, packaging noise collapsed.
///
/// BOTH spacing classes: fontconfig calls a font mono (100) only when every
/// glyph shares one advance, so a Nerd Font patched with full-width icons is
/// dual (90) instead. IosevkaTerm Nerd Font is 90 while its Mono cut is 100 —
/// asking for 100 alone hides the family this repo installs for the claude
/// lane, which is exactly what happened.
pub fn families() -> Vec<String> {
    let mut set: BTreeSet<String> = BTreeSet::new();
    for spacing in ["100", "90"] {
        for line in fc(&[&format!(":spacing={spacing}"), "family"]).lines() {
            for name in line.split(',') {
                let name = name.trim();
                if name.is_empty() || !keep_family(name) {
                    continue;
                }
                set.insert(name.to_string());
            }
        }
    }
    // wezterm reads this repo's own fonts straight out of the config dir via
    // font_dirs, without ever installing them, so fontconfig has never heard of
    // Science Gothic Mono. Read the directory rather than shelling out to
    // `wezterm ls-fonts`: it is the same answer, in-process.
    //
    // wezterm's BUILT-IN faces are deliberately not offered. The only one that
    // matters is its bundled JetBrains Mono, which has no file to measure — so
    // it could be picked but never previewed — and JetBrainsMono Nerd Font is
    // strictly better and already listed.
    for dir in [config_font_dir()] {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            if !matches!(ext.to_ascii_lowercase().as_str(), "ttf" | "otf") {
                continue;
            }
            let Ok(data) = std::fs::read(&path) else {
                continue;
            };
            let Ok(face) = ttf_parser::Face::parse(&data, 0) else {
                continue;
            };
            let mut family = None;
            for name in face.names() {
                // 16 is the typographic family; 1 is the legacy one, which for a
                // non-RIBBI cut carries the weight baked into it.
                if name.name_id == 16 {
                    family = name.to_string();
                    break;
                }
                if name.name_id == 1 && family.is_none() {
                    family = name.to_string();
                }
            }
            if let Some(f) = family.filter(|f| keep_family(f)) {
                set.insert(f);
            }
        }
    }

    set.into_iter().collect()
}

pub fn config_font_dir() -> std::path::PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config")
        });
    base.join("wezterm").join("fonts")
}

/// A single patched family ships under six or more names — the NF/NFM/NFP
/// abbreviations, the Propo cut, and one family per weight. Weight and italic
/// are chosen by wezterm's font_rules, so offering "JetBrainsMono NF Thin" as
/// its own entry offers a choice the rules then override.
fn keep_family(name: &str) -> bool {
    const WEIGHTS: &[&str] = &[
        "thin",
        "light",
        "extralight",
        "medium",
        "semibold",
        "demibold",
        "bold",
        "extrabold",
        "black",
        "retina",
        "italic",
        "oblique",
        "obl",
    ];
    let lower = name.to_ascii_lowercase();
    if lower.contains("emoji") || lower.starts_with("symbols nerd font") {
        return false;
    }
    let words: Vec<&str> = name.split_whitespace().collect();
    if let Some(last) = words.last() {
        if matches!(*last, "Propo" | "NFP" | "NFM" | "NF") {
            return false;
        }
        if WEIGHTS.contains(&last.to_ascii_lowercase().as_str()) {
            return false;
        }
    }
    // "JetBrainsMono NF Light" — an abbreviation followed by a weight.
    !words
        .windows(2)
        .any(|w| matches!(w[0], "NF" | "NFM" | "NFP"))
}

/// style -> file, for one family.
///
/// fontconfig reports a style LIST, real style first, legacy aliases after: a
/// non-RIBBI cut carries nameID 2 "Regular" because the legacy fields only have
/// four slots, so IosevkaTermNerdFont-SemiBold.ttf arrives as "SemiBold,Regular".
/// Taking the first token is what stops SemiBold from claiming Regular — and it
/// claiming Regular is what made the previewer render, weigh and measure the
/// wrong file.
pub fn cuts_of(family: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for line in fc(&["-f", "%{family}\t%{style}\t%{file}\n", family]).lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() != 3 {
            continue;
        }
        let (fams, style, path) = (parts[0], parts[1], parts[2]);
        if !fams
            .to_ascii_lowercase()
            .contains(&family.to_ascii_lowercase())
        {
            continue;
        }
        let mut alts = style.split(',').map(str::trim).filter(|s| !s.is_empty());
        let Some(first) = alts.next() else { continue };
        out.insert(first.to_string(), path.to_string());
        for alias in alts {
            out.entry(alias.to_string())
                .or_insert_with(|| path.to_string());
        }
    }
    if out.is_empty() {
        // Not in fontconfig — look in wezterm's font_dirs, which is where this
        // repo's generated faces live. Style comes from the file's own name
        // table; there is no fontconfig record to consult.
        if let Ok(entries) = std::fs::read_dir(config_font_dir()) {
            for entry in entries.flatten() {
                let path = entry.path();
                let Ok(data) = std::fs::read(&path) else {
                    continue;
                };
                let Ok(face) = ttf_parser::Face::parse(&data, 0) else {
                    continue;
                };
                let mut fam = None;
                let mut style = None;
                for name in face.names() {
                    match name.name_id {
                        16 => fam = name.to_string().or(fam),
                        1 if fam.is_none() => fam = name.to_string(),
                        17 => style = name.to_string().or(style),
                        2 if style.is_none() => style = name.to_string(),
                        _ => {}
                    }
                }
                if fam.as_deref() == Some(family) {
                    out.insert(
                        style.unwrap_or_else(|| "Regular".into()),
                        path.to_string_lossy().into_owned(),
                    );
                }
            }
        }
    }
    out
}

pub struct Metrics {
    pub advance: f32,
    pub line: f32,
    pub x_height: f32,
    pub weight: u16,
    pub variable: Option<(f32, f32)>,
    pub glyphs: u16,
    pub fixed: bool,
    pub critical: usize,
    pub frequent: usize,
    pub incidental: usize,
    pub missing: Vec<&'static str>,
    pub nerd: bool,
    pub box_drawing: usize,
    pub powerline: usize,
    pub braille: bool,
    pub ligatures: Vec<&'static str>,
}

pub fn measure(path: &str) -> Option<(Vec<u8>, Metrics)> {
    let data = std::fs::read(path).ok()?;
    let face = ttf_parser::Face::parse(&data, 0).ok()?;
    let upem = face.units_per_em() as f32;

    let adv = |c: char| {
        face.glyph_index(c)
            .and_then(|g| face.glyph_hor_advance(g))
            .map(|a| a as f32 / upem)
    };
    let advance = adv('m').unwrap_or(0.0);

    // fontconfig's spacing field is the font's CLAIM; this measures it.
    let probes: Vec<f32> = ['i', 'm', 'W'].iter().filter_map(|c| adv(*c)).collect();
    let fixed = !probes.is_empty()
        && probes.iter().cloned().fold(f32::MIN, f32::max)
            - probes.iter().cloned().fold(f32::MAX, f32::min)
            < 1e-4;

    let has = |c: char| face.glyph_index(c).is_some();
    let mut missing = Vec::new();
    let mut count = |set: &'static [(char, &'static str)]| {
        let mut n = 0;
        for (c, label) in set {
            if has(*c) {
                n += 1;
            } else {
                missing.push(*label);
            }
        }
        n
    };
    let critical = count(CRITICAL);
    let frequent = count(FREQUENT);
    let incidental = count(INCIDENTAL);

    // `calt` is the feature Fira Code, JetBrains Mono and Iosevka actually drive
    // => and != through. Checking `liga` alone reports "no ligatures" on all
    // three of the fonts most famous for having them.
    let mut ligatures = Vec::new();
    if let Some(gsub) = face.tables().gsub {
        for feature in gsub.features {
            match &feature.tag.to_bytes() {
                b"liga" => ligatures.push("liga"),
                b"calt" => ligatures.push("calt"),
                b"dlig" => ligatures.push("dlig"),
                b"clig" => ligatures.push("clig"),
                _ => {}
            }
        }
    }
    ligatures.sort_unstable();
    ligatures.dedup();

    let m = Metrics {
        advance,
        line: (face.ascender() as f32 - face.descender() as f32 + face.line_gap() as f32) / upem,
        x_height: face.x_height().map(|v| v as f32 / upem).unwrap_or(0.0),
        weight: face.weight().to_number(),
        variable: face
            .variation_axes()
            .into_iter()
            .find(|a| a.tag.to_bytes() == *b"wght")
            .map(|a| (a.min_value, a.max_value)),
        glyphs: face.number_of_glyphs(),
        fixed,
        critical,
        frequent,
        incidental,
        missing,
        nerd: has(NERD_PROBE),
        box_drawing: (0x2500u32..0x2580)
            .filter(|c| has(char::from_u32(*c).unwrap()))
            .count(),
        powerline: (0xE0A0u32..0xE0D5)
            .filter(|c| has(char::from_u32(*c).unwrap()))
            .count(),
        braille: has('\u{2800}'),
        ligatures,
    };
    Some((data, m))
}

/// Style names read from the FILES themselves, for fonts fontconfig has never
/// seen — anything `fontbrowse` has downloaded but not installed.
///
/// A variable font's cuts are its named instances, not a name field: nameID 17
/// on VictorMono[wght] is "Thin", the DEFAULT instance, so reading it reports
/// one cut and calls a font famous for its italics italic-less. ttf-parser
/// exposes the axes but not the instance names, so a variable file is reported
/// by its axis range instead of a fake cut list — honest about what is known.
pub fn styles_of_files(paths: &[String]) -> Vec<String> {
    let mut out: BTreeSet<String> = BTreeSet::new();
    for path in paths {
        let Ok(data) = std::fs::read(path) else {
            continue;
        };
        let Ok(face) = ttf_parser::Face::parse(&data, 0) else {
            continue;
        };
        if face.is_variable() {
            if let Some(a) = face
                .variation_axes()
                .into_iter()
                .find(|a| a.tag.to_bytes() == *b"wght")
            {
                let italic = path.to_ascii_lowercase().contains("italic");
                out.insert(format!(
                    "variable wght {:.0}–{:.0}{}",
                    a.min_value,
                    a.max_value,
                    if italic { " italic" } else { "" }
                ));
                continue;
            }
        }
        let mut style = None;
        for name in face.names() {
            match name.name_id {
                17 => style = name.to_string().or(style),
                2 if style.is_none() => style = name.to_string(),
                _ => {}
            }
        }
        out.insert(style.unwrap_or_else(|| "Regular".into()));
    }
    out.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::keep_family;

    /// A single patched family ships under six or more names. These are the
    /// ones that must NOT reach the picker, because weight and italic are
    /// chosen by wezterm's font_rules and offering them here offers a choice
    /// the rules then override.
    #[test]
    fn packaging_variants_are_collapsed() {
        for noisy in [
            "JetBrainsMono NF",
            "JetBrainsMono NFM",
            "JetBrainsMono NFP",
            "JetBrainsMono Nerd Font Propo",
            "JetBrainsMono NF Light",
            "IosevkaTerm NFM SemiBold",
            "Source Code Pro Semibold",
            "Noto Color Emoji",
            "Symbols Nerd Font Mono",
        ] {
            assert!(!keep_family(noisy), "should have been filtered: {noisy}");
        }
    }

    /// The dual-width case, which is the one that actually bit. Both of these
    /// are real families a person would want; `IosevkaTerm Nerd Font` is
    /// fontconfig spacing 90 rather than 100 because its icons are full-width,
    /// and an earlier filter dropped it — the font this repo installs for the
    /// claude lane, missing from its own picker.
    #[test]
    fn real_families_survive() {
        for good in [
            "0xProto Nerd Font",
            "IosevkaTerm Nerd Font",
            "IosevkaTerm Nerd Font Mono",
            "JetBrainsMono Nerd Font",
            "Science Gothic Mono",
            "Adwaita Mono",
        ] {
            assert!(keep_family(good), "should have been kept: {good}");
        }
    }
}
