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

2. Create a `.sops.yaml` in your project root with your SSH public key:
   ```yaml
   keys:
     - &mykey ssh-ed25519 AAAA...your-agent-ssh-public-key...  # cat ~/.ssh/id_ed25519_agent.pub
   creation_rules:
     - path_regex: secrets\.yaml
       key_groups:
         - age:
           - *mykey
   ```

3. Create the `agent_workspace/` directory and encrypt your secrets into it:
   ```bash
   mkdir agent_workspace
   sops agent_workspace/secrets.yaml
   ```
   Add the following to the file, then save and close:
   ```yaml
   CLAUDE_CODE_OAUTH_TOKEN: your-token-here
   ```
   If your SSH key has a passphrase, sops will prompt for it.

## Usage

```bash
AGENT_WORKDIR=./agent_workspace nix run github:Antoinemarteau/ai-agent-nix-sandboxing
```

## Technical details

The tool is developed using nix and only requires installing the [nix package
manager](https://nixos.org/download/) (it is a "nix flake"). The user
namespaces are created by
[bubblewrap](https://github.com/containers/bubblewrap) via [jail.nix](https://sr.ht/~alexdavid/jail.nix/).

Written using Claude-code.
