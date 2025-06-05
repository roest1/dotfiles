# tmux

tmux is a terminal multiplexer that lets you run multiple terminal sessions in a single (split) window and save sessions.

## When Should You Use tmux?

- ✅ When you want to run two or more independent terminal processes at once

- ✅ When you want terminal state persistence — you can detach and reattach later without losing work

- 🚫 Use Vim splits (:vsp, :sp) when all the activity is inside Vim, like viewing and editing multiple files

### 1. Start tmux

```sh
tmux
```

In tmux, hit the prefix key in order to run any tmux commands. By default, the prefix key is Ctrl-b.

### 2. Split Windows

Horizontal split:

```sh
<prefix-key> "
```

Vertical split:

```sh
<prefix-key> %
```

### 3. Navigate Windows

Use the arrow keys: ← ↑ → ↓

```sh
<prefix-key><arrow-key>
```

### 4. Resizing Windows

Just like navigating we use the arrow keys, but hold down Ctrl

```sh
<prefix-key>Ctrl<arrow-key>
```

### 5. Detach & Reattach

You can exit a tmux session by typing:

```sh
<prefix-key>d
```

You can enter the previous session by typing:

```sh
<prefix-key>attach
```

### 6. Session Tracking

Once inside a tmux session, you can rename the session by typing:

```sh
<prefix-key>:rename-session <name>
```

To list all open sessions:

```sh
tmux ls
```

You can open up a specific tmux session by specifying the session name:

```sh
tmux attach -t <name>
```

### 7. Terminating Sessions

While _inside_ a tmux session, you can terminate it by running:

```sh
exit
```

until all windows are closed and the session is terminated.

To kill a specific session while _outside_ tmux, you can run:

```sh
tmux kill-session -t <name>
```

To kill all sessions, you can run:

```sh
tmux kill-server
```

**Warning**: You will not be able to gain back access to a session if you terminate using any of these strategies. Use `<prefix-key>d` if you want to save the session for later.
