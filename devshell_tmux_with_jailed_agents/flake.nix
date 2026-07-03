{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, flake-utils, home-manager, jail-nix, llm-agents, ... }:
  flake-utils.lib.eachDefaultSystem (system:
  let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    # Variable required to be set to the repository root, containing the current file
    devshellRoot = "/home/antoine/prog/ai-agent-sandboxing";
    # Variables that can be optionally modified
    devshellUser           = "agents";
    devshellHomeFolder     = "agentshome";
    devshellProjectsFolder = "projects";
    tmuxServer             = "julia-agent-dev";
    tmuxSession            = "julia_agents";

    # home manager configuration for tmux, zsh, julia, etc.
    devshellHomeManager = import ./devshell-home.nix { inherit pkgs home-manager devshellRoot devshellUser devshellHomeFolder; };
    homeDirectory = devshellHomeManager.config.home.homeDirectory;
    configFile = devshellHomeManager.config.xdg.configFile;

    jail = jail-nix.lib.init pkgs;
    julia-pkg = pkgs.julia-bin;
    claude-pkg = llm-agents.packages.${system}.claude-code;

    jailedAgents = import ./jailed-agents.nix { inherit pkgs jail julia-pkg claude-pkg devshellRoot devshellProjectsFolder devshellUser homeDirectory; };

  in
  {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        nixd zsh wget gawkInteractive ps gzip unzip gnutar
        (writeShellScriptBin "claude" ''exec jailed-claude "$@"'')
        (writeShellScriptBin "yolo-claude" ''exec jailed-claude --dangerously-skip-permissions "$@"'')
        (writeShellScriptBin "kaimon" ''exec jailed-kaimon "$@"'')
        (writeShellScriptBin "claude-connect-kaimon" ''exec jailed-claude mcp add --transport http --scope user kaimon http://localhost:2828/mcp'')

        (jailedAgents.makeJailedClaude { })
        (jailedAgents.makeJailedShell { extraPkgs = [ claude-pkg julia-pkg ]; })
        (jailedAgents.makeJailedJulia { })
        (jailedAgents.makeJailedKaimon { })
      ];

      shellHook = ''
        # Fail fast if devshellRoot doesn't exist — avoids silently creating directories at a wrong path.
        if [ ! -d "${devshellRoot}" ]; then
          echo "ERROR: devshellRoot does not exist: ${devshellRoot}" >&2
          exit 1
        fi

        # Require running from within devshellRoot, to avoid forgeting seting devshellRoot properly
        _cwd="$(pwd -P)"
        case "$_cwd/" in
          "${devshellRoot}/"*) ;;
          *)
            echo "ERROR: must be run from within devshellRoot = ${devshellRoot}, did you set it properly in flake.nix?" >&2
            echo "  current: $_cwd" >&2
            exit 1
            ;;
        esac
        unset _cwd

        # require tmux
        if ! command -v tmux >/dev/null 2>&1; then
          echo "ERROR: tmux is not installed on the host — install it via your OS package manager" >&2
          exit 1
        fi

        # Refuse to run inside any other tmux session — new-session cannot attach when nested.
        if [ -n "''${TMUX:-}" ]; then
          echo "ERROR: cannot start the tmux development shell within a tmux session — detach first (Ctrl-b d)" >&2
          exit 1
        fi

        # Activate home-manager config into the agentshome dir (never touches real $HOME).
        HOME=${homeDirectory} USER=${devshellUser} HOME_MANAGER_BACKUP_EXT=bak \
          ${devshellHomeManager.activationPackage}/activate

        # Create or reset the tmux session. -L creates an independant tmux server.
        tmux -L ${tmuxServer} kill-server 2>/dev/null || true
        tmux -L ${tmuxServer} -f ${configFile."tmux/tmux.conf".source} new-session -s ${tmuxSession} -c ${devshellRoot}/${devshellProjectsFolder}
      '';
    };
  });
}
