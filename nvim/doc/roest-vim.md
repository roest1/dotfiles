# How this config works (Stuff I use)

## Commands: <operator> <count> <motion>

- all three are [optional] (2^3 = 8 styles of vim commands)

* `:<count>` (go to line)
* `<motion>`
* `<count><motion>`
* `<operator>[<operator>]` (line-wise)
* `<operator>[<count>]<motion>`
* `<count><operator><motion>`

### Operators

- `d`: delete
- `y`: yank (copy)
- `p` / `P`: put (paste)
- `<` / `>`: change indent (tip: use on selected text and then `.` to apply the indent multiple time)
- `~`: toggle case

### Motions

- `h`: ←
- `j`: ↓
- `k`: ↑
- `l`: →

- `^`: First non-whitespace character
- `0`: Beginning of line
- `9`: End of line
- `w`: Next word (start)
- `e`: Next word (end)
- `b`: Previous word

- `gg`: Beginning of file
- `G`: End of file
- `{` / `}`: Paragraph up / down
- `%`: Jump to matching "()", "{}", "[]"

### Commands I like to use

- `:%y`: Copy all text in a file
- `:term`: Open up terminal in window
- `:term python --args %`: Run current file as python program with args (replace interpreter/compiler)

## Macros

Macros let you record and replay sequences (vim commands)

1. Record: `q<letter>` (ex: "qa" starts recording into register `a`)
2. Do vim commands
3. Stop Recording: `q`

- `@a`: Replay macro from register _a_
- `@@`: Replay last macro

## Window Splits

- `:vsplit` or `:vsp`: Vertical split
- `:split` or `:sp`: Horizontal split
- `<Ctrl>+w` `hjkl`: Move between splits
- `<space>-`: Floating directory nav (see oil)
- `-`: directory nav (see oil)
