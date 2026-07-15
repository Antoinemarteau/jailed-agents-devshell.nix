---
name: security-review-reports
description: "Security-review findings for the jailed-agents-devshell.nix repo, by git range (network-restriction + reorg work)"
metadata: 
  node_type: memory
  type: project
---

Security reviews performed with the `/security-review` skill's threat model. Repo threat model: single-user host; the **untrusted party is the sandboxed agent**, which runs in an empty network namespace and reaches the host only through the bound unix socket. See [[project-network-restriction-impl]] and [[project-jailed-agents-devshell]].

## Range `9063a5013..master` (reviewed 2026-07-13) — tinyproxy refactor, per-instance proxies, direnv-in-panes

**Result: NO HIGH/MEDIUM findings.** Files: README.md, devshell-home.nix, jailed-agents.nix, network-restrictions.nix. Candidates examined and cleared:
- **Allowlist regex** (`mkProxyFilterFile`, ERE `(^|\.)d$`, dots escaped): anchoring correct — `julialang.org.evil.com`, `evil-julialang.org`, `xjulialang.org` do NOT match; no bypass vs. the old Python `endswith` match. `domains` is build-time config, not untrusted.
- **New host-loopback TCP surface** (tinyproxy `127.0.0.1:<port>`): restricted jails are empty-netns → can't reach it; host-netns contexts that can (`jailed-shell`, `yolo-*`, local procs) already have full network, so an allowlist proxy is strictly *less* capability (no SSRF pivot; `ConnectPort` 80/443 only). No escalation.
- **Runtime `--bind "${JAIL_PROXY_HOST_SOCK-}"`** (`unsafe-add-raw-args`): value is wrapper-set `<home>/.cache/jail-net/<name>.<pid>.sock` (build-time + PID), quoted, no metachars, mirrors jail.nix `mount-cwd`. No injection.
- **Fail-closed**: all-10-port-retry-fail → `exit 1` (jail doesn't launch); proxy death mid-session → empty netns = no egress. Boundary stays fail-closed.
- **`FilterCaseSensitive Off`**: safe for allowlist (case-fold can't create a different allowed host).
- **direnv-in-panes / `bind C`**: deny-by-default hook, no agent→host exec path; footgun (user manually allowing an agent-planted `projects/.envrc`) documented in README.

## Uncommitted working tree on master (reviewed 2026-07-14, second pass) — assertNoForbiddenBinds + forbiddenBindPaths

**Result: NO findings ≥0.7 confidence (clean).** Incremental review of the eval-time bind checks added on top of the ip2unix refactor (below). Cleared: the check is an identity function when passing (drvPath byte-identical, independently re-verified → zero runtime surface); fail mode is eval abort = fail-closed, strictly additive restrictiveness; all check inputs are eval-time constants the jailed agent cannot influence (and the check itself now forbids binding `nix_src/`/`.git/`, protecting its own integrity); parser gaps (raw args, `"`-prefixed runtime sources, symlinks) are the documented footgun-not-boundary limitation and admit no attacker-controlled source in the current config; the five `forbiddenBindPaths` each map to a real host-code-exec vector if ever bound.

## Uncommitted working tree on master (reviewed 2026-07-14) — ip2unix proxy simplification (jailed-agents.nix only)

**Result: NO findings ≥0.7 confidence (clean).** The `jail-net-proxy` script (random TCP port + host socat + /dev/tcp probe) was replaced by `ip2unix -r in,tcp,port=3128,path=$SOCK tinyproxy -d -c <store conf>` in `runInner`. Cleared: `in`-rule scoping (outgoing tinyproxy traffic untouched, only the one listener captured); host socket perms unchanged vs socat (umask-dependent, 0755 ⇒ others can't connect) and the agent can't reach `~/.cache/jail-net` through any bind (verified all rw binds in flake.nix — only `.cache/kaimon` and `.cache/kaimon-jail-sock` subtrees, never `.cache` itself); readiness change (socket-at-bind vs confirmed-accepting) is fail-closed — pre-`listen()` connects get ECONNREFUSED, and even a pre-filter-load connect hits `FilterDefaultDeny Yes` + empty list = deny-all; conf/filter in world-readable store contain no secrets; `rm -f`/trap paths are build-time constants + wrapper `$$`. Net improvement: the old host-loopback TCP listener (usable by any local process as a proxy) no longer exists.

## Range `7bc3a90cc7..master` (reviewed 2026-07-13) — full native network-restriction + reorg + credential-access work (19 commits)

**Result: NO CONFIRMED HIGH/MEDIUM findings. One conditional MEDIUM advisory (unverified) — see below.** Files: flake.nix, jailed-agents.nix, network-restrictions.nix (new), devshell-home.nix, .claude/settings.json, .gitconfig, .hosthome tmux conf, .envrc (moved), .gitignore.

Confirmed-safe / cleared:
- **Network allowlist** (empty netns + tinyproxy proxy) is a net *improvement* over the previous full-network default; fail-closed; CONNECT is end-to-end TLS (no MITM), correct cacert bundle. Allowlist regex reviewed (see range above).
- **guard** broadened from a dir-list to the whole `agentHomeDirectory` (more protective; still explicitly "footgun-reducer, not a boundary").
- **gitconfig credential helper** hardened to `get`-only (`!f() { [ "$1" = get ] && git credential-store --file ~/.git-credentials "$1"; }`), so the agent can't overwrite the stored PAT; `$1` is git-controlled → no injection.
- **.gitignore** still ignores `agentshome/.git-credentials` (the PAT) — no secret-commit regression.
- **reorg** (projects/ + .envrc into agentshome) is path-consistent; `assertInDevshell` + guard cover the new location.
- **`share-ns "pid"`** (host PID ns for julia/kaimon/shell → /proc visibility of host processes) is **pre-existing** (context lines in the diff), so out of scope for this range — but worth a future look as a standalone confidentiality concern.
- runtime `--bind "${JAIL_PROXY_HOST_SOCK-}"`, mkLauncher socat legs, kaimon MCP bridge: no injection, intended.

**ADVISORY (MEDIUM if confirmed; UNVERIFIED):** This range makes the *default* `jailed-claude` run `--dangerously-skip-permissions` (bypassPermissions mode) — previously only a separate `yolo-jailed-claude` wrapper did — and adds `skipDangerousModePermissionPrompt: true` plus `deny` rules for `~/.git-credentials`, `~/.claude/.credentials.json`, `curl`/`wget`. **If bypassPermissions skips deny evaluation (likely, per Claude Code's "skips all permission checks", but NOT confirmed — couldn't reach docs, claude-code-guide couldn't verify), those deny rules are inert**, so a prompt-injected agent can read the GitHub PAT (bound ro via `gitReadBinds`) and the Anthropic token (`.claude/.credentials.json`, rw-bound) and exfiltrate via the `github.com`/`anthropic.com` allowlist. Mitigated by design: README mandates independent secrets on an isolated machine, and the agent needs those creds to operate. **Verify empirically:** launch `jailed-claude`, ask it to `Read(~/.git-credentials)`; if it succeeds, the deny list is not a real control under dangerous mode (rely on the jail + independent secrets instead, and consider not binding `.git-credentials`/creds when not needed).

## Focused finding: `share-ns "pid"` = host PID namespace → host process data leaks into the sandbox — **RESOLVED 2026-07-13**

**RESOLUTION: `share-ns "pid"` removed from ALL jails (julia/kaimon/shell). Validated live on a fresh clone — Claude→Kaimon→Julia eval works without it.** Each jail now gets its own PID ns (default `--unshare-pid`), so `/proc` shows only in-jail processes → host-process leak closed. Root cause of it ever being needed: older Kaimon checked a PID for gate liveness; **KaimonGate ~1.0 (the gate now ships as its own ZMQ+stdlib package) dropped that** — comm is pure ZMQ-IPC + filesystem discovery in the shared `~/.cache/kaimon/sock/` (bound rw into both jails). Lesson: these deps move fast; a 2-week-old "PID is required" assumption was stale — re-verify. (`ps` stays in commonPkgs; now scoped to the jail's own PID ns, which is correct.)

**Severity had this not been fixed: MEDIUM on this host (`kernel.yama.ptrace_scope=1`); HIGH on any host with `ptrace_scope=0`.** Category: sandbox isolation breach / information disclosure. Was at: `jailed-agents.nix` `share-ns "pid"` on jailed-julia / jailed-kaimon / jailed-shell (NOT jailed-claude).

Mechanics (all verified): `share-ns "pid"` drops `--unshare-pid` → jail runs in the **host** PID ns; jail.nix `base` mounts `--proc /proc` → that procfs shows **all host processes**; bwrap `--unshare-user` with no `--uid` maps the caller's real uid→itself (uid 1000). So these jails can: read **`/proc/<pid>/cmdline` of every host process** (world-readable); read **`/proc/<pid>/environ` of every same-uid host process** (environ uses `PTRACE_MODE_READ`, which Yama does NOT restrict — only the uid check applies); **signal** same-uid procs; and on `ptrace_scope=0` hosts, ATTACH/read same-uid process **memory**.

**Reachable by the primary agent transitively:** jailed-claude lacks host PID ns, but holds `kaimonClientLeg` → drives the Kaimon MCP → arbitrary **Julia eval** in jailed-julia (which HAS host PID ns). So a prompt-injected Claude runs Julia like `read("/proc/$pid/environ", String)` to scrape host process secrets, exfil via the julia allowlist. Punctures the "agent only sees agentshome" promise.

Root cause: PID sharing was added only so **Kaimon ↔ its Julia server** can find each other — sharing the *host* ns is broader than needed.

**KaimonGate architecture (from the official Gate/API docs, 2026-07-13): comm does NOT need a shared PID namespace.** The Gate uses **ZMQ (ZeroMQ) IPC = Unix-domain sockets** (REP for eval/tool/ping/restart, PUB for stdout/stderr streaming) with endpoints under **`~/.cache/kaimon/sock/`**; **session discovery = JSON metadata files written to that same dir**, which the Kaimon server watches and auto-connects; liveness = ZMQ **ping**; reconnection after `restart()` (execvp, same PID) = **session key**, not PID. `~/.cache/kaimon` is already rw-bound into both jailed-julia and jailed-kaimon (`kaimonCacheWriteBinds`), and AF_UNIX filesystem sockets + files cross mount namespaces via that shared bind independent of PID/net ns. So the `# required for Kaimon <-> Julia comm` comment is **stale/misdiagnosed**. TCP mode (`KAIMON_GATE_MODE=tcp` + `KAIMON_GATE_TOKEN`/CURVE) is an alternative but unnecessary.

**Fix (recommended): just remove `share-ns "pid"`** from julia/kaimon/shell and verify Claude→Kaimon→Julia eval still works (it rides the existing shared-cache IPC). Only residual uncertainty: whether a Kaimon *tool* (e.g. `investigate_environment`, `ps`) relies on host /proc — the empirical test settles it. Fallback if some undocumented PID dependency surfaces: a **jail-private shared PID ns** for julia+kaimon (shared `unshare --pid --fork` supervisor, or bwrap `--pid-ns <fd>`, or co-locate both in one bwrap). See [[project-network-restriction-impl]].
