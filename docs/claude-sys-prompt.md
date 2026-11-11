Claude Code saves a copy of the system prompt in every session's transcript file, so you can read it from disk with no extra tools.

That file isn't the whole picture of what the model receives [Certain]:

- Tool definitions are stored separately (Bash, Edit, Read and so on), and they're much longer than the prompt text itself.
- Some sections only exist in some sessions. The environment details, memory and MCP sections depend on where and how you launch Claude Code, so another session's copy can differ.

The transcripts are under `~/.claude/projects/<folder-name>/<session-id>.jsonl`, one JSON record per line. This function prints the system prompt from your most recent session:

```bash
# Print the system prompt Claude Code sent in the most recent session.
claude-sysprompt() {
    local f
    f=$(ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1)
    [[ -n "$f" ]] || { echo "claude-sysprompt: no transcripts found" >&2; return 1; }
    python3 -I - "$f" <<'EOF'
import sys, json
snap = None
for line in open(sys.argv[1]):
    a = json.loads(line).get("attachment") or {}
    if a.get("type") == "prompt_snapshot":
        snap = a
print("\n\n".join(snap["systemPrompt"]) if snap else "No snapshot found")
EOF
}
```

This works because the transcript file has a section that isn't officially documented. A future update could rename or remove it without notice.
A more stable but more involved method is to route Claude Code's traffic through a local proxy that logs requests, such as mitmproxy, by setting `ANTHROPIC_BASE_URL`.

Author: Claude Code Opus
