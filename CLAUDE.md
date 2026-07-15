# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A reproducible, sandboxed agentic-coding environment for Julia projects on Linux, built
entirely with Nix. It runs Claude Code, a Julia REPL, and the Kaimon CLI each inside its
own Linux user namespace (bubblewrap, via [jail.nix](https://sr.ht/~alexdavid/jail.nix/)),
orchestrated in a tmux session. The host stays unprivileged while a sandboxed agent can be
given full privilege. There is **no automated test suite**; changes are verified by Nix
evaluation and by launching a session (see Commands).

## Repository layout

- `nix_src/` — all the Nix code (this is a flake living in a
  subdirectory, not the repo root):
  - `flake.nix` — the `devShell`. The `let` block holds the config vars; **`devshellRoot`
    must be set to the absolute path of the repo checkout** (edited per clone; a trailing
    slash is tolerated). Assembles the jailed-agent wrappers and the `new_agent_session`
    launcher into the shell's `packages`.
  - `jailed-agents.nix` — the generic sandbox machinery (see Architecture): `makeJailed`,
    common binds, the network-allowlist proxy plumbing, `new_agent_session` /
    `attach_agent_session`, and the host home-manager instantiation.
  - `devshell-home.nix` — a home-manager config (tmux, zsh, julia) activated into
    `.hosthome/` — the **host** interactive `$HOME`, never bound into the jails.
- `.hosthome/` — the interactive devshell home (home-manager activated): the zsh/tmux/nvim
  config for the tmux panes you attach to, plus `.config/tmux/default-session.conf` (the
  user-editable runtime tmux layout). Host-only; kept out of every jail. Mostly git-ignored.
- `agentshome/` — the single **agent-tainted root**, and the fake `$HOME` partially
  bind-mounted into the sandboxes. Holds the jail-bound agent data (`.claude/` credentials,
  `.config/kaimon/`, `.julia/`, `.cache/kaimon/`), the `.envrc` direnv loader (see Commands),
  and `projects/`. Mostly git-ignored.
- `agentshome/projects/` — where actual dev projects live. Jailed agents and
  `new_agent_session` **refuse to run outside it**.
- `DEVNOTES.ms` — sops/age recipe for encrypting the agent's Claude credentials so they can
  be committed. `kaimon.md` — how to wire Claude Code to a Kaimon.jl MCP server.
- `.claude/memories/` — knowledge accumulated by past Claude Code sessions on this repo
  (architecture, network-restriction gotchas, security-review reports, working
  conventions); read the relevant file before touching the corresponding area.

## Commands

Enter the environment (puts the sandboxed tools on `PATH`; does **not** start a session):
```bash
cd agentshome/projects/<project>   # tools load via direnv anywhere under agentshome/
direnv allow                       # once, picks up agentshome/.envrc
# or, without direnv:
nix develop ./nix_src
```

Start (or reset) a tmux dev session — the single explicit entry point, run from within a
project under `agentshome/projects/`:
```bash
new_agent_session
```

Tools available on `PATH` inside the env:
- `jailed-claude`, `yolo-jailed-claude` — sandboxed Claude Code (the latter with `--dangerously-skip-permissions`).
- `jailed-kaimon`, `jailed-julia` (egress restricted to the Julia registries), `yolo-jailed-julia` (full network), `jailed-shell` — the jails.
- `claude-connect-kaimon` — one-shot helper to register the Kaimon MCP server in Claude.
- **Guarded** host tools (`git`, `gh`, `julia`, `claude`, `kaimon`, `make`, `python`, `pip`,
  `uv`, `conda`, `node`, `npm`, `docker`, `apt` — full list is `guardedHostTools` in
  `flake.nix`): they refuse to run when cwd is anywhere under the agent-tainted `agentshome/`
  tree and defer to the real tool elsewhere. Footgun-reducer, not a
  boundary (absolute paths / libgit2 / any unlisted tool bypass it). Use the explicit
  `jailed-*` names to run the sandboxed agents.

tmux is provided by the devShell (on `PATH`, not the host) and uses a dedicated socket
(the host tmux config is deliberately overridden). Prefix is `C-t`.
```bash
tmux -L julia_agents ls                 # list live sessions
tmux -L julia_agents attach -t <name>   # re-attach (do NOT re-run new_agent_session — it resets)
```

Verify a flake change evaluates (fast, catches Nix errors without a full build):
```bash
cd nix_src
nix eval --raw .#devShells.x86_64-linux.default.drvPath
```

## Architecture

**Entry model.** Loading the devShell (direnv or `nix develop`) only exposes executables.
`new_agent_session` is the explicit launcher: it validates the cwd is under `agentshome/projects/`,
checks the tools are on `PATH`, activates the home-manager config into
`.hosthome/`, then builds and attaches the tmux session. Nothing auto-launches — the
`shellHook` is intentionally empty so direnv can load the env on every `cd` without side
effects.

**Two-layer split: generic vs. program-specific.** `jailed-agents.nix` owns everything
program-agnostic: the generic `makeJailed { name, exe, extraArgs, socatLegs, network,
proxiedNetwork, allowedDomains, options, extraPkgs, preHook }` builds each agent as an
outer `writeShellScriptBin` wrapper around an inner `jail "<name>-inner" …` sandbox
(`exe` — a derivation or literal path — and `socatLegs` are resolved into a launcher by
`mkLauncher`; the wrapper runs `preHook` and the shared `assertInDevshell` cwd check, then
`exec`s the inner). It also owns the network-allowlist proxy plumbing (tinyproxy listening
on a per-instance unix socket via ip2unix, `restrictedNetOptions`, `localhostResolveBinds`),
common binds (`gitReadBinds`,
`nixLdBinds`), and `new_agent_session`/`attach_agent_session`. `flake.nix` owns everything
program-specific: the `makeJailedClaude/Shell/Julia/Kaimon` constructors (each a thin call
into `makeJailed` setting `exe`, `network`, `proxiedNetwork`, `preHook`, and `options`),
their bind sets (`claudeConfigWriteBinds`, `juliaDepotWriteBinds`, `kaimonCacheWriteBinds`,
`kaimonConfigWriteBinds`), the Claude↔Kaimon MCP socat legs, and the domain allowlists.
The inner sandbox's store path fully encodes its binds/program/network — comparing inner
derivations before/after a refactor is a reliable equivalence check
(`nix eval --raw .#devShells.<system>.default.drvPath`).

**`network` vs `proxiedNetwork`.** Mutually exclusive `makeJailed` flags, asserted at eval
time: `network = true` gives full host network (no proxy); `proxiedNetwork = true` keeps
jail.nix's default empty netns and reaches the internet only through a host-side allowlist
proxy bridged in over a unix socket (`allowedDomains` required, and disallowed otherwise).
Every jail without full host network — restricted or fully offline (e.g. Kaimon) — also
gets `localhostResolveBinds`, since an empty netns has no `/etc/hosts`/`nsswitch.conf`.

**Bind model.** Program-specific bind sets in `flake.nix` (`claudeConfigWriteBinds`,
`juliaDepotWriteBinds`, `kaimonCacheWriteBinds`, `kaimonConfigWriteBinds`) map subdirs of
the host `agentshome/` into the jail's `/home/agents`; generic ones (`gitReadBinds`,
`nixLdBinds`) live in `jailed-agents.nix`. Kaimon↔Julia communication relies on a shared
`.cache/kaimon` (each jail now runs in its own PID namespace — no `share-ns "pid"`);
`nix-ld` binds provide a dynamic linker for non-Nix binaries. `$HOME` inside the jail is a
writable tmpfs.

**tmux session layout.** The window layout is native tmux syntax in
`.hosthome/.config/tmux/default-session.conf`, read at runtime (edits apply on the next
`new_agent_session`, no rebuild). It is applied with `source-file -t "$session:"` so all
commands target the right session on the shared `-L julia_agents` server; the project
directory is passed in as the `@proj` tmux user option and referenced as
`new-window -c "#{@proj}"` (a bare `new-window` would inherit the server's launch dir, not
the project dir).

## Conventions & gotchas

- `devshellRoot` in `flake.nix` is a hardcoded absolute path — it must be updated after
  cloning (the README's Setup section covers this).
- `.envrc` prefers nix-direnv's `use flake` and falls back to `nix print-dev-env`; it
  `watch_file`s `jailed-agents.nix` and `devshell-home.nix` (which Nix would not otherwise
  track) so plain direnv reloads when they change.
- Only one Kaimon server/CLI can run at a time across sessions.
- Building the jails requires unprivileged user namespaces; on Ubuntu these are AppArmor-
  restricted by default (README has the fix).
- The host-tool guard is `guardHostTool` in `jailed-agents.nix`, applied in `flake.nix` over
  the `guardedHostTools` list (extend it to cover more tools); it refuses to run anywhere under `agentHomeDirectory`
  (the whole `agentshome/` tree, which now contains `projects/` too). The interactive shell's
  startup files live in `.hosthome/` (a separate tree, never bound into a jail), so they
  cannot become agent-writable.
- Two host homes: `.hosthome/` (home-manager activated, host interactive `$HOME`, via
  `hostHomeDirectory`) vs `agentshome/` (jail-bound agent data, via `agentHomeDirectory`).
  home-manager activates into the former; the jails rw-bind subdirs of the latter.
- Never bind `agentshome/.cache/` wholesale (or `.cache/jail-net`) into a jail — that
  directory holds every instance's host-side proxy socket, and a jail that can reach it
  could route through another jail's allowlist. Bind only specific `.cache/` subdirs
  (as `kaimonCacheWriteBinds` does). Enforced at eval time by `assertNoForbiddenBinds`
  in `jailed-agents.nix`, which scans the inner jail's bwrap args for bind sources that
  expose `.cache/jail-net` or any `forbiddenBindPaths` entry (set in `flake.nix`; also
  covers ancestor binds up to `/`), and requires every static bind source to be under
  `agentshome/` or the nix store (jail.nix's `~/.local/share/jail.nix` fake-passwd data
  and `/run/systemd/resolve` excepted). Footgun check, not a boundary — runtime `"$…"`
  bwrap args are not parsed, and read-only binds are rejected too (unix-socket
  `connect()` works through a ro mount).

## Security

The agent's Claude credentials live in `agentshome/.claude/` (git-ignored). `DEVNOTES.ms`
describes encrypting them with sops/age for safe committing. Per the README warning: there
is no security guarantee — run full-privilege sandboxed agents only from an isolated machine
with no access to sensitive data, using an independent GitHub account and secrets.
