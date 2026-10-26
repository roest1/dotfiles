//! How many terminal cells a string actually occupies.
//!
//! ## Why this exists rather than `.chars().count()`
//!
//! A terminal is a fixed grid and most characters take one cell, so counting
//! characters is right until it is not. Emoji are East Asian **Wide**: `✅` is
//! one `char` and TWO cells. Every piece of layout here -- truncating a label
//! to fit, reserving room for a badge, deciding whether the tab strip has run
//! out of width -- was counting characters, so an emoji anywhere in a
//! fixed-width column silently shifted everything after it by one cell per
//! emoji.
//!
//! The first answer to that was to ban emoji from columns. That was the wrong
//! trade: the glyphs carry colour and meaning that a word does not, which is
//! precisely why the fzf implementation used them. The right answer is to
//! measure properly, which is this file.
//!
//! ## Why not the `unicode-width` crate
//!
//! It is the correct general answer and it is a dependency plus a compile for
//! a complete table of a problem this crate has a bounded version of: the only
//! wide characters that reach these screens are the ones chosen in
//! `github::paint` and `github::model`. So the ranges below cover Unicode's
//! emoji-presentation blocks -- the set that is wide by default, with no
//! variation selector needed -- and everything else is one cell.
//!
//! If a screen ever needs CJK text, swap this for the crate. The signature is
//! the same and the call sites would not change.

/// Cells one character occupies.
///
/// Zero for a combining mark, two for a default-emoji-presentation character,
/// one for everything else.
pub fn char_width(c: char) -> usize {
    let u = c as u32;
    match u {
        // Combining marks: drawn on top of the previous cell, so they add
        // nothing. A variation selector (FE0F) is in here, which matters --
        // it is what turns `⚠` into an emoji presentation without widening it
        // in most terminals.
        0x0300..=0x036F | 0xFE00..=0xFE0F | 0x200D => 0,
        // The ranges Unicode marks Emoji_Presentation=Yes below U+1F000.
        // Written out rather than approximated, because `↑` (2191) and `★`
        // (2605) are NEIGHBOURS of wide characters and are one cell -- an
        // approximation that swept up the whole block would break the branch
        // table's arrows.
        0x231A..=0x231B
        | 0x23E9..=0x23EC
        | 0x23F0
        | 0x23F3
        | 0x25FD..=0x25FE
        | 0x2614..=0x2615
        | 0x2648..=0x2653
        | 0x267F
        | 0x2693
        | 0x26A1
        | 0x26AA..=0x26AB
        | 0x26BD..=0x26BE
        | 0x26C4..=0x26C5
        | 0x26CE
        | 0x26D4
        | 0x26EA
        | 0x26F2..=0x26F3
        | 0x26F5
        | 0x26FA
        | 0x26FD
        | 0x2705
        | 0x270A..=0x270B
        | 0x2728
        | 0x274C
        | 0x274E
        | 0x2753..=0x2755
        | 0x2757
        | 0x2795..=0x2797
        | 0x27B0
        | 0x27BF
        | 0x2B1B..=0x2B1C
        | 0x2B50
        | 0x2B55 => 2,
        // Everything in the supplemental symbol planes: the pictographs,
        // transport, flags and the rest. Wide by default, all of them.
        0x1F004 | 0x1F0CF | 0x1F18E | 0x1F191..=0x1F19A => 2,
        0x1F200..=0x1F320
        | 0x1F32D..=0x1F335
        | 0x1F337..=0x1F37C
        | 0x1F37E..=0x1F393
        | 0x1F3A0..=0x1F3CA
        | 0x1F3CF..=0x1F3D3
        | 0x1F3E0..=0x1F3F0
        | 0x1F3F4
        | 0x1F3F8..=0x1F43E
        | 0x1F440
        | 0x1F442..=0x1F4FC
        | 0x1F4FF..=0x1F53D
        | 0x1F54B..=0x1F54E
        | 0x1F550..=0x1F567
        | 0x1F57A
        | 0x1F595..=0x1F596
        | 0x1F5A4
        | 0x1F5FB..=0x1F64F
        | 0x1F680..=0x1F6C5
        | 0x1F6CC
        | 0x1F6D0..=0x1F6D2
        | 0x1F6D5..=0x1F6D7
        | 0x1F6EB..=0x1F6EC
        | 0x1F6F4..=0x1F6FC
        | 0x1F7E0..=0x1F7EB
        | 0x1F90C..=0x1F93A
        | 0x1F93C..=0x1F945
        | 0x1F947..=0x1F9FF
        | 0x1FA70..=0x1FAFF => 2,
        _ => 1,
    }
}

/// Cells a whole string occupies, ANSI escapes excluded.
///
/// The escapes have to be skipped rather than counted: they are characters in
/// the string and nothing on screen, which is the same arithmetic `lib/sgr.sh`
/// and `make help`'s typewriter both have to do.
pub fn width(s: &str) -> usize {
    let mut total = 0;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            // CSI ... final-byte. Everything up to and including the first
            // letter belongs to the escape.
            for e in chars.by_ref() {
                if e.is_ascii_alphabetic() {
                    break;
                }
            }
            continue;
        }
        total += char_width(c);
    }
    total
}

/// Pad `s` on the right to `cells`, measured properly. Longer strings are
/// returned unchanged -- the caller truncates if it needs to.
pub fn pad(s: &str, cells: usize) -> String {
    let w = width(s);
    if w >= cells {
        return s.to_string();
    }
    format!("{s}{}", " ".repeat(cells - w))
}

/// Pad `s` on the LEFT to `cells`, for a right-aligned column.
pub fn rpad(s: &str, cells: usize) -> String {
    let w = width(s);
    if w >= cells {
        return s.to_string();
    }
    format!("{}{s}", " ".repeat(cells - w))
}

/// Shorten `s` to at most `cells`, adding an ellipsis when it had to cut.
///
/// Cuts on a character boundary and never inside an escape, so a truncated
/// string cannot leave the terminal in whatever state a severed SGR implied.
pub fn truncate(s: &str, cells: usize) -> String {
    if width(s) <= cells {
        return s.to_string();
    }
    if cells == 0 {
        return String::new();
    }
    let budget = cells - 1;
    let mut out = String::new();
    let mut used = 0;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            out.push(c);
            for e in chars.by_ref() {
                out.push(e);
                if e.is_ascii_alphabetic() {
                    break;
                }
            }
            continue;
        }
        let w = char_width(c);
        if used + w > budget {
            break;
        }
        out.push(c);
        used += w;
    }
    out.push('\u{2026}');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The characters this repo's screens actually draw, and the pairs that
    /// make the naive answer wrong.
    #[test]
    fn the_glyphs_these_screens_use_measure_correctly() {
        // One cell: the markers and arrows the branch table lines up with.
        for c in [
            'a', ' ', '\u{25cf}', '\u{2605}', '\u{2191}', '\u{2193}', '\u{2713}', '\u{2502}',
        ] {
            assert_eq!(char_width(c), 1, "{c:?}");
        }
        // Two cells: the status emoji, which is the whole reason this exists.
        for c in [
            '\u{2705}',
            '\u{274c}',
            '\u{23f3}',
            '\u{1f512}',
            '\u{1f680}',
            '\u{1f33f}',
        ] {
            assert_eq!(char_width(c), 2, "{c:?}");
        }
    }

    /// `★` and `✅` are both one `char`. Counting characters says they are the
    /// same width; they are not, and that one cell per emoji is what shifted
    /// every column after it.
    #[test]
    fn counting_characters_is_what_this_replaces() {
        assert_eq!("\u{2605}".chars().count(), "\u{2705}".chars().count());
        assert_ne!(width("\u{2605}"), width("\u{2705}"));
        assert_eq!(width("\u{2605}"), 1);
        assert_eq!(width("\u{2705}"), 2);
    }

    /// Escapes are characters in the string and nothing on screen.
    #[test]
    fn ansi_escapes_occupy_no_cells() {
        assert_eq!(width("\x1b[38;5;203mfail\x1b[0m"), 4);
        assert_eq!(width("\x1b[1m\u{2705} ok\x1b[0m"), 5);
    }

    /// A variation selector styles the previous character without widening it.
    #[test]
    fn a_combining_mark_adds_nothing() {
        assert_eq!(width("\u{26a0}\u{fe0f}"), 1);
    }

    /// Padding a column of mixed glyph widths has to land on one boundary, or
    /// the table it is building is not a table.
    #[test]
    fn padding_lines_up_across_mixed_widths() {
        let col = [pad("\u{2705} ok", 8), pad("fail", 8), pad("\u{23f3}", 8)];
        for c in &col {
            assert_eq!(width(c), 8, "{c:?}");
        }
        let right = [rpad("8h", 5), rpad("\u{2705}", 5)];
        for c in &right {
            assert_eq!(width(c), 5, "{c:?}");
        }
    }

    /// Truncation must respect cells too, and must never sever an escape --
    /// a half-written SGR leaves the terminal in whatever state the fragment
    /// implied, for everything printed after it.
    #[test]
    fn truncation_counts_cells_and_keeps_escapes_whole() {
        assert_eq!(truncate("abcdef", 4), "abc\u{2026}");
        assert_eq!(width(&truncate("abcdef", 4)), 4);
        // Two emoji is four cells, so a 3-cell budget keeps one and ellipses.
        assert_eq!(width(&truncate("\u{2705}\u{274c}", 3)), 3);
        let styled = truncate("\x1b[31mabcdef\x1b[0m", 4);
        assert!(styled.contains("\x1b[31m"), "{styled:?}");
        assert!(!styled.ends_with('\x1b'));
        // Nothing to do when it already fits.
        assert_eq!(truncate("ab", 8), "ab");
    }
}
