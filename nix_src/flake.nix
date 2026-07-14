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

    ###########################################################################
    # Main flake parameters #
    ###########################################################################

    # NECESSARY TO SET to the repository root, containing the current file
    devshellRoot = "/home/antoine/prog/ai-agent-sandboxing";

    # Network whitelists
    claudeAllowedDomains = [ "anthropic.com" "claude.ai" "claude.com" "github.com" "githubusercontent.com" ];
    juliaAllowedDomains  = [ "julialang.org" "julialang.net" "github.com" "githubusercontent.com" ];

    guardedHostTools = [
      "git" "gh" "julia" "claude" "kaimon"          # the sandboxed workflow's tools
      "make" "npm" "node" "python" "python3" "pip"  # common project-code runners
      "uv" "conda" "docker" "apt"
    ];


    ###########################################################################
    # Directory architecture related variables #
    ###########################################################################

    devshellUser           = "agents";         # username in the jail
    devshellHomeFolder     = "agentshome";     # host dir holding the jail-bound agent data
    devshellHostHomeFolder = ".hosthome";       # host dir for the interactive devshell home (zsh/tmux/nvim)
    agentHomeDirectory = "${devshellRoot}/${devshellHomeFolder}";
    jailHomeDirectory      = "/home/${devshellUser}"; # $HOME as seen from inside every jail

    ###########################################################################
    # jail-nix library helpers
    ###########################################################################

    jail = jail-nix.lib.init pkgs;

    jailedAgents = import ./jailed-agents.nix {
      inherit pkgs jail home-manager devshellRoot devshellHomeFolder
              devshellHostHomeFolder devshellUser jailHomeDirectory;
      homeDirectory = agentHomeDirectory;
    };
    inherit (jailedAgents)
      makeJailed gitReadBinds nixLdBinds hostHomeManager
      newAgentSession attachAgentSession guardHostTool;

    tmux-pkg = hostHomeManager.config.programs.tmux.package;


    ###########################################################################
    # jailed-kaimon:                                                          #
    ###########################################################################

    # The Claude<->Kaimon MCP channel is bridged the same way over a shared unix
    # socket, so localhost:2828 keeps working once both jails leave the host netns.

    kaimonPort = 2828; # in-jail TCP for Kaimon's MCP server
    jailKaimonSock = "${jailHomeDirectory}/.cache/kaimon-jail-sock/kaimon.sock";

    # Shared dir for the Claude<->Kaimon MCP socket
    kaimonBridgeBinds = with jail.combinators; [
      (rw-bind "${agentHomeDirectory}/.cache/kaimon-jail-sock" "${jailHomeDirectory}/.cache/kaimon-jail-sock")
    ];

    kaimonClientLeg = "socat TCP-LISTEN:${toString kaimonPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailKaimonSock} 2>/dev/null &";
    kaimonServerLeg = "rm -f ${jailKaimonSock}; socat UNIX-LISTEN:${jailKaimonSock},fork,reuseaddr TCP:127.0.0.1:${toString kaimonPort} 2>/dev/null &";

    # for Kaimon <-> Julia communication
    kaimonCacheWriteBinds = with jail.combinators; [
      (rw-bind "${agentHomeDirectory}/.cache/kaimon" "${jailHomeDirectory}/.cache/kaimon")
    ];

    kaimonConfigWriteBinds = with jail.combinators; [
      (rw-bind "${agentHomeDirectory}/.config/kaimon" "${jailHomeDirectory}/.config/kaimon")
    ];

    juliaDepotReadBinds = with jail.combinators; [
      (ro-bind "${agentHomeDirectory}/.julia" "${jailHomeDirectory}/.julia")
    ];

    makeJailedKaimon = { extraPkgs ? [], name ? "jailed-kaimon" }:
      makeJailed {
        inherit name extraPkgs;
        exe = "~/.julia/bin/kaimon";
        socatLegs = [ kaimonServerLeg ];
        network = false;
        preHook = ''
          [ -d ${agentHomeDirectory} ]
          mkdir -p ${agentHomeDirectory}/.cache/kaimon/sock
          mkdir -p ${agentHomeDirectory}/.cache/kaimon-jail-sock
          mkdir -p ${agentHomeDirectory}/.config/kaimon
        '';
        options = with jail.combinators;
          juliaDepotReadBinds ++
          kaimonCacheWriteBinds ++
          kaimonBridgeBinds ++
          kaimonConfigWriteBinds ++ [
            (add-pkg-deps [ julia-pkg ])
          ];
      };


    ###########################################################################
    # jailed-claude
    ###########################################################################

    claude-pkg = llm-agents.packages.${system}.claude-code;

    claudeConfigWriteBinds = with jail.combinators; [
      (rw-bind "${agentHomeDirectory}/.claude" "${jailHomeDirectory}/.claude")
      (rw-bind "${agentHomeDirectory}/.claude.json" "${jailHomeDirectory}/.claude.json")
    ];

    # restrictNetwork = true : empty netns, internet only via the host allowlist proxy.
    # restrictNetwork = false: full host network (for use on an isolated remote server).
    # The Claude<->Kaimon MCP socat bridge is present either way, since Kaimon always
    # runs in its own netns.
    makeJailedClaude = { extraPkgs ? [], name ? "jailed-claude", allowedDomains ? [],
                         restrictNetwork ? false, extraArgs ? "" }:
      makeJailed {
        inherit name extraPkgs restrictNetwork allowedDomains extraArgs;
        exe = claude-pkg;
        socatLegs = [ kaimonClientLeg ];
        network = !restrictNetwork;
        preHook = ''
          # makes sure a writable and host persisted .claude.json file exists
          [ -f ${agentHomeDirectory}/.claude.json ] || echo '{}' > ${agentHomeDirectory}/.claude.json
          # shared dir for the Claude<->Kaimon MCP socket
          mkdir -p ${agentHomeDirectory}/.cache/kaimon-jail-sock
        '';
        options = claudeConfigWriteBinds ++ gitReadBinds ++ kaimonBridgeBinds;
      };


    ###########################################################################
    # jailed-julia
    ###########################################################################

    julia-pkg = pkgs.julia-bin;

    juliaDepotWriteBinds = with jail.combinators; [
      (rw-bind "${agentHomeDirectory}/.julia" "${jailHomeDirectory}/.julia")
    ];

    # restrictNetwork = true : empty netns, internet only via the host allowlist proxy
    #   (e.g. the Julia registries). restrictNetwork = false: full host network.
    makeJailedJulia = { extraPkgs ? [], name ? "jailed-julia", allowedDomains ? [],
                        restrictNetwork ? false }:
      makeJailed {
        inherit name extraPkgs restrictNetwork allowedDomains;
        exe = julia-pkg;
        network = !restrictNetwork;
        preHook = ''
          [ -d ${agentHomeDirectory} ]
          mkdir -p ${agentHomeDirectory}/.cache/kaimon/sock
        '';
        options = juliaDepotWriteBinds ++ kaimonCacheWriteBinds ++ nixLdBinds;
      };


    ###########################################################################
    # jailed-shell
    # for safely working within projects/ and debugging other jails
    ###########################################################################

    nvim-pkg = nixconfig.packages.${system}.default;

    # devshell-home.nix's zsh config (oh-my-zsh, aliases, history), instantiated for
    # jailed-shell: never activated — only its build-time `home-files` output is
    # consumed, ro-bound straight into the jail below.
    jailShellHomeManager = import ./devshell-home.nix {
      inherit pkgs home-manager devshellUser;
      homeDirectory = jailHomeDirectory;
    };
    zshHomeFiles = jailShellHomeManager.config.home-files;

    makeJailedShell = { extraPkgs ? [], name ? "jailed-shell" }:
      makeJailed {
        inherit name extraPkgs;
        exe = pkgs.zsh;
        network = true;
        preHook = ''
          # makes sure a writable and host persisted .claude.json file exists
          [ -f ${agentHomeDirectory}/.claude.json ] || echo '{}' > ${agentHomeDirectory}/.claude.json
          # similar with Kaimon config folders
          mkdir -p ${agentHomeDirectory}/.cache/kaimon/sock
          mkdir -p ${agentHomeDirectory}/.config/kaimon
          # persistent zsh history, shared across jailed-shell invocations
          mkdir -p ${agentHomeDirectory}/.local/state
        '';
        options = with jail.combinators;
          claudeConfigWriteBinds ++
          gitReadBinds ++
          juliaDepotWriteBinds ++
          kaimonConfigWriteBinds ++
          kaimonCacheWriteBinds ++
          nixLdBinds ++ [
            (ro-bind "${zshHomeFiles}/.config/zsh" "${jailHomeDirectory}/.config/zsh")
            (rw-bind "${agentHomeDirectory}/.local/state" "${jailHomeDirectory}/.local/state") # zsh history
            (set-env "ZDOTDIR" "${jailHomeDirectory}/.config/zsh")
            (set-env "LANG" "C.UTF-8")
            (set-env "TERMINFO_DIRS" "${pkgs.ncurses}/share/terminfo")
            (add-pkg-deps [ pkgs.zsh pkgs.ncurses zshHomeFiles ])
          ];
      };

  in
  {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [

        tmux-pkg zsh
        newAgentSession
        attachAgentSession
        (writeShellScriptBin "claude-connect-kaimon" ''exec jailed-claude mcp add --transport http --scope user kaimon http://localhost:2828/mcp'')

        # jailed-claude: claude-code with skip permission and restricted network
        (makeJailedClaude {
          name = "jailed-claude";
          extraPkgs = [ ];
          extraArgs = "--dangerously-skip-permissions";
          restrictNetwork = true;
          allowedDomains = claudeAllowedDomains;
        })

        # yolo-jailed-claude: claude-code with skip permission full network access
        (makeJailedClaude {
          name = "yolo-jailed-claude";
          extraPkgs = [ ];
          extraArgs = "--dangerously-skip-permissions";
        })

        # jailed-julia: julia with restricted network access
        (makeJailedJulia {
          name = "jailed-julia";
          extraPkgs = [ python3 ];
          restrictNetwork = true;
          allowedDomains = juliaAllowedDomains;
        })

        # yolo-jailed-julia: julia with full network access
        (makeJailedJulia {
          name = "yolo-jailed-julia";
          extraPkgs = [ python3 ];
        })

        # jailed-kaimon: no network access
        (makeJailedKaimon { })

        # jailed-shell: zsh with all dev. tools and all folders other jail have binded for debugging
        (makeJailedShell {
          extraPkgs = [
            nvim-pkg claude-pkg julia-pkg python3 gh man gzip unzip gnutar
          ];
        })
      ]
      ++ builtins.map guardHostTool guardedHostTools;
    };
  });
}
