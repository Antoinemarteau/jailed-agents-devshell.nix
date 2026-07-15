# Accumulated Claude Code knowledge

Memory files written by Claude Code while developing this repository, committed
so that anyone personalizing their copy (or pointing their own Claude at it) can
reuse the accumulated context. `<devshellRoot>` stands for the repo checkout path.

- `project_jailed_agents_devshell.md` — architecture overview: devShell, jails, tmux session, the two-home split.
- `project_network_restriction_impl.md` — the network-allowlist implementation (empty netns + tinyproxy + ip2unix) and its hard-won gotchas, including the never-bind-`.cache/jail-net` invariant.
- `security_review_reports.md` — security-review findings by git range, with the threat model and what was cleared or flagged.
- `feedback_*.md` — working conventions for coding sessions in this repo: idiomatic Nix, no symlinks in derivations, tiny drvPath-verified refactor steps, comment/prose style, tmux session mechanics.
- `project_julia_mcp_integration.md` — jailed julia-mcp: client-launched stdio MCP server, socket-activated by the claude jails (add-runtime/add-cleanup pattern).
