# ai-agent-nix-sandboxing

A reproducible development environment for Julia projects on Linux, based on
nix, tmux and direnv. Currently, it provides the Claude and Kaimon CLI as well
as Julia REPL, sandboxed in different Linux "user namespaces".

The sandboxes can be run from an unprivileged environment, still the sandboxed
agent can be given full privilege.

> [!WARNING]
> I have no security background training, there is no security guarantee. I would only
> use fully privileged sandboxed agents from an independent machine with no
> (access to) sensitive data, and commit through an independent forge (Github)
> account using independent secrets (e.g. ssh keys).


## Setup

Before starting, you will need [`nix`](https://nixos.org/download/) and
optionally [`direnv`](https://direnv.net/) (recommended) installed on your
machine.

This repository has the following structure:
```
.
├── projects/           # Folder containing all development projects
├── agentshome/         # agent data (partially) forwarded to the sandboxes
│   ├── .claude/        # agent specific Claude config
│   ├── .config/
│   │   ├── kaimon/
│   │   └── zsh/        # sandboxed shell config
│   └── .julia/         # agent specific julia folder
│       └── startup.jl
├── nix_src/            # nix code for the development environment
├── .envrc              # direnv config. (automatically activate dev. environment)
├─ README.md
└── .hosthome/          # host interactive home (home-manager: zsh/tmux/nvim), never jailed
    └── .config/
       └── tmux/default-session.conf # user-editable tmux session layout
```

Clone the repository. Change the hard-coded
```nix
devshellRoot = "/home/antoine/prog/ai-agent-sandboxing";
```
variable in the `nix_src/flake.nix` file, to the
actual absolute path of the local folder the repo was cloned in.

Then enable `direnv` for the checked-in `.envrc`, from the repository root
(the `devshellRoot`):
```bash
direnv allow
```
Entering any project under `projects/` now puts the sandboxed tools on `PATH`
automatically.

For faster cached reloads (optional, recommended), install `nix-direnv` at user level
— no system or home-manager config required:
```bash
nix profile install nixpkgs#nix-direnv
echo 'source $HOME/.nix-profile/share/nix-direnv/direnvrc' >> ~/.config/direnv/direnvrc
```

### Ubuntu setup

Extra steps are required on Ubuntu that by default [restricts user
namespaces](https://etbe.coker.com.au/2024/04/24/ubuntu-24-04-bubblewrap/) via
apparmor.
A relatively simple and safe solution is to:
```bash
sudo apt install apparmor-profiles # install pre-made apparmor profile
sudo ln -s /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/ # add one for bubblwrap
sudo apparmor_parser /etc/apparmor.d/bwrap-userns-restrict. # load it, optionally use -r to reload, or --delete then --add.
systemctl restart
```

If this not enough (you get an error at next step), you can simply do
```bash
sudo sysctl -w kernel.apparmor_restrict_unprivileged_unconfined=0
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```
but it is [unsafe and
discouraged](https://gitlab.com/apparmor/apparmor/-/wikis/unprivileged_userns_restriction)
on personal machine. These are reset to default by setting 1 instead of 0.


## Usage

Create a project directory, clone what you need, `cd` into.
```bash
mkdir projects/my_project
git clone <url> projects/my_project # don't do that from within projects/
cd projects/my_project
```

Then, from the project folder (must be within `<devshellRoot>/projects`, where
`direnv` has loaded the tools), start (or restart) the `tmux` development session:
```bash
new_agent_session
```
On a host without `direnv`, load the environment first and then launch a session:
```bash
nix develop <devshellRoot>/nix_src
new_agent_session
```

This creates a tmux session with 4 windows:
- kaimon: automatically runs sandboxed Kaimon CLI
- shell: an un-sandboxed terminal
- claude: to run sandboxed claude-code CLI
- repl: automatically runs sandboxed Julia REPL serving Kaimon

This default session can be personalized by modifying `.hosthome/.config/tmux/default-session.conf`.\
There are two options to run sandboxed Claude from there:
```bash
jailed-claude      # sandboxed claude with normal permission, or
yolo-jailed-claude # sandboxed claude with --dangerously-skip-permissions
```

The default `jailed-julia`, doesn't have internet access. If you want a jailed
Julia REPL with internet, use `jailed-julia-net`.

On the first session you ever create, you need to:
- Launch `jailed-julia-net` to install Kaimon;
- Launch `jailed-kaimon` to setup Kaimon, choose "Lax" mode (filtering who acceses Kaimon is pointless since it is sandboxed);
- Launch `jailed-claude` that complains about invalid config, select second option (reset config), and launch it again;
- Once Claude is connected, run `claude-connect-kaimon` from the shell to connect the MCP
Claude should then be ready to pass Kaimon's `usage_quiz` and read `usage_instructions`.

To return to the development session later, do not re-run `new_agent_session`
(it kills and recreates the session and all existing agents), but from the
project folder:
```bash
attach_agent_session
```
which re-attaches the session named after the current folder. Or, manually:
```bash
tmux -L julia_agents ls # see live sessions
tmux -L julia_agents attach -t <session>
```
The non-default tmux socket `julia_agents` is used because the host tmux config
is overwritten with one provided from nix, for use on remote machine.

Only one Kaimon server/CLI can be used simultaneously, so you can kill the
first window if you launch a new tmux session (via `new_agent_session`) in
another sub-project.

## Security warning

If you let Claude have strong permission (either permissive permissions or
"yolo" mode), treat `projects/` and `agentshome/` as untrusted: development
tools that may run arbitrary code from files added in these folders (e.g. `git`
with .git/ hooks) should not be used within them.

As a guard against that mistake, a list of common host dev tools — `git`, `gh`,
`julia`, `claude`, `kaimon`, `make`, `python`, `pip`, `uv`, `conda`, `node`,
`npm`, `docker`, `apt` (see `guardedHostTools` in `flake.nix`) — is shadowed
inside the devShell: they refuse to run within an agent-writable tree
(`projects/` and some `agentshome/` sub-dirs). It is a footgun-reducer, not a
security boundary: not all dev tools are shadowed, and absolute paths
(`/usr/bin/git`) or tools that embed git (libgit2, `gh`) bypass it.


## Technical details

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via [jail.nix](https://sr.ht/~alexdavid/jail.nix/).

The design is based on this [blog from Anderson. J](https://dev.to/andersonjoseph/how-i-run-llm-agents-in-a-secure-nix-sandbox-1899).

TODO folder architechture

Written with the help of Claude code.
