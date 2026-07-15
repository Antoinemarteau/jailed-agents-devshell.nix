---
name: feedback-claude-credentials
description: "Claude Code credentials are at ~/.claude/.credentials.json, not ~/.claude.json"
metadata: 
  node_type: memory
  type: feedback
---

Claude Code needs BOTH files to avoid re-authentication on every jail restart:
- `~/.claude.json` — main configuration/session file at HOME level (required)
- `~/.claude/.credentials.json` — separate credentials file inside the config dir

**Why:** Confirmed by running Claude inside the jail — without `~/.claude.json`, Claude treats every session as a fresh install and prompts for theme setup. The `.credentials.json` inside `~/.claude/` is a separate file.

**How to apply:** On the host, `.claude.json` lives **inside** `$JAILED_CLAUDE_CONFIG` (i.e. at `$JAILED_CLAUDE_CONFIG/.claude.json`). Two binds are needed:
1. `rw-bind "$JAILED_CLAUDE_CONFIG" ~/.claude` — covers the config dir including `.credentials.json`
2. `rw-bind "$JAILED_CLAUDE_CONFIG/.claude.json" ~/.claude.json` — re-binds the same host file to the HOME-level path where Claude looks for it

In the jail this makes `.claude.json` visible at both `~/.claude/.claude.json` (from the dir bind) and `~/.claude.json` (from the file bind); both are the same underlying host file. Harmless — Claude only reads the HOME-level one.

Both host paths must exist before bwrap or `rw-bind` errors out; a wrapper does `mkdir -p "$JAILED_CLAUDE_CONFIG"` and `touch "$JAILED_CLAUDE_CONFIG/.claude.json"` before invoking the inner jail. `try-rw-bind` is not a substitute — see [[project-srt-network-restriction]].
