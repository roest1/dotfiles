//! `font show` — what each lane is set to, and whether the terminal is
//! actually honoring it.
//!
//! The second half is the part that earns this file. The picker rasterizes its
//! own previews with fontdue and draws them as inline images, so a specimen
//! looks perfect whether or not wezterm is applying `font_rules` at all — the
//! one screen dedicated to fonts was blind to the one failure that matters.
//! The carrier below is the opposite: real SGR 5 and SGR 6 text, rendered by
//! the terminal, so it is a picture of what wezterm did rather than of what
//! this process thinks it should have done.
//!
//! There used to be a version floor answering this instead — a build stamp in
//! wezterm/MIN_VERSION, compared on every install. It inferred a render-time
//! behavior from a number, which is not inferable, and it could not fail safe:
//! any build at or above the floor passed untested. What replaced it splits the
//! question along the line of what is actually knowable. Everything here is
//! either provable (does the family exist, is the config dir linked) or shown
//! to the only instrument that can read it.

use crate::fonts;
use crate::lanes;

/// Whether the fonts the TERMINAL will use are visible to this process.
///
/// Inside WSL they are not, and that is by design rather than a broken install:
/// wezterm.exe runs on the Windows host and draws the pixels, so the families
/// it resolves live in the host's font path. wezterm/deps.sh skips every font
/// download in the guest for the same reason.
///
/// So the guest's answer to "is this family installed" is UNKNOWABLE, not "no".
/// Reporting MISSING here would be a false red on a correctly set up machine --
/// and, since status_fonts counts the exit code as drift, would have made
/// `make status` red on the one platform this repo is most often driven from.
///
/// This duplicates is_wsl in lib/pkg.sh, which is a real cost and a small one:
/// it is a one-line read of /proc/version, and the alternative is a flag passed
/// in by the caller, which would make `font show` answer differently depending
/// on who ran it.
fn fonts_are_local() -> bool {
    match std::fs::read_to_string("/proc/version") {
        Ok(v) => {
            let v = v.to_ascii_lowercase();
            !(v.contains("microsoft") || v.contains("wsl"))
        }
        Err(_) => true,
    }
}

/// The three conditions from lib/sgr.sh, and the same reasoning.
///
/// Reported rather than merely tested, because "the carrier did not print" and
/// "the carrier printed and looked wrong" are different diagnoses and the user
/// cannot tell them apart from an absence.
enum Carrier {
    Live,
    /// stdout is not a terminal — `make status | tee` and CI both land here.
    Piped,
    /// Every other terminal renders SGR 6 as what it means: blinking text.
    NotWezterm(String),
    /// Being IN wezterm is not the same as wezterm having the font_rules.
    NotLinked(String),
}

fn carrier() -> Carrier {
    // SAFETY: isatty on a fixed fd, no arguments borrowed.
    if unsafe { libc::isatty(1) } != 1 {
        return Carrier::Piped;
    }
    match std::env::var("TERM_PROGRAM").unwrap_or_default().as_str() {
        "WezTerm" => {}
        other => {
            let named = if other.is_empty() { "unset" } else { other };
            return Carrier::NotWezterm(named.to_string());
        }
    }
    let dir = fonts::config_font_dir();
    if !dir.is_dir() {
        return Carrier::NotLinked(dir.display().to_string());
    }
    Carrier::Live
}

fn tildify(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && path.starts_with(&home) => {
            format!("~{}", &path[home.len()..])
        }
        _ => path.to_string(),
    }
}

/// Non-zero when a lane names a family this machine does not have.
///
/// That is the only half of this command a program can judge, so it is the only
/// half that gets an exit code. status_fonts (lib/status.sh) reads it and counts
/// drift on it; the carrier below is informational there for the same reason it
/// is a picture here — over ssh, in a pipe, on any other terminal it is
/// unreadable, and a machine that is fine would report red.
pub fn run() -> i32 {
    let state = lanes::read();
    let local = fonts_are_local();
    let installed = if local { fonts::families() } else { Vec::new() };
    let mut missing = 0;

    println!();
    println!("  lanes");
    for (lane, value) in &state {
        let mark = if !local {
            "host"
        } else if installed.iter().any(|f| f == value) {
            "ok"
        } else {
            missing += 1;
            "MISSING"
        };
        println!(
            "    {lane:<12} {value:<28} {mark:<8} {}",
            lanes::covers(lane)
        );
    }
    println!();
    println!(
        "    state: {}",
        tildify(&lanes::state_path().display().to_string())
    );
    if !local {
        println!("    `host` — this is the WSL guest, and wezterm.exe resolves these on the");
        println!("    Windows side, so whether they are installed is not knowable from in");
        println!("    here. `make windows` runs the host installer, which reports each face.");
    }
    if missing > 0 {
        println!("    a lane names a family this machine does not have — run `font` to repick,");
        println!("    or `make install wezterm` to fetch the defaults.");
    }

    println!();
    println!("  carrier");
    match carrier() {
        Carrier::Live => {
            // Each sample resets immediately after itself. A truncated or
            // interrupted line must not leave the terminal in SGR 6, which
            // would silently reskin everything printed after it.
            println!("    SGR 6  \x1b[6mScience Gothic Mono\x1b[22;25m  <- `make` output");
            println!("    SGR 5  \x1b[5mthe nvim editor lane\x1b[22;25m  <- the file you edit");
            println!("    plain  the base font           <- everything else");
            println!();
            println!("    Three different faces means the lanes are live. If they are one face,");
            println!("    wezterm is not matching font_rules on the blink attribute — the 2024");
            println!("    stable does not, and fails silently. See windows/README.md.");
            if !local {
                println!();
                println!("    This one does cross the guest boundary: the escape is written in");
                println!("    here and drawn by wezterm.exe out there, so it is the only check");
                println!("    on this machine that tests what you actually see.");
            }
        }
        Carrier::Piped => {
            println!("    · not shown — stdout is not a terminal.");
            println!("      The carrier is an escape sequence; it must never reach a pipe.");
            println!("      Run `font show` directly to see it.");
        }
        Carrier::NotWezterm(term) => {
            println!("    · not shown — TERM_PROGRAM is {term}, not WezTerm.");
            println!("      SGR 6 means BLINKING TEXT on every other terminal, so this");
            println!("      degrades to plain rather than strobing at you over ssh.");
        }
        Carrier::NotLinked(dir) => {
            println!("    · not shown — {} is not linked.", tildify(&dir));
            println!("      Being in wezterm is not the same as wezterm having the font_rules;");
            println!("      a stock config has none. Run `make link` to point it at this repo.");
        }
    }
    println!();

    i32::from(missing > 0)
}
