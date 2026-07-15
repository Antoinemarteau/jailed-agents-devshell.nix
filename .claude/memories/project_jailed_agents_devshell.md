---
name: project-jailed-agents-devshell
description: "Nix flake project to run Claude Code and Julia agents sandboxed via jail.nix, with home-manager for dotfiles"
metadata: 
  node_type: memory
  type: project
---

Goal: a nix devShell that opens a tmux session where Claude Code and Julia run inside jail.nix sandboxes.

**Project name: `jailed-agents-devshell.nix`** (chosen 2026-07-15; README h1 updated).

**Why:** Secure agentic coding workflow — agents run isolated, only see what they need.

## Repo layout

```
nix_src/              — the flake (NOT the repo root); untainted, host tools here
  flake.nix           — program-specific: makeJailedClaude/Julia/Kaimon/Shell constructors,
                        their bind sets, Claude<->Kaimon MCP socat legs, domain allowlists,
                        tmux-pkg, devShell assembly
  devshell-home.nix   — home-manager config module (zsh, tmux, direnv), instantiated twice
                        (see below)
  jailed-agents.nix   — generic: makeJailed, mkLauncher, network-allowlist proxy plumbing
                        (tinyproxy launcher, restrictedNetOptions, localhostResolveBinds),
                        common binds (gitReadBinds, nixLdBinds), guardHostTool,
                        new_agent_session/attach_agent_session, host home-manager
                        instantiation (hostHomeManager)
agentshome/           — SINGLE agent-tainted root; also the fake $HOME
  .envrc              — direnv loader (uses ../nix_src)
  projects/           — workspaces jailed agents may run from
  .claude/ .julia/ .config/kaimon/ .cache/kaimon/ — jail-bound agent data
.hosthome/            — host interactive $HOME (zsh/tmux/nvim); never bound into jails
```
Guard (`guardHostTool`, defined in `jailed-agents.nix`, applied in `flake.nix` over
`guardedHostTools`) refuses host dev tools anywhere under `agentshome/` (single check on
`agentHomeDirectory`).

**Refactor (2026-07-14, DONE — see [[feedback_nix_refactor_process]]):** moved from one
`network-restrictions.nix` + monolithic `jailed-agents.nix` to the generic/program-specific
split above. `network-restrictions.nix` no longer exists (merged into `jailed-agents.nix`).
`makeJailed` now takes `exe` (a derivation or literal path, e.g. Kaimon's
`~/.julia/bin/kaimon`) + `extraArgs`/`socatLegs` instead of a pre-built `program`; it
resolves them via `mkLauncher`, which returns `exe` unwrapped when there's nothing to run
first (no legs, no extraArgs) — avoids an unnecessary wrapper script for e.g. `jailed-julia`
(unrestricted) and `jailed-shell`. `proxiedNetwork` (renamed from `restrictNetwork` 2026-07-15)/`allowedDomains` replaced the old
`proxyDomains` — `makeJailed` asserts `network && proxiedNetwork` never both true, and
`allowedDomains == []` whenever `proxiedNetwork = false`. `localhostResolveBinds` is now
applied automatically to every `!network` jail (not just proxy-restricted ones — Kaimon
needs it too, fully offline) instead of being bolted on per-constructor.

## Architecture

Single flake at `nix_src/`. No sub-flakes.

`flake.nix` defines four jailed programs via constructors that call `jailed-agents.nix`'s
generic `makeJailed`:
- `jailed-claude` — Claude Code + claudeConfigWriteBinds
- `jailed-julia` — Julia REPL + juliaDepotWriteBinds + kaimonCacheWriteBinds
- `jailed-kaimon` — Kaimon MCP server + all julia/kaimon binds
- `jailed-shell` — zsh shell with all binds (for debugging), home-manager zsh config

## HOME and bind strategy

Inside every jail:
- `HOME = /home/agents` (set via `set-env "HOME" jailHomeDirectory` in commonJailOptions)
- `USER = agents`
- `tmpfs /home/agents` — writable empty root so programs can create transient files (e.g. lock files)
- Program-specific `rw-bind`s provide all persistent content

Bind variables (program-specific ones now in `flake.nix`, generic ones in `jailed-agents.nix`):
- `claudeConfigWriteBinds` — `.claude/` and `.claude.json` rw (flake.nix)
- `juliaDepotWriteBinds` — `.julia/` rw (flake.nix)
- `kaimonCacheWriteBinds` — `.cache/kaimon/` rw (flake.nix)
- `kaimonConfigWriteBinds` — `.config/kaimon/` rw (flake.nix)
- `gitReadBinds`, `nixLdBinds` — generic (jailed-agents.nix)

## Key invariants

- `assertInDevshell` (now the first add-runtime of each launcher): jailed programs can only run from inside `agentshome/projects/`
- `agentshome/.claude.json` must exist before bwrap runs — `withClaudeConfigInit` does `touch` to ensure it
- `startup.jl` in `agentshome/.julia/config/` auto-installs Revise and Kaimon via `Pkg.Apps.add`
- Kaimon app script (`~/.julia/bin/kaimon`) hardcodes JULIA_LOAD_PATH at install time — if HOME was wrong when installed, delete it and let startup.jl reinstall

## Target platforms

Linux with unprivileged user namespaces. Primary: NixOS.
Ubuntu 24.04+ caveat: must run `sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0` once.

Kaimon↔Claude bridge and network restriction are DONE — see
[[project-network-restriction-impl]].

## tmux panes: env inheritance & direnv (2026-07-13)

Non-obvious, verified empirically: **tmux `new-window`/`split-window` inherit the PATH of
the CLIENT that issues the command** (the terminal you're attached from when you hit the
key), NOT the server-start env and NOT the current pane's live env. So with two parallel
checkouts, a `prefix+C` window created from a shell that has the *other* checkout's devShell
on PATH runs that checkout's `jailed-*` (whose baked `devshellRoot` then fails
`assertInDevshell`). The layout's repl pane is fine because `new_agent_session` (correct env)
created it.

Fix applied: `programs.direnv` (+`nix-direnv`) enabled in `devshell-home.nix` so each pane
self-corrects PATH from its **cwd** regardless of which client made it; `bind C` in the tmux
config now uses `-c '#{@proj}'` so new windows open in the project dir. Rejected the
alternative (per-checkout tmux socket) — it can't fix "attached from a wrong-env shell".
The panes are **host** shells (real UID), so security note added to README: only ever
`direnv allow` the top-level `agentshome/.envrc`; NEVER allow an `.envrc` under `projects/`
(agent-tainted, `mount-cwd` binds project dirs rw) — it would run on the host outside the
sandbox. direnv is deny-by-default (allow-list + content-hash re-block), so the hook itself
runs nothing unapproved; nearest-`.envrc`-wins means an agent-planted `projects/<p>/.envrc`
just shadows the top-level loader and shows as blocked (fail-closed).
