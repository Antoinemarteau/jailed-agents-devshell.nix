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
    julia-mcp = {
      url = "github:aplavin/julia-mcp";
      flake = false;
    };
    nixconfig.url = "github:Antoinemarteau/nixconfig";
  };

  outputs = { self, nixpkgs, flake-utils, home-manager, jail-nix, llm-agents, julia-mcp, nixconfig, ... }:
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
    devshellRoot = "/home/antoine/prog/agents";

    # Network whitelists
    claudeAllowedDomains = [ "anthropic.com" "claude.ai" "claude.com" "github.com" "githubusercontent.com" ];
    juliaAllowedDomains  = [ "julialang.org" "julialang.net" "github.com" "githubusercontent.com" ];

    guardedHostTools = [
      "git" "gh" "julia" "claude" "kaimon"          # the sandboxed workflow's tools
      "make" "npm" "node" "python" "python3" "pip"  # common project-code runners
      "uv" "conda" "docker" "apt"
    ];

    # Host paths no jail may bind, checked at eval time
    forbiddenBindPaths = [
      "${agentHomeDirectory}/.envrc"   # host direnv executes it
      "${agentHomeDirectory}/.direnv"  # host direnv sources its cache without re-approval
      "${devshellRoot}/${devshellHostHomeFolder}"  # host interactive $HOME (zsh/tmux startup files)
      "${devshellRoot}/nix_src"        # this flake: defines the jails themselves
      "${devshellRoot}/.git"           # repo hooks/config run by host git
      "${agentHomeDirectory}/.cache/julia-mcp-sock"  # per-instance julia-mcp listener sockets
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
              devshellHostHomeFolder devshellUser jailHomeDirectory forbiddenBindPaths;
      homeDirectory = agentHomeDirectory;
    };
    inherit (jailedAgents)
      makeJailed mkServerSocketOptions gitReadBinds nixLdBinds hostGitEnv saferHostGit
      hostHomeManager newAgentSession attachAgentSession guardHostTool;

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
      (add-runtime "mkdir -p ${agentHomeDirectory}/.cache/kaimon-jail-sock")
      (rw-bind "${agentHomeDirectory}/.cache/kaimon-jail-sock" "${jailHomeDirectory}/.cache/kaimon-jail-sock")
    ];

    kaimonClientLeg = "socat TCP-LISTEN:${toString kaimonPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailKaimonSock} 2>/dev/null &";
    kaimonServerLeg = "rm -f ${jailKaimonSock}; socat UNIX-LISTEN:${jailKaimonSock},fork,reuseaddr TCP:127.0.0.1:${toString kaimonPort} 2>/dev/null &";

    # for Kaimon <-> Julia communication
    kaimonCacheWriteBinds = with jail.combinators; [
      (add-runtime "mkdir -p ${agentHomeDirectory}/.cache/kaimon/sock")
      (rw-bind "${agentHomeDirectory}/.cache/kaimon" "${jailHomeDirectory}/.cache/kaimon")
    ];

    kaimonConfigWriteBinds = with jail.combinators; [
      (add-runtime "mkdir -p ${agentHomeDirectory}/.config/kaimon")
      (rw-bind "${agentHomeDirectory}/.config/kaimon" "${jailHomeDirectory}/.config/kaimon")
    ];

    juliaDepotReadBinds = with jail.combinators; [
      (ro-bind "${agentHomeDirectory}/.julia" "${jailHomeDirectory}/.julia")
    ];

    makeJailedKaimon = { extraPkgs ? [], name ? "jailed-kaimon" }:
      makeJailed {
        inherit name;
        exe = "~/.julia/bin/kaimon";
        extraPkgs = [ julia-pkg ] ++ extraPkgs;
        socatLegs = [ kaimonServerLeg ];
        network = false;
        options =
          juliaDepotReadBinds ++
          kaimonCacheWriteBinds ++
          kaimonBridgeBinds ++
          kaimonConfigWriteBinds;
      };


    ###########################################################################
    # jailed-claude
    ###########################################################################

    claude-pkg = llm-agents.packages.${system}.claude-code;

    claudeConfigWriteBinds = with jail.combinators; [
      # makes sure a writable and host persisted .claude.json file exists
      (add-runtime "[ -f ${agentHomeDirectory}/.claude.json ] || echo '{}' > ${agentHomeDirectory}/.claude.json")
      (rw-bind "${agentHomeDirectory}/.claude" "${jailHomeDirectory}/.claude")
      (rw-bind "${agentHomeDirectory}/.claude.json" "${jailHomeDirectory}/.claude.json")
    ];

    # proxiedNetwork = true : empty netns, internet only via the host allowlist proxy.
    # proxiedNetwork = false: full host network (for use on an isolated remote server).
    # The Claude<->Kaimon MCP socat bridge is present either way, since Kaimon always
    # runs in its own netns.
    makeJailedClaude = { extraPkgs ? [], name ? "jailed-claude", allowedDomains ? [],
                         proxiedNetwork ? false, extraArgs ? "" }:
      makeJailed {
        inherit name extraPkgs proxiedNetwork allowedDomains extraArgs;
        exe = claude-pkg;
        socatLegs = [ kaimonClientLeg ];
        network = !proxiedNetwork;
        options = claudeConfigWriteBinds ++ gitReadBinds ++ kaimonBridgeBinds ++ juliaMcpServerSocketOptions;
      };


    ###########################################################################
    # jailed-julia
    ###########################################################################

    julia-pkg = pkgs.julia-bin;

    juliaDepotWriteBinds = with jail.combinators; [
      (rw-bind "${agentHomeDirectory}/.julia" "${jailHomeDirectory}/.julia")
    ];

    # proxiedNetwork = true : empty netns, internet only via the host allowlist proxy
    #   (e.g. the Julia registries). proxiedNetwork = false: full host network.
    makeJailedJulia = { extraPkgs ? [], name ? "jailed-julia", allowedDomains ? [],
                        proxiedNetwork ? false }:
      makeJailed {
        inherit name extraPkgs proxiedNetwork allowedDomains;
        exe = julia-pkg;
        network = !proxiedNetwork;
        options = juliaDepotWriteBinds ++ kaimonCacheWriteBinds ++ nixLdBinds;
      };


    ###########################################################################
    # jailed-julia-mcp
    # julia-mcp stdio MCP server in its own jail, launched by Claude on demand.
    ###########################################################################

    jailJuliaMcpSock = "${jailHomeDirectory}/.cache/julia-mcp-sock/mcp.sock";

    makeJailedJuliaMcp = { extraPkgs ? [], name ? "jailed-julia-mcp", allowedDomains ? [],
                           proxiedNetwork ? false }:
      makeJailed {
        inherit name allowedDomains proxiedNetwork;
        exe = pkgs.writeShellScriptBin "julia-mcp-server" ''
          exec python3 -u ${julia-mcp}/server.py "$@"
        '';
        extraPkgs = [ julia-pkg (pkgs.python3.withPackages (ps: [ ps.mcp ])) ] ++ extraPkgs;
        network = !proxiedNetwork;
        options = juliaDepotWriteBinds ++ nixLdBinds;
      };

    jailedJuliaMcp = makeJailedJuliaMcp {
      proxiedNetwork = true;
      allowedDomains = juliaAllowedDomains;
    };

    # Socket activation for the claude jails: an idle host-side listener holds a
    # per-instance socket, bound into the jail at jailJuliaMcpSock; each connection
    # from Claude spawns jailedJuliaMcp on its stdio, and the listener dies with the
    # jail. Only the single socket file enters the jail — never bind the
    # .cache/julia-mcp-sock dir itself (cf. forbiddenBindPaths).
    juliaMcpServerSocketOptions =
      mkServerSocketOptions "julia-mcp" jailedJuliaMcp jailJuliaMcpSock;


    ###########################################################################
    # jail-debug
    # for debugging other jails
    ###########################################################################

    nvim-pkg = nixconfig.packages.${system}.default;

    # devshell-home.nix's zsh config (oh-my-zsh, aliases, history), instantiated for
    # the shell jails: never activated — only its build-time `home-files` output is
    # consumed, ro-bound straight into the jails below.
    jailShellHomeManager = import ./devshell-home.nix {
      inherit pkgs home-manager devshellUser;
      homeDirectory = jailHomeDirectory;
    };
    zshHomeFiles = jailShellHomeManager.config.home-files;

    makeJailDebug = { extraPkgs ? [], name ? "jail-debug" }:
      makeJailed {
        inherit name;
        exe = pkgs.zsh;
        extraPkgs = with pkgs; [ zsh ncurses zshHomeFiles ] ++ extraPkgs;
        network = true;
        options = with jail.combinators;
          claudeConfigWriteBinds ++
          gitReadBinds ++
          juliaDepotWriteBinds ++
          kaimonConfigWriteBinds ++
          kaimonCacheWriteBinds ++
          nixLdBinds ++ [
            (ro-bind "${zshHomeFiles}/.config/zsh" "${jailHomeDirectory}/.config/zsh")
            (ro-bind "${zshHomeFiles}/.config/starship.toml" "${jailHomeDirectory}/.config/starship.toml")
            # persistent zsh history, shared across jailed-shell invocations
            (add-runtime "mkdir -p ${agentHomeDirectory}/.local/state")
            (rw-bind "${agentHomeDirectory}/.local/state" "${jailHomeDirectory}/.local/state") # zsh history
            (set-env "ZDOTDIR" "${jailHomeDirectory}/.config/zsh")
            (set-env "LANG" "C.UTF-8")
            (add-runtime ''
              if [ -n "''${TERMINFO-}" ] && [ -d "''${TERMINFO-}" ]; then
                RUNTIME_ARGS+=(--ro-bind "$TERMINFO" /run/host-terminfo)
              fi
            '')
            (set-env "TERMINFO_DIRS" "/run/host-terminfo:${pkgs.ncurses}/share/terminfo")
          ];
      };


    ###########################################################################
    # jailed-shell
    # minimal human-run shell for reviewing agent work and pushing it with the
    # personal git credentials from .hosthome/
    ###########################################################################

    hostHomeDir = "${devshellRoot}/${devshellHostHomeFolder}";

    hostGitFiles = [
      "${hostHomeDir}/.gitconfig"
      "${hostHomeDir}/.git-credentials"
    ];
    hostGitBinds = with jail.combinators; [
      (try-ro-bind "${hostHomeDir}/.gitconfig" "${jailHomeDirectory}/.gitconfig")
      (try-ro-bind "${hostHomeDir}/.git-credentials" "${jailHomeDirectory}/.git-credentials")
    ];

    # A Julia depot for jailed-shell alone, so the IDE can run language servers.
    hostJuliaDepot = "${hostHomeDir}/.julia";
    hostJuliaDepotBind = with jail.combinators; [
      (add-runtime "mkdir -p ${hostJuliaDepot}")
      (rw-bind "${hostJuliaDepot}" "${jailHomeDirectory}/.julia")
    ];

    # override g:clipboard to OSC 52 so yanks reach tmux and the terminal
    nvim-pkg =
      let osc52 = pkgs.writeText "osc52-clipboard.lua" ''
        vim.opt.clipboard = 'unnamedplus'
        local osc52 = require('vim.ui.clipboard.osc52')
        vim.g.clipboard = {
          name = 'OSC 52',
          copy = {
            ['+'] = osc52.copy('+'),
            ['*'] = osc52.copy('*'),
          },
          paste = {
            ['+'] = osc52.paste('+'),
            ['*'] = osc52.paste('*'),
          },
        }
      '';
      in pkgs.writeShellScriptBin "nvim" ''
        exec ${pkgs.lib.getExe pkgs.neovim} -c "luafile ${osc52}" "$@"
      '';

    makeJailedShell = { extraPkgs ? [], name ? "jailed-shell" }:
      makeJailed {
        inherit name;
        exe = pkgs.zsh;
        extraPkgs = [ pkgs.zsh pkgs.ncurses zshHomeFiles ]
          ++ extraPkgs ++ [ saferHostGit ];
        network = true;
        trustedBindPaths = hostGitFiles ++ [ hostJuliaDepot ];
        options = with jail.combinators;
          hostGitBinds ++
          hostJuliaDepotBind ++
          hostGitEnv ++ [
            (ro-bind "${zshHomeFiles}/.config/zsh" "${jailHomeDirectory}/.config/zsh")
            (ro-bind "${zshHomeFiles}/.config/starship.toml" "${jailHomeDirectory}/.config/starship.toml")
            (add-runtime "mkdir -p ${agentHomeDirectory}/.local/state")
            (rw-bind "${agentHomeDirectory}/.local/state" "${jailHomeDirectory}/.local/state")
            (set-env "ZDOTDIR" "${jailHomeDirectory}/.config/zsh")
            (set-env "LANG" "C.UTF-8")
            (add-runtime ''
              if [ -n "''${TERMINFO-}" ] && [ -d "''${TERMINFO-}" ]; then
                RUNTIME_ARGS+=(--ro-bind "$TERMINFO" /run/host-terminfo)
              fi
            '')
            (set-env "TERMINFO_DIRS" "/run/host-terminfo:${pkgs.ncurses}/share/terminfo")
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
      (writeShellScriptBin "claude-connect-julia-mcp" ''exec jailed-claude mcp add --scope user julia -- socat - UNIX-CONNECT:${jailJuliaMcpSock}'')

        # jailed-claude: claude-code with skip permission and restricted network
        (makeJailedClaude {
          name = "jailed-claude";
          extraPkgs = [ ];
          extraArgs = "--dangerously-skip-permissions";
          proxiedNetwork = true;
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
          proxiedNetwork = true;
          allowedDomains = juliaAllowedDomains;
        })

        # yolo-jailed-julia: julia with full network access
        (makeJailedJulia {
          name = "yolo-jailed-julia";
          extraPkgs = [ python3 ];
        })

        # jailed-kaimon: no network access
        (makeJailedKaimon { })

        # jailed-julia-mcp: julia-mcp MCP server, egress restricted to the Julia
        # registries; spawned by the claude jails on demand, exposed for debugging
        jailedJuliaMcp

        # jailed-shell: minimal shell with the personal git credentials for reviewing/pushing agent work
        (makeJailedShell {
          extraPkgs = [ gh
            # nvim and the CLIs it expects (found via :checkhealth), julia is for language servers
            nvim-pkg julia-pkg fd tar
          ];
        })

        # jail-debug: zsh with all dev. tools and all folders other jail have binded for debugging
        (makeJailDebug {
          extraPkgs = [
            nvim-pkg claude-pkg julia-pkg python3 gh man gzip unzip gnutar
          ];
        })
      ]
      ++ builtins.map guardHostTool guardedHostTools;
    };
  });
}
