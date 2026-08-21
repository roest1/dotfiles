//! The reticle: `[ name ]`, travelling and converging.
//!
//! Lifted from `lib/tui.sh`, which lifted it from the TargetCursor component on
//! Riley's site. Two behaviours carry the idea and both survive here:
//!
//!   TRAVEL     the brackets move from the row they were on toward the row they
//!              are going to, closing a fixed fraction of the gap each frame.
//!              On j/k that is one row and nearly invisible; on G it crosses the
//!              pane, which is what reads as ACQUIRING rather than as a
//!              highlight jumping.
//!   CONVERGE   on arrival they tighten inward, from four cells out to one.
//!
//! THE NAME NEVER MOVES. Rows are indented far enough that the brackets sit
//! outside the label at full spread, so only the frame travels. A reticle that
//! shoved its target sideways would be a hover style with extra steps.
//!
//! What Rust buys over the bash original is honesty about time. `lib/tui.sh`
//! advances one step per `read -n1 -t 0.03`, so its animation runs at whatever
//! rate the terminal happens to deliver keystrokes. Here the step is driven by
//! elapsed time, so the motion is the same on a fast machine and a slow one,
//! and 60fps is a frame budget rather than an aspiration.

use std::time::Duration;

/// Fraction of the remaining distance closed per 16ms frame. Tuned by eye
/// against the bash original's "halve the distance": 0.35 lands a G-sized jump
/// in ~8 frames, which is fast enough to feel immediate and slow enough to read
/// as travel.
const TRAVEL_PER_FRAME: f32 = 0.35;
const SPREAD_MAX: f32 = 4.0;
const SPREAD_MIN: f32 = 1.0;
const FRAME: f32 = 16.0;

/// Below this the position is snapped and the animation declared over --
/// otherwise it asymptotes forever and the loop never gets to block on input.
const SETTLED: f32 = 0.02;

pub struct Reticle {
    row: f32,
    target: f32,
    spread: f32,
}

impl Reticle {
    pub fn new(row: usize) -> Self {
        Self {
            row: row as f32,
            target: row as f32,
            spread: SPREAD_MIN,
        }
    }

    /// Aim at a new row. Re-spreads the brackets so the convergence replays;
    /// that is what makes each move read as a fresh acquisition.
    pub fn aim(&mut self, row: usize) {
        let row = row as f32;
        if (row - self.target).abs() > f32::EPSILON {
            self.target = row;
            self.spread = SPREAD_MAX;
        }
    }

    /// Advance by real elapsed time. Returns whether anything is still moving,
    /// which is what lets the caller block on input instead of spinning.
    pub fn step(&mut self, dt: Duration) -> bool {
        let frames = (dt.as_secs_f32() * 1000.0 / FRAME).clamp(0.0, 4.0);
        if frames <= 0.0 {
            return self.moving();
        }
        // Compounded per-frame decay rather than a single scaled step, so a
        // dropped frame catches up instead of overshooting.
        let keep = (1.0 - TRAVEL_PER_FRAME).powf(frames);
        self.row = self.target - (self.target - self.row) * keep;
        if (self.target - self.row).abs() < SETTLED {
            self.row = self.target;
        }

        // Converge only once travel is essentially done, so the two motions
        // read in sequence -- fly to it, then close on it -- rather than
        // mushing together into a single blur.
        if (self.target - self.row).abs() < 0.5 {
            self.spread = SPREAD_MIN + (self.spread - SPREAD_MIN) * keep;
            if self.spread - SPREAD_MIN < SETTLED {
                self.spread = SPREAD_MIN;
            }
        }
        self.moving()
    }

    pub fn moving(&self) -> bool {
        (self.target - self.row).abs() >= SETTLED || self.spread - SPREAD_MIN >= SETTLED
    }

    /// The row the brackets are drawn on this frame.
    pub fn row(&self) -> usize {
        self.row.round().max(0.0) as usize
    }

    /// How many cells outside the label each bracket sits.
    pub fn spread(&self) -> u16 {
        self.spread.round().max(SPREAD_MIN as f64 as f32) as u16
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The property the event loop depends on. If the reticle never reports
    /// "settled", `app` polls on a 16ms timeout forever and the process spins
    /// at 60fps showing a static list — a laptop fan, not a bug you would spot
    /// by looking at it.
    #[test]
    fn settles_so_the_loop_can_block() {
        let mut r = Reticle::new(0);
        r.aim(40);
        let mut frames = 0;
        while r.moving() {
            r.step(Duration::from_millis(16));
            frames += 1;
            assert!(frames < 600, "reticle never settled");
        }
        assert_eq!(r.row(), 40);
        assert_eq!(r.spread(), SPREAD_MIN as u16);
    }

    /// Travel has to be visible or it is just a highlight jumping. A one-row
    /// move should be nearly instant; a pane-crossing G should take enough
    /// frames to read as motion.
    #[test]
    fn a_long_jump_takes_longer_than_a_short_one() {
        let count = |to: usize| {
            let mut r = Reticle::new(0);
            r.aim(to);
            let mut n = 0;
            while r.moving() && n < 600 {
                r.step(Duration::from_millis(16));
                n += 1;
            }
            n
        };
        assert!(count(40) > count(1), "a long jump should take more frames");
    }

    /// Elapsed time drives the step, not the number of calls -- that is the
    /// whole difference from the bash original, which advanced once per
    /// keystroke and so animated at whatever rate the terminal delivered them.
    #[test]
    fn one_big_step_matches_several_small_ones() {
        let mut a = Reticle::new(0);
        let mut b = Reticle::new(0);
        a.aim(20);
        b.aim(20);
        a.step(Duration::from_millis(64));
        for _ in 0..4 {
            b.step(Duration::from_millis(16));
        }
        assert!((a.row() as i32 - b.row() as i32).abs() <= 1);
    }
}
