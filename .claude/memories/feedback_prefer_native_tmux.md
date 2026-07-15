---
name: feedback-prefer-native-tmux
description: Prefer native tmux mechanisms over custom shell parsing for session layout
metadata: 
  node_type: memory
  type: feedback
---

When externalizing the tmux session layout, the user rejected a custom shell loop that parsed a data file and asked "is there any native tmux way to do this?" — favor built-in tool mechanisms over reinventing them in shell.

**Why:** Native tmux config is more expressive (splits/layouts/options), familiar syntax, and needs no bespoke parser.

**How to apply:** The session layout lives in a runtime-read `${devshellRoot}/${devshellHomeFolder}/.config/tmux/default-session.conf` (i.e. `agentshome/.config/tmux/default-session.conf`, alongside home-manager's tmux.conf symlink) written in plain tmux commands. The shellHook does: `new-session -d -c "$_cwd"` → `set-option -t "$_session" @proj "$_cwd"` → `source-file -t "$_session:" <file>` → `attach`. Key facts verified empirically: `source-file -t sess:` scopes all bare inner commands to that session (safe on the shared `-L julia_agents` server); a bare `new-window` does NOT inherit the session start dir (uses the server's launch dir), so layout lines use `new-window -c "#{@proj}"` where `@proj` is a per-session user option carrying the project dir. Related: [[feedback_tmux_config_file]], [[project_jailed_agents_devshell]].
