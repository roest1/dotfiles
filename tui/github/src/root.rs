//! The root screen: your repos, grouped by where you filed them.
//!
//! This is the screen the port hangs off. `github` is repo-scoped today --
//! `__gh_repo` is `gh repo view` in the cwd, and every screen inherits that
//! ambient repo -- and the target is account-scoped, because the goal is not
//! opening a browser for anything done weekly. Adding a root later is cheap;
//! threading scope through screens written against an ambient repo is not.
//!
//! It reads the disk and nothing else. No API call happens before the first
//! frame, which is the rule the fzf implementation already follows and the
//! reason it opens instantly. Live data -- open PRs, failing runs, ahead/behind
//! -- fills in after, and is the next increment rather than a missing half:
//! "which of my repos are in what state" is already a question github.com
//! cannot answer, and this answers it offline.

use reticle::{nav::Action, Flow, Pane, Row, Screen};
use std::path::PathBuf;
use std::process::Command;

use crate::index::{self, Remote, Repo};

pub struct Root {
    root: PathBuf,
    repos: Vec<Repo>,
    /// Lane names in display order, with the index of each repo under them.
    lanes: Vec<(String, Vec<usize>)>,
    open: Vec<bool>,
    status: String,
    focus_sel: usize,
    /// The row to open on, answered to `Screen::initial_sel`. Set by
    /// `focused_on`; 0 otherwise.
    start_sel: usize,
}

/// One row's meaning, resolved once so `pane`, `on_action` and `footer` cannot
/// disagree -- the same reason `dots::console::At` exists, and the same bug it
/// was introduced to stop.
enum At {
    Lane(usize),
    Repo(usize),
    Nothing,
}

impl Default for Root {
    fn default() -> Self {
        Self::new()
    }
}

impl Root {
    pub fn new() -> Self {
        Self::rooted(index::root_dir())
    }

    /// The index root injected, for the reason `dots::repo`'s functions take
    /// one: the tests must read a tree they built, not this machine's.
    pub fn rooted(root: PathBuf) -> Self {
        let repos = index::scan(&root);
        let mut lanes: Vec<(String, Vec<usize>)> = Vec::new();
        for (i, r) in repos.iter().enumerate() {
            match lanes.last_mut() {
                // `scan` sorts by lane, so equal lanes are already adjacent and
                // this is a run-length pass rather than a group-by.
                Some((name, ids)) if *name == r.lane => ids.push(i),
                _ => lanes.push((r.lane.clone(), vec![i])),
            }
        }
        // Open on arrival. A tree that starts collapsed makes you press l on
        // every lane to see what you have, on the screen whose entire job is
        // showing you what you have.
        let open = vec![true; lanes.len()];
        Self {
            root,
            repos,
            lanes,
            open,
            status: String::new(),
            focus_sel: 0,
            start_sel: 0,
        }
    }

    /// Select this repo on arrival, opening its lane.
    ///
    /// What `github` run inside a repo does: the seeded stack pushes the repo's
    /// own screen on top, and this is what is underneath it, so `q` lands on
    /// the row you came from rather than at the top of the list.
    pub fn focused_on(mut self, repo: &Repo) -> Self {
        let found = self
            .repos
            .iter()
            .position(|r| r.path == repo.path)
            // A repo outside ~/github has no row here. Matching on identity
            // rather than path then still lands on the right lane if a second
            // clone of it happens to be filed in the index.
            .or_else(|| self.repos.iter().position(|r| r.slug() == repo.slug()));
        let Some(i) = found else {
            return self;
        };
        let lane = self
            .lanes
            .iter()
            .position(|(_, ids)| ids.contains(&i))
            .unwrap_or(0);
        self.open[lane] = true;
        self.start_sel = self.row_of_repo(i).unwrap_or(0);
        self
    }

    fn row_of_repo(&self, target: usize) -> Option<usize> {
        let mut row = 0;
        for (l, (_, ids)) in self.lanes.iter().enumerate() {
            row += 1;
            if self.open[l] {
                for &i in ids {
                    if i == target {
                        return Some(row);
                    }
                    row += 1;
                }
            }
            row += 1; // spacer
        }
        None
    }

    fn at(&self, sel: usize) -> At {
        let mut row = 0;
        for (l, (_, ids)) in self.lanes.iter().enumerate() {
            if sel == row {
                return At::Lane(l);
            }
            row += 1;
            if self.open[l] {
                for &i in ids {
                    if sel == row {
                        return At::Repo(i);
                    }
                    row += 1;
                }
            }
            row += 1; // spacer
        }
        At::Nothing
    }

    /// Distinct GitHub owners in a lane, most-repos-first.
    ///
    /// The first is the lane's expected owner, which is what lets a row stay
    /// quiet when it is the unremarkable case.
    fn lane_owners(&self, l: usize) -> Vec<String> {
        let mut counted: Vec<(String, usize)> = Vec::new();
        for &i in &self.lanes[l].1 {
            if let Remote::GitHub { owner, .. } = &self.repos[i].remote {
                match counted.iter_mut().find(|(o, _)| o == owner) {
                    Some((_, n)) => *n += 1,
                    None => counted.push((owner.clone(), 1)),
                }
            }
        }
        // Stable within equal counts, so the order does not flicker between
        // runs on a lane where two owners are tied.
        counted.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
        counted.into_iter().map(|(o, _)| o).collect()
    }

    /// A row's second column: what is worth saying about THIS repo.
    ///
    /// Not always the slug. On the real tree most rows are `roest1/finpulse`
    /// sitting in a directory called `finpulse` inside a lane whose owner is
    /// already `roest1` — thirteen rows of a column repeating what the row and
    /// its heading both already said, which also pushed the genuinely different
    /// ones off the end of a truncated column. Same principle as the branch
    /// badge: say the unusual thing.
    ///
    ///   the directory was renamed        -> owner/name
    ///   someone else's, in your lane     -> owner/name
    ///   no remote, or not github         -> what it is instead
    ///   filed in a subfolder             -> that subfolder
    ///   otherwise                        -> nothing
    fn repo_detail(&self, l: usize, i: usize) -> String {
        let repo = &self.repos[i];
        match &repo.remote {
            Remote::GitHub { owner, name } => {
                let expected = self.lane_owners(l);
                if *name != repo.dir || expected.first().map(String::as_str) != Some(owner.as_str())
                {
                    repo.slug()
                } else {
                    repo.within.clone()
                }
            }
            _ => repo.slug(),
        }
    }

    /// What a lane is, in one line: who owns what is in it, and how much.
    ///
    /// The owners are the point rather than the count. `orgs/codegig` holding
    /// `codegig-br` repos is the disagreement between path and remote made
    /// visible, and it is the thing you would otherwise have to open a repo to
    /// discover.
    fn lane_detail(&self, l: usize) -> String {
        let ids = &self.lanes[l].1;
        let owners = self.lane_owners(l);
        let owners: Vec<&str> = owners.iter().map(String::as_str).collect();
        let n = ids.len();
        let count = if n == 1 {
            "1 repo".to_string()
        } else {
            format!("{n} repos")
        };
        match owners.len() {
            0 => count,
            1 => format!("{} · {count}", owners[0]),
            // Named rather than counted up to three: "roest1 +2 others" hides
            // exactly the fact this line exists to show.
            2..=3 => format!("{} · {count}", owners.join(", ")),
            k => format!("{}, +{} more · {count}", owners[..2].join(", "), k - 2),
        }
    }

    fn open_in_browser(&mut self, i: usize) -> Flow {
        let Remote::GitHub { owner, name } = &self.repos[i].remote else {
            self.status = "no github remote — nothing to open".into();
            return Flow::Dirty;
        };
        let url = format!("https://github.com/{owner}/{name}");
        // xdg-open on Linux, open on macOS -- the same pair `_open_url` in
        // bash_github picks between. Spawned and forgotten: waiting on it would
        // block the loop for as long as the browser takes to start.
        let opener = if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        };
        match Command::new(opener).arg(&url).spawn() {
            Ok(_) => self.status = format!("opened {url}"),
            Err(e) => self.status = format!("could not run {opener}: {e}"),
        }
        Flow::Dirty
    }
}

impl Screen for Root {
    fn title(&self) -> String {
        "github".into()
    }

    fn focus(&mut self, sel: usize) {
        self.focus_sel = sel;
    }

    fn initial_sel(&self) -> usize {
        self.start_sel
    }

    fn rows(&mut self) -> Vec<Row> {
        if self.lanes.is_empty() {
            return vec![Row::leaf("no clones found").detail(self.root.display().to_string())];
        }
        let mut rows = Vec::new();
        for (l, (name, ids)) in self.lanes.iter().enumerate() {
            let mut r = Row::leaf(name);
            r.group = true;
            r.expanded = self.open[l];
            rows.push(r.detail(self.lane_detail(l)));
            if self.open[l] {
                for &i in ids {
                    let repo = &self.repos[i];
                    let mut r = Row::leaf(&repo.dir);
                    r.depth = 1;
                    let mut r = r.detail(self.repo_detail(l, i));
                    // Badge only what is unusual. A branch badge on every row
                    // would put `main` down the whole column to say nothing;
                    // being on something else is the thing worth seeing from
                    // the list.
                    match repo.branch.as_deref() {
                        Some("main") | Some("master") | None => {}
                        Some(b) => r = r.badged(b, 179),
                    }
                    rows.push(r);
                }
            }
            rows.push(Row::spacer());
        }
        rows
    }

    fn pane(&mut self, sel: usize, _cols: u16, _rows: u16) -> Pane {
        let mut lines: Vec<String> = Vec::new();
        match self.at(sel) {
            At::Lane(l) => {
                let (name, ids) = &self.lanes[l];
                lines.push(name.clone());
                lines.push(String::new());
                lines.push(format!("{}/{}", self.root.display(), name));
                lines.push(String::new());
                lines.push(self.lane_detail(l));
                lines.push(String::new());
                lines.push("Lanes come from where you filed a repo, not from".into());
                lines.push("its remote — a clone of someone else's project".into());
                lines.push("stays where you put it and still shows whose it".into());
                lines.push("is.".into());
                let strays = ids.iter().filter(|&&i| !self.repos[i].is_github()).count();
                if strays > 0 {
                    lines.push(String::new());
                    lines.push(match strays {
                        1 => "One here has no github remote.".to_string(),
                        n => format!("{n} here have no github remote."),
                    });
                }
            }
            At::Repo(i) => {
                let repo = &self.repos[i];
                lines.push(repo.slug());
                lines.push(String::new());
                lines.push(repo.path.display().to_string());
                lines.push(String::new());
                if !repo.within.is_empty() {
                    lines.push(format!("filed under  {}/{}", repo.lane, repo.within));
                } else {
                    lines.push(format!("filed under  {}", repo.lane));
                }
                match repo.branch.as_deref() {
                    Some(b) => lines.push(format!("on           {b}")),
                    None => lines.push("on           no commits yet".into()),
                }
                match &repo.remote {
                    Remote::GitHub { .. } => {}
                    Remote::Elsewhere(host) => {
                        lines.push(String::new());
                        lines.push(format!("origin points at {host}, so the GitHub"));
                        lines.push("screens do not apply to it.".into());
                    }
                    Remote::None => {
                        lines.push(String::new());
                        lines.push("No origin. It is on this disk and nowhere".into());
                        lines.push("else — listed because that is worth knowing,".into());
                        lines.push("not because there is anything to open.".into());
                    }
                }
            }
            At::Nothing => {}
        }
        if !self.status.is_empty() {
            lines.push(String::new());
            lines.push(self.status.clone());
        }
        Pane { image: None, lines }
    }

    fn on_action(&mut self, action: Action, sel: usize) -> Flow {
        self.status.clear();
        match (action, self.at(sel)) {
            (Action::Activate | Action::Open, At::Lane(l)) => {
                self.open[l] = !self.open[l];
                Flow::Dirty
            }
            (Action::Close, At::Lane(l)) => {
                self.open[l] = false;
                Flow::Dirty
            }
            // Interim. The repo's own screens are the next increment, and this
            // is what enter becomes when they exist -- `o` keeps opening the
            // browser after that, the way ctrl-o does in the fzf screens.
            (Action::Activate, At::Repo(i)) | (Action::Key('o'), At::Repo(i)) => {
                self.open_in_browser(i)
            }
            _ => Flow::Continue,
        }
    }

    fn footer(&self) -> String {
        match self.at(self.focus_sel) {
            At::Lane(_) => "enter open/close".into(),
            At::Repo(_) => "enter open on github.com".into(),
            At::Nothing => "j/k move · h/l close/open".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tree(name: &str, repos: &[(&str, &str)]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("github-root-{name}"));
        let _ = fs::remove_dir_all(&root);
        for (rel, origin) in repos {
            let git = root.join(rel).join(".git");
            fs::create_dir_all(&git).expect("mkdir");
            fs::write(git.join("HEAD"), "ref: refs/heads/main\n").expect("HEAD");
            fs::write(
                git.join("config"),
                format!("[remote \"origin\"]\n\turl = {origin}\n"),
            )
            .expect("config");
        }
        root
    }

    fn sample(name: &str) -> Root {
        Root::rooted(tree(
            name,
            &[
                ("public/mdgest", "git@github.com:roest1/mdgest.git"),
                ("public/site", "git@github.com:roest1/site.git"),
                (
                    "orgs/codegig/platform",
                    "git@github.com:codegig-br/platform.git",
                ),
            ],
        ))
    }

    /// Same invariant as `dots`: every selectable index must resolve to the row
    /// actually drawn at it. Lanes collapse, so the mapping moves.
    fn walk_agrees(r: &mut Root) {
        let rows = r.rows();
        for (i, row) in rows.iter().enumerate() {
            if !row.selectable {
                assert!(matches!(r.at(i), At::Nothing), "spacer {i} resolves");
                continue;
            }
            match r.at(i) {
                At::Lane(l) => assert_eq!(row.label, r.lanes[l].0),
                At::Repo(x) => assert_eq!(row.label, r.repos[x].dir),
                At::Nothing => panic!("selectable row {i} ({}) resolves to nothing", row.label),
            }
        }
    }

    #[test]
    fn the_walk_matches_the_rows_open_and_closed() {
        let mut r = sample("walk");
        walk_agrees(&mut r);
        r.open[0] = false;
        walk_agrees(&mut r);
        for o in r.open.iter_mut() {
            *o = false;
        }
        walk_agrees(&mut r);
    }

    /// The disagreement this screen exists to show: the lane is `orgs/codegig`
    /// and the owner is `codegig-br`, and you can see both without opening
    /// anything.
    #[test]
    fn a_lane_names_the_owners_inside_it() {
        let r = sample("detail");
        let orgs = r
            .lanes
            .iter()
            .position(|(n, _)| n == "orgs/codegig")
            .unwrap();
        assert_eq!(r.lane_detail(orgs), "codegig-br · 1 repo");
        let public = r.lanes.iter().position(|(n, _)| n == "public").unwrap();
        assert_eq!(r.lane_detail(public), "roest1 · 2 repos");
    }

    /// Lanes start open. A tree that starts collapsed makes you press `l` on
    /// every lane to see what you have, on the screen whose job is showing you
    /// what you have.
    #[test]
    fn every_lane_starts_open() {
        let mut r = sample("open");
        let labels: Vec<String> = r.rows().iter().map(|x| x.label.clone()).collect();
        assert!(labels.contains(&"mdgest".to_string()));
        assert!(labels.contains(&"platform".to_string()));
    }

    /// `github` inside a repo lands on that repo's row rather than at the top,
    /// so popping back from its screens returns where you came from.
    #[test]
    fn it_can_start_focused_on_the_repo_you_are_standing_in() {
        let r = sample("focused");
        let root = r.root.clone();
        let here = index::current(&root.join("orgs/codegig/platform"), &root).expect("a repo");
        let mut r = r.focused_on(&here);
        let sel = r.initial_sel();
        let rows = r.rows();
        assert_eq!(rows[sel].label, "platform");
    }

    /// A repo cloned outside the index has no row to land on. Falling back to
    /// the top is right; panicking or selecting the wrong row is not.
    #[test]
    fn starting_focused_on_an_unindexed_repo_falls_back_to_the_top() {
        let r = sample("stray");
        let other = tree("stray-src", &[("x", "git@github.com:someone/x.git")]);
        let here = index::current(&other.join("x"), &other).expect("a repo");
        assert_eq!(r.focused_on(&here).initial_sel(), 0);
    }

    #[test]
    fn an_empty_index_says_so_instead_of_drawing_nothing() {
        let empty = std::env::temp_dir().join("github-root-empty");
        let _ = fs::remove_dir_all(&empty);
        fs::create_dir_all(&empty).expect("mkdir");
        let mut r = Root::rooted(empty);
        let rows = r.rows();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].label, "no clones found");
    }

    /// The column earns its place by being quiet. Thirteen rows of
    /// `roest1/<same-name>` under a heading that already says `roest1` is a
    /// column that says nothing while truncating the rows that would have.
    #[test]
    fn a_row_only_names_its_owner_when_that_is_the_surprising_part() {
        let r = Root::rooted(tree(
            "row-detail",
            &[
                ("public/mdgest", "git@github.com:roest1/mdgest.git"),
                ("public/site", "git@github.com:roest1/site.git"),
                // Someone else's, filed in your lane.
                (
                    "public/gods-eye-view",
                    "https://github.com/bilawalsidhu/gods-eye-view.git",
                ),
                // Directory renamed away from the repo name.
                ("public/immich", "git@github.com:roest1/roest-immich.git"),
            ],
        ));
        let l = r.lanes.iter().position(|(n, _)| n == "public").unwrap();
        let detail = |dir: &str| {
            let i = r.repos.iter().position(|x| x.dir == dir).expect(dir);
            r.repo_detail(l, i)
        };
        assert_eq!(detail("mdgest"), "", "the unremarkable case says nothing");
        assert_eq!(detail("site"), "");
        assert_eq!(detail("gods-eye-view"), "bilawalsidhu/gods-eye-view");
        assert_eq!(detail("immich"), "roest1/roest-immich");
    }

    /// A repo filed in a subfolder says where, since the row is only its
    /// basename and two clones can share one.
    #[test]
    fn a_subfoldered_repo_shows_where_it_is_filed() {
        let r = Root::rooted(tree(
            "within",
            &[("private/repos/quant", "git@github.com:roest1/quant.git")],
        ));
        let l = 0;
        let i = r.repos.iter().position(|x| x.dir == "quant").unwrap();
        assert_eq!(r.repo_detail(l, i), "repos");
    }
}
