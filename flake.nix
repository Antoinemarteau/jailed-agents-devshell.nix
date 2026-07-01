{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    jailed-agents.url = "path:/home/antoine/prog/ai-agent-sandboxing/jailed-agents";
  };

  outputs = { self, nixpkgs, flake-utils, jailed-agents, ... }:
  flake-utils.lib.eachDefaultSystem (system:
  let
            #system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in
  {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        pkgs.nixd
        (pkgs.writeShellScriptBin "claude" ''exec jailed-claude "$@"'')
        (pkgs.writeShellScriptBin "yolo-claude" ''exec jailed-claude --dangerously-skip-permissions "$@"'')
        (pkgs.writeShellScriptBin "jail_debuging"   ''exec jailed-bash "$@"'')

        (jailed-agents.lib.${system}.makeJailedClaude {
          extraPkgs = [ ];
        })

        (jailed-agents.lib.${system}.makeJailedShell {
          extraPkgs = [ claude-code ];
        })

      ];

      shellHook = ''
        # require tmux
        if ! command -v tmux >/dev/null 2>&1; then
          echo "ERROR: tmux is not installed on the host — install it via your OS package manager" >&2
          exit 1
        fi

        if [ -z "''${DEVSHELL_ROOT:-}" ]; then
          export DEVSHELL_ROOT="$(git rev-parse --show-toplevel)/"
        fi
        mkdir -p "$DEVSHELL_ROOT/.claude"

        # Create or reset the tmux session. -L creates an independant tmux server.
        tmux -L julia-agent-dev kill-session -t julia_agents 2>/dev/null || true
        tmux -L julia-agent-dev new-session -s julia_agents
      '';
    };
  });
}
