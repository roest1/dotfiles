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
use std::time::Duration;

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
    /// Short markers — a status word, a fit verdict, a column of a table —
    /// each with its ANSI colour.
    ///
    /// RIGHT-ALIGNED to the list's right edge, laid out right to left in the
    /// order given, with the text before them truncated to make room — so a
    /// long family name can never shove a badge across the divider.
    ///
    /// SEVERAL, because a full-width table is a row with six facts on the
    /// right of it and one badge could only hold the last. They do not
    /// self-align: `app` packs them against the edge, so a screen that wants a
    /// COLUMN pads each value to a fixed width itself. It knows its own data
    /// and `rows()` does not know the terminal width, which is the trade that
    /// keeps the width out of this trait.
    pub badges: Vec<(String, u8)>,
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
            badges: Vec::new(),
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

    /// Add one marker, rightmost first.
    pub fn badged(mut self, text: impl Into<String>, color: u8) -> Self {
        self.badges.push((text.into(), color));
        self
    }

    pub fn detail(mut self, text: impl Into<String>) -> Self {
        self.detail = Some(text.into());
        self
    }
}

/// How a screen wants the body divided.
///
/// Per screen rather than per program, because the shapes genuinely differ: a
/// workflow run is a short list with a long story beside it, where a branch
/// list is a TABLE -- six columns of fact per row and nothing worth a pane.
/// Forcing the table into a 52-column sidebar would have meant dropping
/// columns to fit a pane that had nothing to say.
pub enum Split {
    /// List on the left, detail pane on the right. The default, and what
    /// `font`, `dots`, Actions and the account screens all want.
    ListPane,
    /// The list spans the full width. No pane, no divider -- and `pane()` is
    /// never called, so a screen using this need not implement one usefully.
    Full,
    /// A narrow column of controls on the left, the list on the right.
    ///
    /// The shape of Riley's Issues and PRs mocks, and the inverse of
    /// `ListPane`: the left column holds the FILTERS and the content is on the
    /// right. So there are two row regions, both navigable, with `h` and `l`
    /// crossing between them -- which is why this needed `Screen::sidebar` and
    /// `Screen::on_sidebar` rather than being a width setting.
    ///
    /// No pane. The mocks put everything a row needs on the row and the
    /// actions behind a menu, so there is nothing a third column would hold.
    Sidebar,
}

/// A header strip of sibling screens, drawn above BOTH columns.
///
/// Peers, not a stack: six things about one repo are not six levels deep, and
/// making them a stack meant popping to the hub to get from Issues to PRs. A
/// screen that returns this is a HOST -- it owns one child per tab and
/// delegates to the active one, so each tab stays its own `Screen` impl and
/// `Actions` did not have to know it had become a tab.
///
/// `None` (the default) keeps the plain bold title, which is what `font` and
/// `dots` draw. The strip costs one extra header row, so a screen that has no
/// siblings does not pay for it.
pub struct Tabs {
    /// Dim text before the strip: whose tabs these are. The strip replaces the
    /// title row, so without it a screen loses the one place it said which
    /// repo or org you are looking at.
    pub label: Option<String>,
    pub names: Vec<String>,
    pub active: usize,
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
/// The states exist because "keep waking me", "wake me later" and "something
/// changed" are different questions, and collapsing them re-renders an image on
/// every frame of a download.
pub enum Tick {
    /// Nothing outstanding — block on input and cost nothing.
    Idle,
    /// Work in flight, but nothing new to show. Wake again on the NEXT FRAME;
    /// do not redraw. For work measured in milliseconds, where polling at 60fps
    /// for its duration is the price of noticing the moment it lands.
    Busy,
    /// Nothing in flight, but ask again after this long.
    ///
    /// For a screen watching something that changes on ITS own clock rather
    /// than on ours — `github` re-asking a live workflow run every five
    /// seconds. `Busy` is the wrong answer there and not by a little: it sets
    /// the poll timeout to one frame, so a run that takes nine minutes would
    /// spin this process at 60fps for nine minutes to notice an event that can
    /// only arrive on a five-second boundary. That is the laptop fan this
    /// loop's blocking poll exists to avoid, reintroduced by the one kind of
    /// screen that most needs to stay quiet while it waits.
    ///
    /// It does NOT keep the reticle moving and does not mark the pane dirty —
    /// it only shortens the wait for the next input poll. So a screen that asks
    /// for a wake and then has nothing to say costs one timeout and one row
    /// redraw, not a frame loop.
    Wake(Duration),
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
    /// Ask the user for one line of text, then call `Screen::answered`.
    ///
    /// Screen-driven, where filtering is framework-driven, and the split is
    /// the point: narrowing a list means the same thing on every screen, so
    /// `app` does it and no screen is told. A VALUE only the screen knows what
    /// to do with has to come back to the screen.
    ///
    /// One line, deliberately. These are identifiers — a secret's name, a new
    /// branch name, an environment — not bodies. Anything longer already has a
    /// better answer: `gh pr create` and `gh pr edit` prompt for a title and a
    /// body themselves, on the real terminal, via `Flow::Detach`. That is why
    /// this arrived later and smaller than expected.
    Ask {
        /// What is being asked, as a question. Shown in the field.
        label: String,
        /// Pre-filled, for a rename or an edit.
        initial: String,
    },
    /// Like `Dirty`, but the cursor's place is no longer meaningful — ask
    /// `initial_sel` again.
    ///
    /// For a tab switch, which is the one thing that replaces every row at
    /// once. `Dirty` only clamps the selection, so switching from a 40-row tab
    /// to a 3-row one would leave the cursor at the bottom of a tab you are no
    /// longer looking at. Reusing `initial_sel` rather than inventing a
    /// "go to row N" flow is what lets a host remember each tab's own cursor
    /// and hand it back on return, without `app` learning what a tab is.
    Retarget,
    /// Hand the terminal back, run this command line to completion on the
    /// user's REAL tty, then take the terminal again and redraw.
    ///
    /// The alternative was streaming a child's output into the pane, and it is
    /// worse for the case this exists to serve. A child on the real tty can
    /// prompt for a sudo password, which a pane cannot -- raw mode has already
    /// taken the keyboard -- and that single fact is what made the bash console
    /// carry sudo priming and a credential keepalive. It also means the output
    /// is exactly what you would have seen typing the command, colour and all,
    /// rather than a reimplementation of it.
    ///
    /// First element is the program; the rest are arguments, unsplit and
    /// unquoted, so nothing here goes through a shell.
    Detach(Vec<String>),
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

    /// The header strip, if this screen has siblings. Default: none, and the
    /// title is drawn plain.
    fn tabs(&self) -> Option<Tabs> {
        None
    }

    /// How to divide the body. Default: list left, pane right.
    fn split(&self) -> Split {
        Split::ListPane
    }

    /// The left column's rows, for `Split::Sidebar`.
    ///
    /// Its own method rather than a flag on `rows()` because the two lists are
    /// navigated separately and have separate cursors -- and because every
    /// screen that does not want one should not have to say so.
    fn sidebar(&mut self) -> Vec<Row> {
        Vec::new()
    }

    /// A key pressed with the SIDEBAR focused, with the sidebar's own row
    /// index. `rows()`'s handler is `on_action`; this is the other one.
    ///
    /// Split in two rather than passed a region, so a screen cannot read the
    /// index against the wrong list -- which is the one mistake here that
    /// would act on a row nobody was looking at.
    fn on_sidebar(&mut self, _action: Action, _sel: usize) -> Flow {
        Flow::Continue
    }

    /// The answer to a `Flow::Ask`, or `None` if it was abandoned.
    ///
    /// The screen is responsible for remembering WHAT it asked — `app` carries
    /// the text and nothing else. A screen that can ask more than one thing
    /// keeps a field saying which, the same way a pending confirm does.
    fn answered(&mut self, _text: Option<String>) -> Flow {
        Flow::Continue
    }

    /// Which row to open on. Default: the first.
    ///
    /// Asked of the screen rather than passed in beside it, because the screen
    /// is the only thing that knows which of its rows the answer corresponds
    /// to -- `github` run inside a repo wants that repo's row, and where that
    /// lands depends on which lanes it decided to open. A caller would have to
    /// reimplement the row walk to compute it.
    ///
    /// Clamped by `app` to the rows actually produced, and skipped past if it
    /// names a spacer, so a stale answer cannot put the cursor nowhere.
    fn initial_sel(&self) -> usize {
        0
    }
}
