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
    nixconfig.url = "github:Antoinemarteau/nixconfig";
  };

  outputs = { self, nixpkgs, flake-utils, home-manager, jail-nix, llm-agents, nixconfig, ... }:
  flake-utils.lib.eachDefaultSystem (system:
  let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    # Variable required to be set to the repository root, containing the current file
    devshellRoot = "/home/antoine/prog/ai-agent-sandboxing";
    # Variables that can be optionally modified
    devshellUser           = "agents";         # username in the jail
    devshellHomeFolder     = "agentshome";     # host dir holding the jail-bound agent data
    devshellHostHomeFolder = ".hosthome";       # host dir for the interactive devshell home (zsh/tmux/nvim)
    devshellProjectsFolder = "projects";       # host dir for the coding projects
    agentHomeDirectory = "${devshellRoot}/${devshellHomeFolder}";
    tmuxServer             = "julia_agents";   # tmux server name
    tmuxSessionFile        = "${devshellRoot}/${devshellHostHomeFolder}/.config/tmux/default-session.conf"; # user-editable window layout

    # home manager configuration for the interactive devshell home (tmux, zsh, julia,
    # etc.), activated into <devshellRoot>/.hosthome. Kept out of agentshome so no host
    # dotfiles live in a tree that is bound into the jails.
    devshellHomeManager = import ./devshell-home.nix { inherit pkgs home-manager devshellRoot devshellUser devshellHostHomeFolder nvim-pkg; };
    hostHomeDirectory = devshellHomeManager.config.home.homeDirectory;
    configFile = devshellHomeManager.config.xdg.configFile;
    tmux-pkg = devshellHomeManager.config.programs.tmux.package;

    jail = jail-nix.lib.init pkgs;
    julia-pkg = pkgs.julia-bin;
    claude-pkg = llm-agents.packages.${system}.claude-code;
    nvim-pkg = nixconfig.packages.${system}.default;

    jailedAgents = import ./jailed-agents.nix { inherit pkgs jail julia-pkg claude-pkg devshellRoot devshellProjectsFolder devshellUser; homeDirectory = agentHomeDirectory; };

    # Launch (or reset) a tmux development session for the current project. This is the
    # explicit entry point: entering the devShell (via direnv or `nix develop`) only puts
    # the tools on PATH — running this builds and attaches the session.
    newAgentSession = pkgs.writeShellScriptBin "new_agent_session" ''
      # Require running from within <devshellRoot>/projects, where the jailed agents operate.
      _projects="${devshellRoot}/${devshellProjectsFolder}"
      if [ ! -d "$_projects" ]; then
        echo "ERROR: devshellRoot in flake.nix is '${devshellRoot}'," >&2
        echo "  but its projects directory ($_projects) does not exist." >&2
        echo "  set devshellRoot to this repo's absolute path in flake.nix, then reload the env." >&2
        exit 1
      fi
      _cwd="$(pwd -P)"
      case "$_cwd/" in
        "$(realpath "$_projects")/"*) ;;
        *)
          echo "ERROR: new_agent_session must be run from within $_projects" >&2
          echo "  current: $_cwd" >&2
          exit 1
          ;;
      esac
      _session="$(basename "$_cwd")"
      _session="''${_session//[^a-zA-Z0-9_-]/_}"

      # The session windows launch jailed agents from PATH; ensure the devShell env is loaded.
      if ! command -v jailed-kaimon >/dev/null 2>&1; then
        echo "ERROR: devShell tools not on PATH — enter the env first (direnv, or 'nix develop ${devshellRoot}/nix_src')" >&2
        exit 1
      fi

      # Refuse to run inside any other tmux session — new-session cannot attach when nested.
      if [ -n "''${TMUX:-}" ]; then
        echo "ERROR: cannot start the tmux development session within a tmux session — detach first (Ctrl-b d)" >&2
        exit 1
      fi

      # Activate home-manager config into the .hosthome dir (never touches real $HOME).
      HOME=${hostHomeDirectory} USER=${devshellUser} HOME_MANAGER_BACKUP_EXT=bak \
        ${devshellHomeManager.activationPackage}/activate

      # Create or reset the tmux session, then apply the user-editable window
      # layout. @proj is the project dir.
      _layout="${tmuxSessionFile}"
      if [ ! -f "$_layout" ]; then
        echo "ERROR: tmux session file not found: $_layout" >&2
        exit 1
      fi
      tmux -L ${tmuxServer} kill-session -t "=$_session" 2>/dev/null || true
      tmux -L ${tmuxServer} -f ${configFile."tmux/tmux.conf".source} new-session -d -s "$_session" -c "$_cwd"
      tmux -L ${tmuxServer} set-option  -t "$_session" @proj "$_cwd"
      tmux -L ${tmuxServer} source-file -t "$_session:" "$_layout"
      tmux -L ${tmuxServer} attach-session -t "$_session"
    '';

    attachAgentSession = pkgs.writeShellScriptBin "attach_agent_session" ''
      _session="$(basename "$(pwd -P)")"
      _session="''${_session//[^a-zA-Z0-9_-]/_}"

      # Refuse to attach inside another tmux session — attach cannot nest.
      if [ -n "''${TMUX:-}" ]; then
        echo "ERROR: cannot attach within a tmux session — detach first (Ctrl-b d)" >&2
        exit 1
      fi

      if ! tmux -L ${tmuxServer} has-session -t "=$_session" 2>/dev/null; then
        echo "ERROR: no tmux session '$_session' for this folder — start one with new_agent_session" >&2
        exit 1
      fi
      tmux -L ${tmuxServer} attach-session -t "=$_session"
    '';

    # Directories the sandboxed agents can write to. The interactive devshell home
    # lives in a separate tree (.hosthome/), so its startup files can never become
    # agent-writable.
    agentWritableDirs = [
      "${devshellRoot}/${devshellProjectsFolder}"
      "${agentHomeDirectory}/.claude"
      "${agentHomeDirectory}/.julia"
      "${agentHomeDirectory}/.cache/kaimon"
      "${agentHomeDirectory}/.config/kaimon"
    ];

    # Shadow a host dev tool in agent writable directories. This is a
    # footgun-reducer, NOT a security boundary: absolute paths (/usr/bin/git)
    # and tools that use git without exec'ing it (libgit2, gh's internal git)
    # bypass it.
    guardHostTool = name: pkgs.writeShellScriptBin name ''
      _cwd="$(${pkgs.coreutils}/bin/pwd -P)/"
      for _t in ${pkgs.lib.escapeShellArgs agentWritableDirs}; do
        case "$_cwd" in
          "$(${pkgs.coreutils}/bin/realpath -m "$_t")/"*)
            echo "⛔ '${name}' is disabled here: this tree is written by the sandboxed agents." >&2
            echo "   Running host '${name}' could execute agent-planted hooks/config on your host." >&2
            echo "   Use the jailed tools, or run '${name}' from inside 'jailed-shell', or from outside the sandbox after reviewing the diff." >&2
            exit 1 ;;
        esac
      done
      # Outside any agent-writable tree: hand off to the real host tool (skip this wrapper).
      readarray -t _paths < <(type -aP ${name})
      _real="''${_paths[1]:-}"
      if [ -z "$_real" ]; then
        echo "${name}: no host '${name}' found on PATH" >&2
        exit 127
      fi
      exec "$_real" "$@"
    '';

    guardedHostTools = [
      "git" "gh" "julia" "claude" "kaimon"          # the sandboxed workflow's tools
      "make" "npm" "node" "python" "python3" "pip"  # common project-code runners
      "uv" "conda" "docker" "apt"
    ];

  in
  {
    devShells.default = pkgs.mkShell {
      NIX_LD = pkgs.stdenv.cc.bintools.dynamicLinker;
      NIX_LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc pkgs.zlib ];

      packages = with pkgs; [
        tmux-pkg nixd zsh wget gawkInteractive ps gzip unzip gnutar
        (writeShellScriptBin "claude-connect-kaimon" ''exec jailed-claude mcp add --transport http --scope user kaimon http://localhost:2828/mcp'')

        (jailedAgents.makeJailedClaude {
          name = "jailed-claude";
          extraPkgs = [ mcp-nixos ];
          extraArgs = "--dangerously-skip-permissions";
          restrictNetwork = true;
        })
        (jailedAgents.makeJailedClaude {
          name = "yolo-jailed-claude";
          extraPkgs = [ mcp-nixos ];
          extraArgs = "--dangerously-skip-permissions";
        })
        (jailedAgents.makeJailedShell {
          extraPkgs = [
            claude-pkg julia-pkg python3 gh mcp-nixos man less ];
        })
        (jailedAgents.makeJailedJulia { extraPkgs = [ python3 ]; })
        (jailedAgents.makeJailedJulia { extraPkgs = [ python3 ]; network = true; name = "jailed-julia-net"; })
        (jailedAgents.makeJailedKaimon { })

        newAgentSession
        attachAgentSession
      ]
      ++ builtins.map guardHostTool guardedHostTools;
    };
  });
}
