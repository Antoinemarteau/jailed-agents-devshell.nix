# jailed-agents-devshell.nix

A reproducible Linux development environment to work with sandboxed coding
agents, open source and vendor independent. Currently configured to work on
Julia projects using Claude-code and Kaimon.jl.

The project leverages nix, tmux and direnv to facilitate using coding agents in
a reproducible, personalized and safer manner, on local machine or remotely via
ssh.

> [!WARNING]
> I have no security background training, there is no security guarantee. I would only
> use fully privileged sandboxed agents from an independent machine with no
> (access to) sensitive data, and commit through an independent forge (Github)
> account using independent secrets (e.g. ssh keys).

Currently, this repository provides the Claude and Kaimon CLI as well as Julia
REPL, sandboxed in different Linux "user namespaces" via
[jail-nix](https://alexdav.id/projects/jail-nix/) (that is backed by
[bubblewrap](https://github.com/containers/bubblewrap)). It has the following
structure:
```sh
.   # everyday development folders
├── agentshome/      # single agent-writeable root (agent data + projects)
│   ├── projects/    # Folder containing all development projects
│   ├── .envrc       # direnv config. (automatically activate dev. environment on cd)
│   ├── .claude/     # agent specific Claude config
│   ├── .config/
│   │   ├── kaimon/
│   │   └── zsh/     # sandboxed shell config
│   └── .julia/      # agent specific julia folder
│       └── startup.jl
│
│   # dev. environment definition and personalization
├── nix_src/         # nix code for the development environment
├── README.md
└── .hosthome/       # out-of-sandbox shell personalization
    └── .config/
       └── tmux/default-session.conf # user-editable tmux session layout
```
`nix` and `direnv` are the only software needed to be pre-installed. The
objective of this repo is that everything else is automatically installed in a
reproducible way upon cloning it. You'll still have to personalize `.julia` and
`.claude` folders and optionally other software configuration (tmux, shell,
etc.).

The sandboxes can be run from an unprivileged environment (although root
privilege is needed to install `nix` and `direnv`). The sandboxed coding tools
can only write into `agentshome/` (which holds `projects/` and the agent data).


## Setup

Before starting, you will need [`nix`](https://nixos.org/download/) and
optionally [`direnv`](https://direnv.net/) (recommended) installed on your
machine.

If [`nix-direnv`](https://github.com/nix-community/nix-direnv) is not installed
on the machine, install it at user level for faster cached reloads (optional
but recommended)
```bash
nix profile install nixpkgs#nix-direnv
echo 'source $HOME/.nix-profile/share/nix-direnv/direnvrc' >> ~/.config/direnv/direnvrc
```

Use this template (or clone the repository). Set the
```nix
devshellRoot = "";
```
variable in the `nix_src/flake.nix` file to the absolute path of the cloned repo.

Then enable `direnv` from within `agentshome/`
```bash
cd agentshome
direnv allow
```
Entering any project under `agentshome/projects/` now puts the sandboxed tools on
`PATH` automatically.

### Ubuntu setup

Ubuntu (23.10+) by default [restricts unprivileged user
namespaces](https://etbe.coker.com.au/2024/04/24/ubuntu-24-04-bubblewrap/) via
apparmor, so bubblewrap fails with `bwrap: setting up uid map: Permission
denied`. To fix it, run
```bash
sudo cp nix_src/apparmor/bwrap-userns-restrict /etc/apparmor.d/
sudo apparmor_parser -r -W /etc/apparmor.d/bwrap-userns-restrict
```
This apparmor config for bwrap is the same as the [default official bwrap
userns profile,
](https://gitlab.com/apparmor/apparmor/-/blob/master/profiles/apparmor/profiles/extras/bwrap-userns-restrict)
except it also works for the nix provided bwrap binaries.


## Usage

Create a project directory, clone what you need, `cd` into.
```bash
mkdir agentshome/projects/my_project
git clone <url> agentshome/projects/my_project # don't do that from within agentshome/
cd agentshome/projects/my_project
```

Then, from the project folder, start (or restart) the `tmux` development session
```bash
new_agent_session
```
On a host without `direnv`, load the environment first and then launch a session
```bash
nix develop <devshellRoot>/nix_src
new_agent_session
```

This creates a tmux session with 4 windows:
- kaimon: runs sandboxed Kaimon CLI, `jailed-kaimon`
- shell: runs a sandboxed terminal, `jailed-shell`
- claude: runs sandboxed claude-code CLI `jailed-claude`
- repl: runs sandboxed Julia REPL serving Kaimon, `jailed-julia`

On the first session you ever create, `agentshome/.julia/` and other configs are empty, so you need to:
- Go to the repl window and wait for the Kaimon install to finish,
- Go to kaimon window and launch `jailed-kaimon` to set it up, choose "Lax" mode (filtering who accesses Kaimon is pointless since it is sandboxed),
- Exit Claude, run `claude-connect-kaimon` from the shell to connect the MCP,
- launch `jailed-claude` again (or `yolo-jailed-claude`) and login.

Claude should then be ready to pass Kaimon's `usage_quiz` and read `usage_instructions`.
By default, Claude's login info should be stored in `agentshome/.claude/.credentials.json`.

To return to the development session later, do not re-run `new_agent_session`
(it kills and recreates the session and all existing agents), but
```bash
attach_agent_session
```
from the folder the session was started from.

Or, manually
```bash
tmux -L julia_agents ls # see live sessions
tmux -L julia_agents attach -t <session>
```
since the session is named after the folder.\
The non-default tmux socket `julia_agents` is used because the host tmux config
is overwritten with one provided from nix, for use on remote machine.

The difference between `jailed-[claude,julia]` and the `yolo-...` version is
that the former is network restricted to the whitelists:
```nix
claudeAllowedDomains = [
    "anthropic.com" "claude.ai" "claude.com" "github.com" "githubusercontent.com"
];
juliaAllowedDomains  = [
    "julialang.org" "julialang.net" "github.com" "githubusercontent.com"
];
```
using [tinyproxy](https://tinyproxy.github.io/).


### Git identity and GitHub token

To give a git identity for the agent, set name and email in
`agentshome/.gitconfig`. If you want it to pull/push, create
`agentshome/.git-credentials` with a GitHub [fine-grained Personal Access Token
(PAT)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token):
```bash
echo 'https://x-access-token:github_pat_{YOUR-TOKEN-HERE}@github.com' > agentshome/.git-credentials
chmod 600 agentshome/.git-credentials
```
Make sure to not commit .git-credentials to git.


## Security notes

This project tries to provide security features mostly equivalent to those that
[agent-sandbox.nix
details](https://github.com/archie-judd/agent-sandbox.nix#security) (read them,
it's very informative), with the following differences:
- here, the agent cannot edit its config,
- everything we here provide to the sandbox is within `agentshome/`, no host home files are forwarded by default, `/tmp/` is not shared with the host,
- we provide the read-write access to Claude credentials, and read access to the ssh keys, assuming that agent specific limited secrets are used,
- we don't forward the whole nix store to the sandboxes, only binaries required by packages provided to sandboxes.

This development environment gives Claude strong permission
(--dangerously-skip-permisson) by default. Treat the whole `agentshome/` tree
(agent data and `projects/`) as untrusted: development tools that may run
arbitrary code from files added in these folders (e.g. `git` with .git/ hooks)
should not be used within them.

Relatedly, only ever `direnv allow` the top-level `agentshome/.envrc`, never
allow an `.envrc` under `projects/`.

As a guard against that mistake, some common host dev tools — `git`, `gh`,
`julia`, `claude`, `kaimon`, `make`, `python`, `pip`, `uv`, `conda`, `node`,
`npm`, `docker`, `apt` (see `guardedHostTools` in `flake.nix`) — are shadowed
inside the devShell: they refuse to run anywhere under the `agentshome/` tree,
appart from within a `jailed-shell`.
It is a footgun-reducer, not a security boundary: not all dev tools are
shadowed, and absolute paths (`/usr/bin/git`) or tools that embed git (libgit2,
`gh`) bypass it.

## Extension and personalization

The tmux session layout is user-editable at
`.hosthome/.config/tmux/default-session.conf`, and the shell/tmux/editor
[home-manager
configurations](https://home-manager-options.extranix.com/?query=zsh&release=release-25.11)
of both the host panes and `jailed-shell` live in `nix_src/devshell-home.nix`.

The top-level `CLAUDE.md` and `.claude/memories/` files are provided to give
coding agents context about this template and how to personalize it.

### Creating a new sandboxed programs

New jailed programs are defined in `nix_src/flake.nix` by calling `makeJailed`
and adding the result to the development shell `packages` list (bottom of the file):
```nix
(makeJailed {
  name = "jailed-htop";
  exe = pkgs.htop;
})
```
Every jail starts from the same baseline: a writable tmpfs (temporary file
system) `$HOME`, the current project directory mounted read-write (the wrapper
refuses to run outside `agentshome/projects/`) and no network unless requested.

`makeJailed` arguments:
- `name` — command name of the generated wrapper.
- `exe` — program to sandbox: a nix package (e.g. from [nixpkgs](https://search.nixos.org/packages)) or a literal in-jail path string (c.f. jailed-kaimon).
- `extraArgs` — extra command-line arguments appended to every `exe` invocation (default `""`).
- `extraPkgs` — additional packages made available on `PATH` inside the jail (default `[]`).
- `options` — extra [jail.nix combinators](https://alexdav.id/projects/jail-nix/combinators/), typically binds of `agentshome/` subdirs into the jail `$HOME` (default `[]`).
- `preHook` — bash run on the host before entering the jail, e.g. `mkdir -p` the folders about to be bound (default `""`).
- `network` — `true` gives full host network access; `false` (default) leaves the jail in an empty network namespace, i.e. no egress.
- `proxiedNetwork` — `true` keeps the empty namespace but bridges in a host-side domain-allowlist proxy; mutually exclusive with `network` (default `false`).
- `allowedDomains` — if `proxiedNetwork`, the domains the proxy allows, subdomains included.
- `socatLegs` — in-jail `socat` commands started in the background before `exe`, for bridging unix sockets into the jail (see the Claude↔Kaimon MCP legs).

To give the jail persistent state, bind subfolders of `agentshome/` in
`options`, following the existing bind sets (`claudeConfigWriteBinds`, ...):
```nix
options = with jail.combinators; [
  (rw-bind "${agentHomeDirectory}/.config/foo" "${jailHomeDirectory}/.config/foo")
];
```
Bind sources are checked at eval time: they must stay under `agentshome/`, and
must not expose any `forbiddenBindPaths` entry (see `flake.nix`). In
particular, never bind `agentshome/.cache/` — it holds the host-side proxy
sockets of every jail instance.

## Technical details

The design is inspired on this [blog from Anderson. J](https://dev.to/andersonjoseph/how-i-run-llm-agents-in-a-secure-nix-sandbox-1899).

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via
[jail.nix](https://sr.ht/~alexdavid/jail.nix/). The network proxy is handled
using [tinyproxy](https://github.com/tinyproxy/tinyproxy) and
[ip2unix](https://github.com/nixcloud/ip2unix) on the host, and
[socat](http://www.dest-unreach.org/socat/) in the sandbox.

The development environment itself is the `devShell` defined in
`nix_src/flake.nix`. This development "shell" is activated by `direnv` within
`agentshome/` once allowed by `direnv allow`. This `devShell` puts the
`jailed-*` tools, `new_agent_session` and `attach_agent_session` on `PATH`.
The `jailed-*` tools can be used outside of a tmux session.

### Security model

> [!WARNING]
> This section mostly comes from Claude's understanding / explanation, I don't
> have the skills to review these materials in detail.

The untrusted party is the sandboxed agent: it may run arbitrary code and
create files within the project. So the design assumes the worst from anything
executing inside a sandbox, and assumes that every development tool usage from
within the projects directories should be sandboxed.

**Filesystem isolation.** Each tool runs in its own unprivileged user, mount
and PID namespace (via bubblewrap). A sandbox's `$HOME` is a throwaway tmpfs; the only
host paths visible inside are
- the current project directory,
- the explicitly bound subdirectories of `agentshome/` (e.g. `.claude/`, `.julia/`),
- read-only nix store paths limited to the runtime closure of the provided packages.

The host home, `/tmp` and the rest of the filesystem are simply not there. None
of the nix code and host side configuration (in `nix_src` and `.hosthome/`) are
ever bound into any sandbox, so the agent cannot alter the developemnt tools (`jailed-*`, tmux...).

**Network isolation.** A sandbox gets one of three network states:
- *none* (default): an empty network namespace — no interface besides loopback,
  the network isolation is enforced strictly by the host OS;
- *proxied* (e.g. `jailed-claude` & `jailed-julia`): the
  namespace stays empty, and the only way out is a unix socket bound into the
  sandbox. On the host side that socket is a per-instance
  [tinyproxy](https://tinyproxy.github.io/) with a default-deny domain allowlist
  and `CONNECT` limited to ports 80/443 (`ip2unix` makes tinyproxy listen on the
  socket, in-jail `socat` re-exposes it as the local `HTTP(S)_PROXY`). HTTPS
  stays end-to-end encrypted — the proxy only sees the domain, it does not
  intercept TLS.\
  If the proxy dies, the jail is left with the empty namespace, so no network.
- *full* (e.g. `yolo-jailed-claude` & `...-julia`): host network, unrestricted.

**Boundaries vs. footgun reducers.** The security boundaries are the
file-system and network isolation described above. Everything else is a guard
against user *mistakes*: the shadowed host tools, the current working directory
checks refusing to start jails outside `agentshome/projects/`, and the
`forbiddenBindPaths` checked at direnv activation.

**Assumed residual risks.** The agent necessarily holds working credentials
(its Claude token, optionally a GitHub PAT) and can reach the allowlisted
domains, so it can leak whatever it can read — which is why those secrets must
be dedicated, low-privilege ones (see the warning at the top). The remaining
attack surface is the kernel/bubblewrap unprivileged-user-namespace machinery
itself, and any service reachable through the allowlisted domains.

## Similar projects

Sandboxing tools alternative to `jail-nix` are described [agent-sandbox.nix's
README](https://github.com/archie-judd/agent-sandbox.nix).

Specific characteristics of the project:
- linux only,
- not just a sandbox, also a portable and remotely-usable dev. environment,
- this is meant to be forked and personalized to your needs, it's not a library.

Written with the invaluable help of Claude code.
