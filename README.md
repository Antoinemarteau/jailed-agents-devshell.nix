# ai-agent-nix-sandboxing

A tool to run the Claude cli within a sandboxed environment that is based on the
"user namespaces" Linux feature.

The sandbox can be run from an unprivileged environment, still the sandboxed
agent can be given full privilege.

> [!WARNING]
> I have no informatic security background, there is no security guarantee. I
> would only use fully privileged sandboxed agents from an independent machine
> with no (access to) sensitive data, and commit through an independent forge
> (Github) account using independent secrets (e.g. ssh keys).


## Setup

Before starting, you will need to have [`nix`](https://nixos.org/download/) and
[`tmux`](https://github.com/tmux/tmux/wiki/installing) installed on your machine.

Clone the repository. Change the hard-coded
```nix
    devshellRoot = "/home/antoine/prog/ai-agent-sandboxing";
```
variable in the top-level flake.nix to the root of the git repository. This
repository contains the `.claude/` and `.julia/` folders that will be
given/seen by your sandboxed agents.

For convenience, register the nix flake for easier new session start.
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

If this not enough, you can simply do
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

This creates a tmux session with windows:
- shell: an un-sandboxed terminal
- claude: to run sandboxed claude-code cli
- kaimon: automatically runs sandboxed kaimon cli
- repl: automatically runs sandboxed julia repl serving kaimon
. There are two options to run sandboxed claude from there:
```bash
claude      # sandboxed claude with normal permission, or
yolo-claude # sandboxed claude with --dangerously-skip-permissions
```

To return to the development session later, do not use `nix develop` that kills
the session and all existing agents, but:
```bash
tmux attach <session>
```


## Technical details

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via [jail.nix](https://sr.ht/~alexdavid/jail.nix/).

The design is based on this [blog from Anderson. J](https://dev.to/andersonjoseph/how-i-run-llm-agents-in-a-secure-nix-sandbox-1899).

Written with the help of Claude code.
