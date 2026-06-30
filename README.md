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

```bash
# from the workspace directory (uses current directory by default)
nix run github:Antoinemarteau/ai-agent-nix-sandboxing

# or from anywhere, pointing to the workspace explicitly
AGENT_WORKDIR=./WORKSPACE nix run github:Antoinemarteau/ai-agent-nix-sandboxing
```

## Technical details

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via [jail.nix](https://sr.ht/~alexdavid/jail.nix/).

Written using Claude-code.
