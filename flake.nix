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
        export JAILED_CLAUDE_CONFIG="$PWD/.claude"
        mkdir -p "$JAILED_CLAUDE_CONFIG"
      '';
    };
  });
}
