> **The original design sketch, kept for reference.** Written before any of it
> existed, so it describes what was wanted rather than what was built — and the
> two differ in places the building settled (Issues and a Security tab are not
> there; the hub it implies was dropped; `Tab` moved the tabs here and does
> nothing in the real thing). What was actually built, and why each difference
> happened: [`decisions/github-tui.md`](decisions/github-tui.md), with the
> record of what the port chose not to carry in
> [`decisions/github-parity.md`](decisions/github-parity.md).

# Design Doc for GitHub TUI

`github` command enters the TUI.

Either you're currently in a git repository, or you're not.
This tool will first try to open at the repo level, and if not in a git repo, will open at the user level.

Let's say I open up this repo and start the `github` tui:

```bash
cd dotfiles && github
```

This is what I imagine showing:

```
**[Branches]** | [Issues] | [PRs] | [Actions] | [Security and Quality] | [Settings]
-----------------------------------------------------------------------------------
# Default
[ <branch-name> [Protection Rules (lock logo if branch has protection rules)]       <last-updated>  [check-status] --(behind)--|++(ahead)++ [PR] [Trash can (delete) [three-dots (open up new PR or rename branch)] ]

# Your branches
[ <branch-name> [Protection Rules (lock logo if branch has protection rules)]       <last-updated>  [check-status] --(behind)--|++(ahead)++ [PR] [Trash can (delete) [three-dots (open up new PR or rename branch)] ]
...

# All branches
[search bar (lookup branch name, PR #, filter by author)]
[ <branch-name> [Protection Rules (lock logo if branch has protection rules)]       <last-updated>  [check-status] --(behind)--|++(ahead)++ [PR] [Trash can (delete) [three-dots (open up new PR or rename branch)] ]
...

-----------------------------------------------------------------------------------
```

```
[Branches] | **[Issues]** | [PRs] | [Actions] | [Security and Quality] | [Settings]
-----------------------------------------------------------------------------------
Issues (shows all issues)                       | [x] open [] closed [search bar] [sort by (created on or last updated; oldest or newest)] [new issue]
Created by (dropdown users - me at the top)     |
Assigned to (dropdown users - me at the top)    | [ ] <nothing, or "X / total selected"> (toggle all) [mark as (open, complete, not planned) to toggled issues] [label (drop down to assign label to toggled issues)] [assign (drop down to assign user to toggled issues)]
Labels (dropdown all labels)                    | [ ] <open|complete|not planned icon> <issue-name> <title> <creator> <created on>
                                                | ...
                                                |
                                                |
                                                |
                                                |
                                                |
                                                |
-----------------------------------------------------------------------------------
```

> created by and assigned to drop downs auto select me (at the top) when toggling the drop down. Collapsing the drop down, doesn't untoggle users.
> If I want to see `assigned to` for users other than myself, I would hit enter once on [assigned to], then down one row would be my user default selected, but since I want to see assigned to someone else, I hit enter on my row, and deselect myself, and continue arrowing down to select the users I want to select. Then a navigate to the left, brings the cursor to the title row (assinged to) and then with [enter] keyed, the dropdown collapses with the selections in tact.
> This is the behavior I want on this sidebar options that drop down users. For created by and assigned to, in the issues tab, and the created by and assigned to in the PRs tab. and so on where prevalent.

```
[Branches] | [Issues] | **[PRs]** | [Actions] | [Security and Quality] | [Settings]
-----------------------------------------------------------------------------------
PRs (shows all PRs)                             | [x] open <count> [] closed <count> [search bar] [sort by (created on or last updated; oldest or newest)] [new PR]

Created by (dropdown users - me at the top)     |
Assigned to (dropdown users - me at the top)    | [ ] <nothing, or "X / total selected"> (toggle all) [mark as (closed, archived, unarchived) to toggled PRs] [label (drop down to assign label to toggled PRs)] [assign (drop down to assign user to toggled PRs)]

Involves _ (dropdown users - me at the top)     | [ ] <open|closed|merged icon> <PR-title> <creator> <created on> <review required?> <checks passing (like ps1)>

Review Requests                                 |
Labels (dropdown all labels)                    |
                                                |
                                                |
                                                |
                                                |
                                                |
                                                |
-----------------------------------------------------------------------------------
```

Contrast to opening outside of a repo:

```bash
cd ~
```

something that starts from user level, so user settings, credentials, keys, integrations, etc.
be able to go into enterprises, organizations, or personal repos. Full priveleges.
