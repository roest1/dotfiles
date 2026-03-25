---
name: GitHub TUI consolidation plan
description: User plans to replace individual gh commands (gpr, ghsecrets, ghbranch, ghenv, gha-ui) with a single unified terminal UI
type: project
---

Riley plans to consolidate gha-ui, gpr, ghsecrets, ghbranch, ghenv into a single command with a navigable terminal UI (like GitHub in the terminal).

**Why:** Current approach is many separate commands; a unified TUI would be more discoverable and polished.

**How to apply:** Don't over-document the individual GitHub commands (bash_roest_git, bash_roest_github) since they will change. Keep docs light on those. When editing these files, be aware the structure will be refactored.
