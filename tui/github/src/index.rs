//! The local index: every clone under `~/github`, read from disk.
//!
//! This is the root screen's data, and it is deliberately the FILESYSTEM
//! rather than the API. Three reasons, in order of how much they matter:
//!
//!   * It is the repos actually cared about. `gh repo list` returns everything
//!     the account can see, which on an account in several orgs is mostly
//!     noise; a clone on this disk is a statement of intent.
//!   * It costs microseconds and no network, so the screen opens instantly and
//!     works on a plane. Live data fills in after, which is the rule the fzf
//!     implementation already follows.
//!   * It is the only thing that knows WHERE a repo is, which is what you
//!     actually want when the next thing you do is cd into it.
//!
//! ## Path and remote disagree, and both are needed
//!
//! Measured against the real tree before any of this was written, because the
//! obvious design — parse `~/github/<org>/<repo>` — is wrong here in four
//! separate ways:
//!
//!   ~/github/orgs/codegig/...          the GitHub org is `codegig-br`
//!   ~/github/orgs/codegig/clients/shell/atlas   depth is not fixed
//!   ~/github/private/repos/jarvis-project/gods-eye-view   owner `bilawalsidhu`
//!   ~/github/private/repos/roest-immich          no remote at all
//!
//! So the path cannot give identity, and the remote cannot give grouping: the
//! third case would file someone else's clone under its own owner heading, and
//! the fourth has no owner to file under. What each one actually knows is
//! different, and the split is the design:
//!
//!   the PATH says what it is TO YOU  — your public work, your private work,
//!                                      an org you do work for
//!   the REMOTE says what it IS       — owner/name on GitHub, or nothing
//!
//! Rows are therefore grouped by the on-disk lane and labelled with the
//! resolved `owner/name`. A clone of someone else's project stays filed where
//! you put it, and still shows whose it is.

use std::fs;
use std::path::{Path, PathBuf};

/// How deep to look for a clone below `~/github`.
///
/// Five is the deepest real one measured (`orgs/codegig/clients/shell/atlas`);
/// six leaves a level of headroom. A limit at all is what stops one
/// `node_modules` with a vendored `.git` from turning a startup read into a
/// filesystem crawl -- descent also stops at every repo found, so the cost is
/// bounded by how you file things rather than by what is inside them.
const MAX_DEPTH: usize = 6;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Remote {
    /// `owner/name` on github.com.
    GitHub { owner: String, name: String },
    /// A remote pointing somewhere else. Kept rather than dropped: a repo that
    /// is on this disk but not on GitHub is a fact about the machine, and
    /// silently omitting it makes the index look like it missed something.
    Elsewhere(String),
    /// No `origin`. Local-only, or a clone whose remote was removed.
    None,
}

#[derive(Debug, Clone)]
pub struct Repo {
    /// Directory name -- what you would `cd` to.
    pub dir: String,
    /// The lane it is filed under, relative to the index root: `public`,
    /// `private`, `orgs/codegig`. The grouping key.
    pub lane: String,
    /// Everything between the lane and the repo, `repos/jarvis-project` for
    /// `private/repos/jarvis-project/J.A.R.V.I.S.`. Empty for a repo sitting
    /// directly in its lane. Shown in the pane, not the row -- it disambiguates
    /// two clones with the same basename without widening every row for the
    /// case that does not have one.
    pub within: String,
    pub path: PathBuf,
    pub remote: Remote,
    /// From `.git/HEAD`. `None` for an unborn branch (a fresh `git init`).
    pub branch: Option<String>,
}

impl Repo {
    /// `owner/name` when GitHub knows it, and something honest when it does not.
    pub fn slug(&self) -> String {
        match &self.remote {
            Remote::GitHub { owner, name } => format!("{owner}/{name}"),
            Remote::Elsewhere(host) => format!("not github — {host}"),
            Remote::None => "local only".into(),
        }
    }

    pub fn is_github(&self) -> bool {
        matches!(self.remote, Remote::GitHub { .. })
    }
}

/// Where the clones live. `GITHUB_DIR` overrides, for the same reason
/// `DOTFILES_SECTIONS_FILE` does: it is how this is tested, and a machine that
/// files elsewhere should not be told it has no repos.
pub fn root_dir() -> PathBuf {
    if let Some(d) = std::env::var("GITHUB_DIR").ok().filter(|s| !s.is_empty()) {
        return PathBuf::from(d);
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join("github")
}

/// Every clone under `root`, sorted: your own lanes first, then orgs.
///
/// One rule rather than a special case per lane -- what you file yourself comes
/// before work you do for someone else, and `orgs/` is the only marker of the
/// difference the tree actually carries.
pub fn scan(root: &Path) -> Vec<Repo> {
    let mut out = Vec::new();
    walk(root, root, 0, &mut out);
    out.sort_by(|a, b| {
        let key = |r: &Repo| {
            (
                r.lane.starts_with("orgs/") || r.lane == "orgs",
                r.lane.to_lowercase(),
                r.within.to_lowercase(),
                r.dir.to_lowercase(),
            )
        };
        key(a).cmp(&key(b))
    });
    out
}

fn walk(dir: &Path, root: &Path, depth: usize, out: &mut Vec<Repo>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut kids: Vec<PathBuf> = Vec::new();
    for e in entries.flatten() {
        let path = e.path();
        if !path.is_dir() {
            continue;
        }
        let name = e.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            continue;
        }
        kids.push(path);
    }
    for path in kids {
        // A repo stops the descent. Anything inside it is its own business --
        // a vendored dependency with a .git is not a repo you filed here.
        if let Some(repo) = read_repo(&path, root) {
            out.push(repo);
            continue;
        }
        walk(&path, root, depth + 1, out);
    }
}

/// Read one directory as a repo, or decide it is not one.
///
/// `.git` as a FILE is a worktree or a submodule -- it holds `gitdir: <path>`
/// pointing at the real store. Skipped rather than followed: neither is a clone
/// you filed here, and following it would list the same repo twice.
fn read_repo(path: &Path, root: &Path) -> Option<Repo> {
    let gitdir = path.join(".git");
    if !gitdir.is_dir() {
        return None;
    }
    let rel = path.strip_prefix(root).ok()?;
    let mut parts: Vec<String> = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect();
    let dir = parts.pop()?;
    // `orgs` alone is a container, not a lane: the lane is the org under it, so
    // two orgs do not collapse into one heading.
    let lane_len = if parts.first().map(String::as_str) == Some("orgs") {
        2
    } else {
        1
    };
    let lane = if parts.is_empty() {
        String::new()
    } else {
        parts[..lane_len.min(parts.len())].join("/")
    };
    let within = parts
        .get(lane_len.min(parts.len())..)
        .map(|w| w.join("/"))
        .unwrap_or_default();

    Some(Repo {
        dir,
        lane,
        within,
        remote: read_remote(&gitdir),
        branch: read_branch(&gitdir),
        path: path.to_path_buf(),
    })
}

/// `origin`'s URL, read straight out of `.git/config`.
///
/// Parsed here rather than shelled to `git config`: the index reads every repo
/// on the machine at startup, and 27 process spawns is the difference between
/// an instant screen and a visible one. The format is stable and the parse is
/// three lines.
fn read_remote(gitdir: &Path) -> Remote {
    let Ok(text) = fs::read_to_string(gitdir.join("config")) else {
        return Remote::None;
    };
    let mut in_origin = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with('[') {
            in_origin = line.replace(char::is_whitespace, "") == "[remote\"origin\"]";
            continue;
        }
        if !in_origin {
            continue;
        }
        if let Some(url) = line.strip_prefix("url") {
            if let Some(url) = url.trim_start().strip_prefix('=') {
                return parse_remote(url.trim());
            }
        }
    }
    Remote::None
}

/// Both URL shapes on this machine, plus the ssh:// long form.
///
///   git@github.com:owner/repo.git
///   https://github.com/owner/repo.git
///   ssh://git@github.com/owner/repo
pub fn parse_remote(url: &str) -> Remote {
    if url.is_empty() {
        return Remote::None;
    }
    // Split host from path without a URL crate: everything here is one of three
    // shapes, and the scp-like form is not a URL at all so a parser would have
    // to special-case it anyway.
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .or_else(|| url.strip_prefix("ssh://"))
        .unwrap_or(url);
    let rest = rest.split_once('@').map_or(rest, |(_, r)| r);
    let (host, path) = match rest.split_once([':', '/']) {
        Some(p) => p,
        None => return Remote::Elsewhere(rest.to_string()),
    };
    if !host.eq_ignore_ascii_case("github.com") {
        return Remote::Elsewhere(host.to_string());
    }
    let path = path.trim_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let mut it = path.split('/').filter(|s| !s.is_empty());
    match (it.next(), it.next()) {
        (Some(owner), Some(name)) => Remote::GitHub {
            owner: owner.to_string(),
            name: name.to_string(),
        },
        // github.com with nothing usable after it -- a truncated or hand-edited
        // remote. Reported as elsewhere rather than as a GitHub repo with an
        // empty name, which would render as a row pointing at `/`.
        _ => Remote::Elsewhere(host.to_string()),
    }
}

/// The checked-out branch, from `.git/HEAD`.
///
/// A file read, not `git branch --show-current`, for the reason `read_remote`
/// is: this runs once per repo at startup. A detached HEAD holds a raw sha and
/// is reported short rather than as a branch, because calling a sha a branch is
/// the kind of small lie that gets believed.
fn read_branch(gitdir: &Path) -> Option<String> {
    let head = fs::read_to_string(gitdir.join("HEAD")).ok()?;
    let head = head.trim();
    match head.strip_prefix("ref: refs/heads/") {
        Some(b) if !b.is_empty() => Some(b.to_string()),
        _ if head.len() >= 7 && head.chars().all(|c| c.is_ascii_hexdigit()) => {
            Some(format!("detached at {}", &head[..7]))
        }
        _ => None,
    }
}

/// The repo the shell is standing in, if any -- walked UP from `cwd`.
///
/// Offline and file-only, deliberately. `gh repo view` is an API call, so using
/// it here would put a network round trip in front of the first frame of a
/// screen whose whole claim is that it opens instantly. It also answers wrongly
/// on a plane.
///
/// Not restricted to the index: a repo cloned outside `~/github` is still the
/// repo you are standing in, and refusing to recognise it would be surprising
/// in exactly the situation where you most want the tool.
pub fn current(cwd: &Path, root: &Path) -> Option<Repo> {
    let mut here = cwd.to_path_buf();
    loop {
        if here.join(".git").is_dir() {
            // Relative to the index when it lives there, so it lands in the
            // right lane; relative to its own parent when it does not, so the
            // lane is at least the directory holding it.
            let base = if here.starts_with(root) {
                root
            } else {
                here.parent()?
            };
            return read_repo(&here, base);
        }
        if !here.pop() {
            return None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_reads_both_url_shapes_this_machine_actually_uses() {
        assert_eq!(
            parse_remote("git@github.com:codegig-br/codegig-platform.git"),
            Remote::GitHub {
                owner: "codegig-br".into(),
                name: "codegig-platform".into()
            }
        );
        assert_eq!(
            parse_remote("https://github.com/roest1/quant.git"),
            Remote::GitHub {
                owner: "roest1".into(),
                name: "quant".into()
            }
        );
        assert_eq!(
            parse_remote("ssh://git@github.com/roest1/ideas"),
            Remote::GitHub {
                owner: "roest1".into(),
                name: "ideas".into()
            }
        );
    }

    /// A repo on this disk that is not on GitHub is a fact about the machine.
    /// Dropping it would make the index look like it had missed something.
    #[test]
    fn a_non_github_or_missing_remote_is_kept_and_named() {
        assert_eq!(
            parse_remote("git@gitlab.com:someone/thing.git"),
            Remote::Elsewhere("gitlab.com".into())
        );
        assert_eq!(parse_remote(""), Remote::None);
        // github.com with nothing usable after it is not a repo at `/`.
        assert!(matches!(
            parse_remote("https://github.com/"),
            Remote::Elsewhere(_)
        ));
    }

    fn tree(name: &str, repos: &[(&str, Option<&str>)]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("github-index-{name}"));
        let _ = fs::remove_dir_all(&root);
        for (rel, origin) in repos {
            let git = root.join(rel).join(".git");
            fs::create_dir_all(&git).expect("mkdir");
            fs::write(git.join("HEAD"), "ref: refs/heads/main\n").expect("HEAD");
            if let Some(url) = origin {
                fs::write(
                    git.join("config"),
                    format!("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = {url}\n"),
                )
                .expect("config");
            }
        }
        root
    }

    /// The four shapes measured on the real tree, which is what this parser was
    /// written against. If the lane rule regresses, someone else's clone starts
    /// appearing under its own heading instead of where it was filed.
    #[test]
    fn lanes_come_from_the_path_and_identity_from_the_remote() {
        let root = tree(
            "lanes",
            &[
                ("public/mdgest", Some("git@github.com:roest1/mdgest.git")),
                (
                    "orgs/codegig/clients/shell/atlas",
                    Some("git@github.com:codegig-br/atlas.git"),
                ),
                (
                    "private/repos/jarvis-project/gods-eye-view",
                    Some("https://github.com/bilawalsidhu/gods-eye-view.git"),
                ),
                ("private/repos/roest-immich", None),
            ],
        );
        let repos = scan(&root);
        assert_eq!(repos.len(), 4);

        let by = |d: &str| repos.iter().find(|r| r.dir == d).expect(d).clone();

        // Directory name is `codegig`; the org is `codegig-br`. Both survive.
        let atlas = by("atlas");
        assert_eq!(atlas.lane, "orgs/codegig");
        assert_eq!(atlas.within, "clients/shell");
        assert_eq!(atlas.slug(), "codegig-br/atlas");

        // Someone else's clone stays where it was filed rather than becoming
        // its own owner heading.
        let theirs = by("gods-eye-view");
        assert_eq!(theirs.lane, "private");
        assert_eq!(theirs.slug(), "bilawalsidhu/gods-eye-view");

        let mine = by("mdgest");
        assert_eq!(mine.lane, "public");
        assert_eq!(mine.within, "");
        assert_eq!(mine.branch.as_deref(), Some("main"));

        let local = by("roest-immich");
        assert_eq!(local.slug(), "local only");
        assert!(!local.is_github());
    }

    /// Your own filing before work you do for someone else -- one rule, and the
    /// only distinction the tree actually carries.
    #[test]
    fn own_lanes_sort_before_org_lanes() {
        let root = tree(
            "sorting",
            &[
                ("orgs/aaa/one", Some("git@github.com:aaa/one.git")),
                ("public/zzz", Some("git@github.com:roest1/zzz.git")),
            ],
        );
        let repos = scan(&root);
        assert_eq!(repos[0].dir, "zzz");
        assert_eq!(repos[1].dir, "one");
    }

    /// Descent stops at a repo. Without this a single vendored `.git` turns the
    /// startup read into a crawl of everything inside it.
    #[test]
    fn a_repo_inside_a_repo_is_not_indexed() {
        let root = tree(
            "nested",
            &[("public/outer", Some("git@github.com:roest1/outer.git"))],
        );
        let inner = root.join("public/outer/vendor/dep/.git");
        fs::create_dir_all(&inner).expect("mkdir");
        fs::write(inner.join("HEAD"), "ref: refs/heads/main\n").expect("HEAD");

        let repos = scan(&root);
        assert_eq!(repos.len(), 1);
        assert_eq!(repos[0].dir, "outer");
    }

    #[test]
    fn a_detached_head_is_not_reported_as_a_branch() {
        let root = tree("detached", &[("public/x", Some("git@github.com:r/x.git"))]);
        fs::write(
            root.join("public/x/.git/HEAD"),
            "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432\n",
        )
        .expect("HEAD");
        let repos = scan(&root);
        assert_eq!(repos[0].branch.as_deref(), Some("detached at 9f8e7d6"));
    }

    /// A repo cloned outside ~/github is still the repo you are standing in.
    /// Refusing to recognise it fails exactly where the tool is most wanted.
    #[test]
    fn current_walks_up_and_works_outside_the_index() {
        let root = tree("current", &[("public/x", Some("git@github.com:r/x.git"))]);
        let deep = root.join("public/x/a/b");
        fs::create_dir_all(&deep).expect("mkdir");
        let found = current(&deep, &root).expect("walks up to the repo");
        assert_eq!(found.dir, "x");
        assert_eq!(found.lane, "public");

        let outside = tree(
            "outside",
            &[("elsewhere/y", Some("git@github.com:r/y.git"))],
        );
        let found = current(&outside.join("elsewhere/y"), &root).expect("still found");
        assert_eq!(found.dir, "y");

        assert!(current(&std::env::temp_dir(), &root).is_none());
    }
}
