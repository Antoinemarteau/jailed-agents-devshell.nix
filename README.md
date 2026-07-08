# ai-agent-nix-sandboxing

A reproducible development environment for Julia projects on Linux, based on
nix. Currently, it provides the Claude and Kaimon CLI as well as Julia REPL,
sandboxed in different Linux "user namespaces".

The sandboxes can be run from an unprivileged environment, still the sandboxed
agent can be given full privilege.

> [!WARNING]
> I have no informatic background, there is no security guarantee. I would only
> use fully privileged sandboxed agents from an independent machine with no
> (access to) sensitive data, and commit through an independent forge (Github)
> account using independent secrets (e.g. ssh keys).


## Setup

Before starting, you will need to have [`nix`](https://nixos.org/download/) and
[`tmux`](https://github.com/tmux/tmux/wiki/installing) installed on your machine.

This repository has the following structure:
```
  .
  ├── projects/           # Folder containing all development projects
  ├── agentshome/         # home folder (partially) forwarded to the sandbox
  │   ├── .claude/        # agent specific Claude config
  │   ├── .config/
  │   │   ├── kaimon/     # contains kaimon config
  │   │   └── tmux/default-session.conf # default tmux session layout
  │   └── .julia/         # agent specific julia folder
  │       └── startup.jl
  ├── devshell_tmux_with_jailed_agents/ # nix code for the development environment
  └── README.md           # This file
  ```

Clone the repository. Change the hard-coded
```nix
    devshellRoot = "/home/antoine/prog/ai-agent-sandboxing";
```
variable in the `devshell_tmux_with_jailed_agents/flake.nix` file, to the
actual absolute path of the local folder the repo was cloned in.

For convenience, register the nix flake for easier start of new development sessions:
```bash
nix registry add agents <devshellRoot>/devshell_tmux_with_jailed_agents/
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

Create and `cd` into a project directory
```bash
mkdir projects/my_project
cd projects/my_project
```
and clone what you need.

Then, from the project folder (must be within
`<devshellRoot>/projects`), start (or restart) the development environment:
```bash
nix develop agents
```

This creates a tmux session with 4 windows:
- kaimon: automatically runs sandboxed Kaimon CLI
- shell: an un-sandboxed terminal
- claude: to run sandboxed claude-code CLI
- repl: automatically runs sandboxed Julia REPL serving Kaimon
This can be personalized by modifying `agentshome/.config/tmux/default-session.conf`

There are two options to run sandboxed Claude from there:
```bash
claude      # sandboxed claude with normal permission, or
yolo-claude # sandboxed claude with --dangerously-skip-permissions
```

The default `jailed-julia`, that is run in the repl window, doesn't have
internet access. If you want a jailed Julia REPL with internet, use
`jailed-julia-net` (useful when setting up the environment because it
automatically installs Kaimon.jl from instructions in startup.jl).

To return to the development session later, do not use `nix develop` that kills
the session and all existing agents, but:
```bash
tmux -L julia_agents ls # see live sessions
tmux -L julia_agents attach -t <session>
```
A non-default tmux socket is used because the host tmux config is overwritten
(one is provided from nix, for use on remote machine).

Only one Kaimon server/CLI can be used simultaneously, so you can kill the
first window if you launch a new tmux session (via `nix develop agents`) in
another sub-project.


## Technical details

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via [jail.nix](https://sr.ht/~alexdavid/jail.nix/).

The design is based on this [blog from Anderson. J](https://dev.to/andersonjoseph/how-i-run-llm-agents-in-a-secure-nix-sandbox-1899).

TODO folder architechture

Written with the help of Claude code.
