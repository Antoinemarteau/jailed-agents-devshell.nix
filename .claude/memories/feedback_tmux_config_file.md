---
name: feedback-tmux-config-file
description: Use -f config_file with tmux start-server to set default-shell and env vars atomically
metadata: 
  node_type: memory
  type: feedback
---

When setting `default-shell` or global environment variables on an isolated tmux server (via `tmux -L`), use a config file passed with `-f` to `start-server`, not separate `set-option`/`set-environment` commands afterward.

**Why:** `tmux start-server` exits immediately when there are no sessions (`exit-empty on` by default). Any subsequent `set-option` or `set-environment` call fails with "no server running" because the server is already gone. The `-f config_file` flag applies the options atomically at server start before the exit check.

**How to apply:** Generate the config with `pkgs.writeText` in Nix, include `set-option -g exit-empty off`, `set-option -g default-shell <zsh>`, and `set-environment -g ZDOTDIR <path>`. Then in the shellHook: `tmux -L server-name -f ${tmuxConf} start-server` followed directly by `tmux -L server-name new-session`.
