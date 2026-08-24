//! What a screen has to provide, and nothing more.
//!
//! Kept deliberately small so the next two screens are cheap. `make it` is a
//! tree of Makefile groups with a help page on the right; `github` is a list of
//! runs or PRs with a live preview on the right. Both are this shape: rows on
//! the left, a pane on the right, single-key actions on the rows.
//!
//! `rows()` is rebuilt per draw rather than mutated in place. That is a real
//! cost at very large N and it is the right trade here: a screen whose model is
//! "derive the visible rows from state" cannot desynchronise its display from
//! its state, which is the bug class that made the old fzf screens stale.

use crate::nav::Action;

#[derive(Debug, Clone)]
pub struct Row {
    /// Drawn first, and BOLD when `group` is set — a header should read as one
    /// without needing a glyph to say so.
    pub label: String,
    /// Dim text after the label: the second column of a two-column row. A
    /// lane's current value, a PR's author. Kept apart from `label` so the
    /// label can be bold and column-aligned while this is neither.
    pub detail: Option<String>,
    /// Indent level. The reticle needs room to sit OUTSIDE the label at full
    /// spread, so a screen that renders at depth 0 still gets a left margin.
    pub depth: u16,
    pub group: bool,
    pub expanded: bool,
    /// A short marker — a status glyph, a fit verdict — with its ANSI colour.
    /// RIGHT-ALIGNED to the pane edge, with the text before it truncated to
    /// make room, so a long family name can never shove a badge across the
    /// divider.
    pub badge: Option<(String, u8)>,
    /// False for spacers. Navigation skips them, so blank rows can group
    /// things without the cursor ever landing in one.
    pub selectable: bool,
}

impl Row {
    pub fn leaf(label: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            detail: None,
            depth: 0,
            group: false,
            expanded: false,
            badge: None,
            selectable: true,
        }
    }

    /// A blank, unselectable row. Grouping four lanes visually beats saying
    /// out loud that they are categories.
    pub fn spacer() -> Self {
        let mut r = Self::leaf("");
        r.selectable = false;
        r
    }

    pub fn badged(mut self, text: impl Into<String>, color: u8) -> Self {
        self.badge = Some((text.into(), color));
        self
    }

    pub fn detail(mut self, text: impl Into<String>) -> Self {
        self.detail = Some(text.into());
        self
    }
}

/// The right-hand pane. An image is a first-class member because the font
/// browser's whole point is showing type, and a picture of type is not
/// expressible as lines — see the note on redraw cost in `app`.
#[derive(Default)]
pub struct Pane {
    pub image: Option<Image>,
    pub lines: Vec<String>,
}

pub struct Image {
    pub png: Vec<u8>,
    /// Height in terminal ROWS. The pane reserves exactly this much and clears
    /// everything below it, so an image that scales differently than expected
    /// cannot eat the text.
    pub rows: u16,
}

/// What a screen wants from the next moment, for work happening off the main
/// thread. `github` will need exactly this for its `gh` calls; the font browser
/// needs it for HTTP.
///
/// The three states exist because "keep waking me" and "something changed" are
/// different questions, and collapsing them re-renders an image on every frame
/// of a download.
pub enum Tick {
    /// Nothing outstanding — block on input and cost nothing.
    Idle,
    /// Work in flight, but nothing new to show. Wake again; do not redraw.
    Busy,
    /// New state arrived. Wake and redraw the pane.
    Changed,
}

pub enum Flow {
    Continue,
    /// Redraw the right-hand pane too, image included. Returned only when the
    /// pane's CONTENT changed, never for reticle motion.
    Dirty,
    /// Open a screen on top of this one, keeping this one's cursor exactly
    /// where it was. `github` wants this for drilling into a run's logs; the
    /// font picker wants it for browsing fonts it has not installed.
    Push(Box<dyn Screen>),
    /// Close this screen and go back. `q` does it for you at any depth below
    /// the root, so a screen rarely needs to return this itself.
    Pop,
    Quit,
}

pub trait Screen {
    fn title(&self) -> String;
    fn rows(&mut self) -> Vec<Row>;
    fn footer(&self) -> String;
    /// Build the right-hand pane for the current selection.
    fn pane(&mut self, sel: usize, cols: u16, rows: u16) -> Pane;
    /// Screen-specific keys. Navigation is handled for you.
    fn on_action(&mut self, action: Action, sel: usize) -> Flow;

    /// Called once per frame while anything is moving. Default: nothing is.
    fn tick(&mut self) -> Tick {
        Tick::Idle
    }

    /// Told where the cursor is, so a screen can prefetch around it. Separate
    /// from `pane` because prefetching must happen even for rows you skim past
    /// without stopping on.
    fn focus(&mut self, _sel: usize) {}
}
