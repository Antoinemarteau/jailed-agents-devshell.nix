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

From the root of your coding project folder (must be within
<devshellRoot>/projects), start (or restart) the development environment:
```bash
nix develop agents
```

This creates a persistent `julia_agents` tmux session on a dedicated tmux
socket script to launch sandboxed agents on PATH. From any project directory
inside the session, run the agent — the sandbox automatically mounts your
*current* directory as the agent's workspace. It is thus advised to create
subfolders and launch the agents from there.
```bash
mkdir agent_workspaces/my_project
cd agent_workspaces/my_project
claude      # sandboxed claude with normal permission, or
yolo-claude # sandboxed claude with --dangerously-skip-permissions
```

To re-attach later, do not use `nix develop` that kills the session and all
existing agents, but:
```bash
tmux attach <session>
```

## Technical details

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via [jail.nix](https://sr.ht/~alexdavid/jail.nix/).

The design is based on this [blog from Anderson. J](https://dev.to/andersonjoseph/how-i-run-llm-agents-in-a-secure-nix-sandbox-1899).

Written with the help of claude-code.
