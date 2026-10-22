//! What this token may do, asked of the token rather than hard-coded.
//!
//! ## The mechanism
//!
//! Every GitHub API response carries two headers:
//!
//!   X-Oauth-Scopes:          gist, project, read:org, repo
//!   X-Accepted-Oauth-Scopes: admin:public_key, read:public_key, write:public_key
//!
//! The first is what the token HAS. The second is what the endpoint just asked
//! for -- any ONE of them is enough. Both are present on a FAILED response as
//! well as a successful one, which is the whole trick: a denial tells you
//! exactly which scopes would have worked, so nothing here needs a table of
//! "which scope does this endpoint want". There is no table to drift.
//!
//! `gh api -i` prints the headers, and `/rate_limit` is free -- it does not
//! count against the rate limit it reports -- so the token's own scopes cost
//! one cheap call to learn.
//!
//! ## Why a 404 has to be translated
//!
//! `GET /user/keys` without `read:public_key` returns **404 Not Found**, not
//! 403. Rendered literally that is "you have no SSH keys", on an account with
//! two. The lie is deliberate on GitHub's side -- it avoids confirming that
//! something exists to a caller not allowed to see it -- but a screen that
//! repeats it is worse than one that says nothing. So a 404 whose
//! `X-Accepted-Oauth-Scopes` names scopes the token lacks is reported as
//! DENIED, with the fix, and never as empty.
//!
//! ## Why it suggests the narrowest scope
//!
//! Offered `admin:public_key, read:public_key, write:public_key` for a screen
//! that only reads, this suggests `read:public_key`. The broader two would also
//! work, and `gh`'s own error message suggests `admin:public_key` -- it has no
//! idea what the caller intends to do. We do. Writing keys is a later feature
//! and can ask for `write:` when it exists; until then the token this tells you
//! to create cannot delete your SSH keys, which is worth one line of code.

use std::collections::BTreeSet;

/// Scope prefixes in increasing privilege, so the least is preferred.
///
/// GitHub spells the ladder consistently: `read:x`, then `write:x`, then
/// `admin:x`. Anything not on the ladder (`repo`, `gist`, `workflow`) sorts
/// last and is taken as-is -- there is no narrower form of `repo` to prefer.
const LADDER: &[&str] = &["read:", "write:", "admin:"];

fn privilege(scope: &str) -> usize {
    LADDER
        .iter()
        .position(|p| scope.starts_with(p))
        .unwrap_or(LADDER.len())
}

/// The scopes a token carries, parsed from `X-Oauth-Scopes`.
#[derive(Debug, Clone, Default)]
pub struct Granted(BTreeSet<String>);

impl Granted {
    pub fn parse(header: &str) -> Self {
        Self(
            header
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect(),
        )
    }

    pub fn has(&self, scope: &str) -> bool {
        self.0.contains(scope)
    }

    pub fn list(&self) -> Vec<&str> {
        self.0.iter().map(String::as_str).collect()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Does this token satisfy an endpoint that accepts any of `accepted`?
    ///
    /// An EMPTY accepted list means the endpoint named no scope requirement,
    /// which is a pass -- `/user` and `/rate_limit` are both in that case.
    pub fn satisfies(&self, accepted: &[String]) -> bool {
        accepted.is_empty() || accepted.iter().any(|s| self.has(s))
    }
}

/// A request refused for want of a scope, and what to do about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Denied {
    /// Every scope the endpoint said it would accept.
    pub accepted: Vec<String>,
    /// The one to actually ask for: the least privileged that works.
    pub suggest: String,
}

impl Denied {
    /// Build from an endpoint's `X-Accepted-Oauth-Scopes`, if the token is
    /// short of all of them. `None` when the token is fine -- the failure was
    /// something else and must not be dressed up as a permissions problem.
    pub fn from(accepted: &[String], granted: &Granted) -> Option<Self> {
        if accepted.is_empty() || granted.satisfies(accepted) {
            return None;
        }
        let mut ranked = accepted.to_vec();
        ranked.sort_by_key(|s| (privilege(s), s.len()));
        Some(Self {
            suggest: ranked.first().cloned()?,
            accepted: accepted.to_vec(),
        })
    }

    /// The literal command to paste. `gh` prints an equivalent on stderr, but
    /// it suggests the broadest accepted scope; this names the narrowest.
    pub fn fix(&self) -> String {
        format!("gh auth refresh -h github.com -s {}", self.suggest)
    }
}

/// One header's values, split on commas.
pub fn header_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Find a header in a raw `gh api -i` response, case-insensitively.
///
/// `gh` normalises the casing it prints (`X-Oauth-Scopes`, where the HTTP spec
/// and GitHub's docs both say `X-OAuth-Scopes`), so matching exactly on either
/// spelling would work today and break on a `gh` upgrade. Case-insensitive is
/// what the HTTP spec actually promises.
pub fn header<'a>(raw: &'a str, name: &str) -> Option<&'a str> {
    let want = name.to_ascii_lowercase();
    for line in raw.lines() {
        // Headers end at the first blank line; the body may contain anything.
        if line.trim().is_empty() {
            return None;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.trim().to_ascii_lowercase() == want {
            return Some(value.trim());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const GRANTED: &str = "gist, project, read:org, repo";

    #[test]
    fn it_reads_the_headers_case_insensitively() {
        // The casing `gh` actually prints, which is not the casing the docs use.
        let raw = "HTTP/2.0 404 Not Found\r\nX-Oauth-Scopes: gist, repo\r\n\r\n{\"message\":\"x\"}";
        assert_eq!(header(raw, "X-OAuth-Scopes"), Some("gist, repo"));
        assert_eq!(header(raw, "x-oauth-scopes"), Some("gist, repo"));
        assert_eq!(header(raw, "X-Accepted-OAuth-Scopes"), None);
    }

    /// A header name appearing in the BODY must not be read as a header. The
    /// scan stops at the blank line that ends them.
    #[test]
    fn it_stops_at_the_end_of_the_headers() {
        let raw = "HTTP/2.0 200 OK\r\n\r\n{\"X-Oauth-Scopes\": \"admin:org\"}";
        assert_eq!(header(raw, "X-Oauth-Scopes"), None);
    }

    /// The real refusal from `GET /user/keys`, measured on this machine.
    #[test]
    fn a_denial_names_the_narrowest_scope_that_would_work() {
        let granted = Granted::parse(GRANTED);
        let accepted = header_list("admin:public_key, read:public_key, write:public_key");
        let d = Denied::from(&accepted, &granted).expect("denied");
        // Not admin:, which is what gh's own message suggests -- this screen
        // only reads.
        assert_eq!(d.suggest, "read:public_key");
        assert_eq!(d.fix(), "gh auth refresh -h github.com -s read:public_key");
        assert_eq!(d.accepted.len(), 3);
    }

    #[test]
    fn the_gpg_ladder_resolves_the_same_way() {
        let granted = Granted::parse(GRANTED);
        let accepted = header_list("admin:gpg_key, read:gpg_key, write:gpg_key");
        assert_eq!(
            Denied::from(&accepted, &granted).expect("denied").suggest,
            "read:gpg_key"
        );
    }

    /// A scope off the read/write/admin ladder has no narrower form, so it is
    /// suggested as-is rather than being sorted below something unrelated.
    #[test]
    fn a_flat_scope_is_suggested_unchanged() {
        let granted = Granted::parse("read:org");
        let accepted = header_list("repo");
        assert_eq!(
            Denied::from(&accepted, &granted).expect("denied").suggest,
            "repo"
        );
    }

    /// The two cases that must NOT be reported as a permissions problem: an
    /// endpoint that asks for nothing, and one the token already satisfies.
    /// Dressing either up as a scope error sends you to re-authorise a token
    /// that was never the problem.
    #[test]
    fn a_failure_that_is_not_about_scopes_is_not_called_one() {
        let granted = Granted::parse(GRANTED);
        assert_eq!(Denied::from(&[], &granted), None);
        assert_eq!(Denied::from(&header_list("repo, read:org"), &granted), None);
        // And a token with `repo` satisfies an endpoint accepting only `repo`.
        assert!(granted.satisfies(&header_list("repo")));
        // An empty accepted list is a pass, not a block.
        assert!(granted.satisfies(&[]));
    }

    /// An unparseable or missing scopes header leaves us knowing nothing, and
    /// knowing nothing must not read as "has every scope".
    #[test]
    fn an_unknown_token_satisfies_nothing_that_asks() {
        let none = Granted::default();
        assert!(none.is_empty());
        assert!(!none.satisfies(&header_list("repo")));
        assert!(none.satisfies(&[]));
    }
}
