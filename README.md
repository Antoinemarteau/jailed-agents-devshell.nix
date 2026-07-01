# ai-agent-nix-sandboxing

A tool to run coding agents within a sandboxed environment that is based on the
"user namespaces" Linux feature and can be run without host privilege.

The sandbox can be run from an unprivileged environment, still the sandboxed
agent can be given full privilege.

> [!WARNING]
> I have no security background, there is no security guarantee. I would only
> use fully privileged sandboxed agents from an independent machine with no
> (access to) sensitive data, and commit through an independent forge (Github)
> account using independent secrets (e.g. ssh keys).

## Setup

1. Generate a dedicated SSH key for the agent. For security, this key should be
   independent from your personal keys and associated with a separate GitHub
   account used exclusively by the agent:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_agent -C "agent"
   ```

2. Create the a `WORKSPACE/` directory to put Claude settings and secrets.
   Create a `.sops.yaml` in your `WORKSPACE/` directory with your SSH public
   key:
   ```yaml
   keys:
     - &agentkey ssh-ed25519 AAAA...your-agent-ssh-public-key... # cat ~/.ssh/id_ed25519_agent.pub
   creation_rules:
     - path_regex: \.credentials\.json
       key_groups:
         - age:
           - *agentkey
   ```

3. Encrypt your credentials to connect to Claude from where `.sops.yaml` is:
   ```bash
   WORKSPACE$ sops -e ~/.claude/.credentials.json > credentials.enc.json
   ```
   If your SSH key has a passphrase, sops will prompt for it. This assumes that
   you have connected `claude` before so that `.credentials.json` exists. The
   encrypted `credentials.enc.json` can safely be put in a git repository.

## Usage

Clone the repo, then from the project root start (or restart) the tmux session:
```bash
nix develop .
```

This creates a persistent `julia_agents` session on a dedicated tmux socket, with
`jailed-claude` on PATH. From any project directory inside the session, run the
agent — the sandbox automatically mounts your current directory as the agent's
workspace:
```bash
cd agent_workspaces/*myproject*
claude      # sandboxed claude with normal permission and network access, or
yolo-claude # sandboxed claude with --dangerously-skip-permissions, but restricted network access.
```

To re-attach later, do not use `nix develop` that kills the session and all
existing agents, but:
```bash
tmux -L julia-agent-dev attach -t julia_agents
```

## Technical details

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via [jail.nix](https://sr.ht/~alexdavid/jail.nix/).

Written using Claude-code.
