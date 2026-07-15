---
name: project-julia-mcp-integration
description: "jailed-julia-mcp: client-launched stdio MCP server in its own jail, socket-activated by the claude jails — DONE, verified live"
metadata: 
  node_type: memory
  type: project
---

julia-mcp (github:aplavin/julia-mcp, pinned as a non-flake input) runs jailed and is
**launched by Claude on demand** — verified live 2026-07-15: `claude-connect-julia-mcp`
then `jailed-claude -p "…factorial(10)…"` → Claude connected, called `julia_eval`,
answered 3628800; listener and socket cleaned up on exit. See [[project_ai_agent_sandboxing]].

**Design (generic machinery in jailed-agents.nix; instantiation in flake.nix; `makeJailed` untouched):**
- julia-mcp is a **stdio** MCP server (FastMCP, official `mcp` SDK): the client spawns it —
  it cannot sit in a separate jail like Kaimon's HTTP bridge. Solution = socket activation:
  the generic `mkServerSocketOptions name serverExe jailSockPath` (jailed-agents.nix;
  instantiated in flake.nix as `juliaMcpServerSocketOptions`, in the claude jails'
  `options`) uses jail.nix's
  `add-runtime` to start a host-side `socat UNIX-LISTEN:$sock,fork EXEC:<jailed-julia-mcp>,pipes`
  listener per instance ($$-keyed), pushes the socket into the jail with
  `RUNTIME_ARGS+=(--bind …)` (the documented mechanism), and `add-cleanup` kills it +
  removes the socket on jail exit. Claude's registered command (user scope):
  `socat - UNIX-CONNECT:~/.cache/julia-mcp-sock/mcp.sock`.
- Each MCP connection spawns a fresh `jailed-julia-mcp` (own tinyproxy, julia allowlist,
  rw `.julia` bind, nixLd binds); it dies when Claude disconnects. Upstream's intended
  lifecycle ("client spawns server"), preserved across the jail boundary.
- **uv is NOT needed** despite upstream README: `uv run` is just their launcher. Nix builds
  the env as `python3.withPackages (ps: [ ps.mcp ])` + `python3 -u ${julia-mcp}/server.py`.

**Hard-won gotchas:**
- `add-runtime`/`add-cleanup` are jail.nix's native host-side-service mechanism (runtime =
  host, pre-bwrap; cleanup = on jail exit, shared var scope, runs even if runtime fails;
  jail.nix drops `exec` before bwrap when cleanups exist). This made a planned `hostLegs`
  makeJailed parameter unnecessary — prefer these combinators for host-side legs.
- `jail-to-host-channel` can NOT carry an MCP session (one-shot single-arg fifo RPC,
  stdout-only, handler respawned per message, runs on the HOST).
- socat `EXEC:…,pipes` (not the socketpair default) so the server sees plain stdio fds;
  `python3 -u` for unbuffered.
- jail.nix in-source `doc` strings are verbatim the website docs (user pasted the site text;
  it matched the store source word-for-word) — cite them when the site is unreachable.
- `agentshome/.cache/julia-mcp-sock` holds per-instance listener sockets → added to
  `forbiddenBindPaths` (same class as `.cache/jail-net`); only the single socket file is
  runtime-bound into the claude jail.
- Cleanup runs via jail.nix `trap cleanup EXIT` (EXIT only): TERM/INT still reach it after
  bwrap returns, but SIGKILL skips it (bwrap itself dies via --die-with-parent; a stale
  socket file may remain — each start `rm -f`s its own). Cleanup lines run under
  writeShellApplication errexit, so every `kill` needs `|| true` or a dead process aborts
  the remaining lines. tinyproxy exits gracefully over ~2s after TERM — not a leak.
- MCP probe over the socket: initialize → notifications/initialized → tools/list or
  tools/call, newline-delimited JSON via `socat - UNIX-CONNECT:…`.
- In Nix strings (both kinds) `$${…}` is LITERAL, not interpolation — to build shell
  `$`-references from a Nix-computed variable name, concat: `v = "_foo"; r = "$" + v;`
  then `${r}_pid` (shellcheck in writeShellApplication catches the mistake at build time).
  `mkServerSocketOptions` keys its shell vars by `name` (`-`/`.` → `_`) so several server
  sockets in one jail can't clobber each other's cleanup state.
