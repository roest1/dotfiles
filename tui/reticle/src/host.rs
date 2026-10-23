//! A screen that is several screens: the tab strip's other half.
//!
//! `Tabs` says what to DRAW. This is what makes the tabs work, and it is a
//! composition rather than a feature: a `Host` owns one `Screen` per tab and
//! forwards every call to the active one. So a screen does not have to know it
//! has become a tab -- `github`'s Actions screen was written before tabs
//! existed and is a tab now with no change to it at all.
//!
//! ## Why peers and not a stack
//!
//! Six things about one repo are not six levels deep. Modelling them as a stack
//! means popping to a hub to get from Issues to PRs, which is two keystrokes to
//! express "sideways" -- and the hub exists only to be passed through. Tabs are
//! the honest shape for siblings, and `Tab`/shift-`Tab` is one keystroke.
//!
//! The stack is still there and still means what it did: `Flow::Push` from
//! inside a tab opens a screen over the WHOLE host, and `q` comes back to the
//! tab you left. Depth is for drilling in; tabs are for moving along.
//!
//! ## What it has to remember
//!
//! Each tab's cursor. Switching tabs replaces every row, so `app` cannot carry
//! the selection across -- clamping a 40-row position into a 3-row tab would
//! land somewhere arbitrary. The host records where you were in each tab as you
//! leave it and answers `initial_sel` with it on the way back, which is the
//! mechanism `Flow::Retarget` exists to trigger. `app` never learns what a tab
//! is.

use crate::nav::Action;
use crate::screen::{Flow, Pane, Row, Screen, Split, Tabs, Tick};

pub struct Host {
    label: Option<String>,
    names: Vec<String>,
    screens: Vec<Box<dyn Screen>>,
    active: usize,
    /// Where the cursor was in each tab, by tab index.
    marks: Vec<usize>,
}

impl Host {
    /// `tabs` is (name, screen) in display order; at least one is required.
    pub fn new(label: Option<String>, tabs: Vec<(String, Box<dyn Screen>)>) -> Self {
        let (names, screens): (Vec<String>, Vec<Box<dyn Screen>>) = tabs.into_iter().unzip();
        let marks = vec![0; screens.len()];
        Self {
            label,
            names,
            screens,
            active: 0,
            marks,
        }
    }

    /// Open on a particular tab rather than the first.
    ///
    /// How `github` inside a repo arrives: the user level opens showing its
    /// repo list with that repo selected, not showing the account page.
    pub fn opening_on(mut self, tab: usize) -> Self {
        if tab < self.screens.len() {
            self.active = tab;
        }
        self
    }

    /// The index of a tab by name, for callers that would rather not count.
    pub fn index_of(&self, name: &str) -> Option<usize> {
        self.names.iter().position(|n| n == name)
    }

    fn current(&mut self) -> &mut dyn Screen {
        self.screens[self.active].as_mut()
    }

    fn step(&mut self, by: isize) -> Flow {
        if self.screens.len() < 2 {
            return Flow::Continue;
        }
        let n = self.screens.len() as isize;
        // Wraps. A strip is a ring in every other tabbed thing on the machine,
        // and stopping at the ends makes the last tab awkward to reach.
        self.active = (((self.active as isize + by) % n + n) % n) as usize;
        Flow::Retarget
    }
}

impl Screen for Host {
    fn title(&self) -> String {
        // Only reached if something draws a host without its strip; the strip
        // carries the label otherwise.
        self.label.clone().unwrap_or_default()
    }

    fn tabs(&self) -> Option<Tabs> {
        Some(Tabs {
            label: self.label.clone(),
            names: self.names.clone(),
            active: self.active,
        })
    }

    fn rows(&mut self) -> Vec<Row> {
        self.current().rows()
    }

    /// Forwarded, because the LAYOUT belongs to the tab rather than to the
    /// strip above it -- a repo's Branches table wants the full width and its
    /// Actions list wants a pane, and they are siblings. Forgetting this made
    /// `Split::Full` silently do nothing: the host answered for the default and
    /// the table's badges, packed into a 52-column sidebar, truncated every
    /// branch name to nothing.
    fn split(&self) -> Split {
        self.screens[self.active].split()
    }

    fn footer(&self) -> String {
        let child = self.screens[self.active].footer();
        if self.screens.len() < 2 {
            return child;
        }
        // The strip's own key, named on the last line where the stack's `q`
        // also lands -- so "how do I move sideways" and "how do I go back" are
        // in the same place on every screen.
        if child.is_empty() {
            "tab switches".into()
        } else {
            format!("{child}\n\u{21e5} tab switches")
        }
    }

    fn pane(&mut self, sel: usize, cols: u16, rows: u16) -> Pane {
        self.current().pane(sel, cols, rows)
    }

    fn tick(&mut self) -> Tick {
        // Only the ACTIVE tab ticks. A background tab polling a workflow run
        // you are not looking at is exactly the cost the two-clock design went
        // to trouble to avoid.
        self.current().tick()
    }

    fn focus(&mut self, sel: usize) {
        self.marks[self.active] = sel;
        self.current().focus(sel);
    }

    fn initial_sel(&self) -> usize {
        // The remembered position if there is one, else let the tab answer for
        // itself -- which is how a freshly built tab still opens on the row it
        // wants (github's repo list on the repo you are standing in).
        let mark = self.marks[self.active];
        if mark > 0 {
            mark
        } else {
            self.screens[self.active].initial_sel()
        }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        match action {
            Action::NextTab => {
                self.marks[self.active] = sel;
                self.step(1)
            }
            Action::PrevTab => {
                self.marks[self.active] = sel;
                self.step(-1)
            }
            other => self.current().on_action(other, sel),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake(&'static str, usize);
    impl Screen for Fake {
        fn title(&self) -> String {
            self.0.into()
        }
        fn rows(&mut self) -> Vec<Row> {
            (0..self.1)
                .map(|i| Row::leaf(format!("{}{i}", self.0)))
                .collect()
        }
        fn footer(&self) -> String {
            format!("{} keys", self.0)
        }
        fn pane(&mut self, _: usize, _: u16, _: u16) -> Pane {
            Pane::default()
        }
        fn on_action(&mut self, _: Action, _: usize) -> Flow {
            Flow::Continue
        }
    }

    fn host() -> Host {
        Host::new(
            Some("roest1".into()),
            vec![
                ("Repos".into(), Box::new(Fake("r", 40)) as Box<dyn Screen>),
                ("Orgs".into(), Box::new(Fake("o", 5))),
                ("Keys".into(), Box::new(Fake("k", 2))),
            ],
        )
    }

    #[test]
    fn it_delegates_to_the_active_tab() {
        let mut h = host();
        assert_eq!(h.rows().len(), 40);
        h.on_action(Action::NextTab, 0);
        assert_eq!(h.rows().len(), 5);
        assert!(h.footer().starts_with("o keys"));
    }

    /// The strip is a ring. Stopping at the ends makes the last tab the
    /// awkward one, and every other tabbed thing on this machine wraps.
    #[test]
    fn the_strip_wraps_in_both_directions() {
        let mut h = host();
        h.on_action(Action::PrevTab, 0);
        assert_eq!(h.tabs().unwrap().active, 2);
        h.on_action(Action::NextTab, 0);
        assert_eq!(h.tabs().unwrap().active, 0);
    }

    /// The thing `app` cannot do for us. Leaving a 40-row tab at row 37 and
    /// coming back to it must land on row 37, not on row 1 and not on a
    /// clamped position borrowed from the 2-row tab in between.
    #[test]
    fn each_tab_keeps_its_own_cursor() {
        let mut h = host();
        h.focus(37);
        h.on_action(Action::NextTab, 37);
        assert_eq!(h.initial_sel(), 0, "a fresh tab opens at its own choice");
        h.focus(3);
        h.on_action(Action::PrevTab, 3);
        assert_eq!(h.initial_sel(), 37, "came back to the wrong row");
        h.on_action(Action::NextTab, 37);
        assert_eq!(h.initial_sel(), 3);
    }

    /// A one-tab host is not a tab bar: no switching, and no footer line
    /// advertising a key that would do nothing.
    #[test]
    fn a_lone_tab_advertises_no_switch() {
        let mut h = Host::new(
            None,
            vec![("Only".into(), Box::new(Fake("x", 3)) as Box<dyn Screen>)],
        );
        assert_eq!(h.footer(), "x keys");
        assert!(matches!(h.on_action(Action::NextTab, 0), Flow::Continue));
        assert_eq!(h.tabs().unwrap().active, 0);
    }

    /// The layout belongs to the TAB. A host that answered for itself made
    /// `Split::Full` a no-op, which showed up as a table with no names in it
    /// rather than as anything resembling a layout bug.
    #[test]
    fn the_layout_comes_from_the_active_tab() {
        struct Wide;
        impl Screen for Wide {
            fn title(&self) -> String {
                "wide".into()
            }
            fn rows(&mut self) -> Vec<Row> {
                vec![Row::leaf("w")]
            }
            fn footer(&self) -> String {
                String::new()
            }
            fn pane(&mut self, _: usize, _: u16, _: u16) -> Pane {
                Pane::default()
            }
            fn on_action(&mut self, _: Action, _: usize) -> Flow {
                Flow::Continue
            }
            fn split(&self) -> Split {
                Split::Full
            }
        }
        let mut h = Host::new(
            None,
            vec![
                ("Narrow".into(), Box::new(Fake("n", 2)) as Box<dyn Screen>),
                ("Wide".into(), Box::new(Wide)),
            ],
        );
        assert!(matches!(h.split(), Split::ListPane));
        h.on_action(Action::NextTab, 0);
        assert!(matches!(h.split(), Split::Full));
    }

    #[test]
    fn it_can_open_on_a_named_tab() {
        let h = host();
        let i = h.index_of("Keys").expect("named tab");
        assert_eq!(h.opening_on(i).tabs().unwrap().active, 2);
    }
}
