---
name: feedback_multiple_tmux_sessions
description: Support multiple concurrent tmux sessions — new_agent_session must not kill-server
metadata: 
  node_type: memory
  type: feedback
---

`new_agent_session` must reset only the same-named session (`kill-session -t
"=$_session"`), never `kill-server` on the `julia_agents` socket. The user runs
several project sessions concurrently on that shared server.

**Why:** killing the whole server to refresh server-global state (default-terminal,
ZDOTDIR, PATH — which `-f tmux.conf` only applies at server birth) would tear down
every other session.

**How to apply:** if stale server-global config is a concern, refresh it in place
(re-`source-file` tmux.conf / re-`set-environment -g`) instead of killing the server.
Never tie a server/session kill to the flake `shellHook` or direnv activation — that
fires on every `cd` (panes have direnv too) and would kill live sessions; the repo
keeps `shellHook` empty by design. See [[feedback_prefer_native_tmux]],
[[feedback_tmux_config_file]].
