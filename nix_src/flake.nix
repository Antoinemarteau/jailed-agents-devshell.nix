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
    inherit (pkgs.lib) getExe;

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

    # KaimonGate TCP bridge. The REPL serves the KaimonGate over fixed TCP ports.
    kaimonGatePort       = 2829;  # gate ROUTER socket (eval request/reply)
    kaimonGateStreamPort = 2830;  # gate XPUB socket   (stdout/stderr stream)
    jailGateSock       = "${jailHomeDirectory}/.cache/kaimon/gate.sock";
    jailGateStreamSock = "${jailHomeDirectory}/.cache/kaimon/gate-stream.sock";

    gateServerLegs = [
      "rm -f ${jailGateSock}; socat UNIX-LISTEN:${jailGateSock},fork,reuseaddr TCP:127.0.0.1:${toString kaimonGatePort} 2>/dev/null &"
      "rm -f ${jailGateStreamSock}; socat UNIX-LISTEN:${jailGateStreamSock},fork,reuseaddr TCP:127.0.0.1:${toString kaimonGateStreamPort} 2>/dev/null &"
    ];
    gateClientLegs = [
      "socat TCP-LISTEN:${toString kaimonGatePort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailGateSock} 2>/dev/null &"
      "socat TCP-LISTEN:${toString kaimonGateStreamPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailGateStreamSock} 2>/dev/null &"
    ];
    # Set on the REPL so its startup.jl `KaimonGate.serve()` binds TCP (fixed ports,
    # so the bridge can target them) instead of a discover-by-file IPC socket.
    gateTcpEnv = with jail.combinators; [
      (set-env "KAIMON_GATE_PORT"        (toString kaimonGatePort))
      (set-env "KAIMON_GATE_STREAM_PORT" (toString kaimonGateStreamPort))
    ];

    # KaimonGate TCP configuration for jailed-julia-repl
    gateAutoConnectSeed = with jail.combinators; [
      (add-runtime ''
        _tcp_gates="${agentHomeDirectory}/.config/kaimon/tcp_gates.json"
        if [ ! -e "$_tcp_gates" ]; then
          mkdir -p "$(dirname "$_tcp_gates")"
          cat > "$_tcp_gates" <<'JSON'
{
  "tcp_gates": [
    {
      "host": "kaimon-gate",
      "port": ${toString kaimonGatePort},
      "name": "jailed-julia-repl",
      "enabled": true,
      "token": "",
      "stream_port": 0,
      "server_key": ""
    }
  ]
}
JSON
        fi
      '')
    ];

    juliaDepotReadBinds = with jail.combinators; [
      (ro-bind "${agentHomeDirectory}/.julia" "${jailHomeDirectory}/.julia")
    ];

    makeJailedKaimon = { extraPkgs ? [], name ? "jailed-kaimon" }:
      makeJailed {
        inherit name;
        exe = "~/.julia/bin/kaimon";
        extraPkgs = [ julia-pkg ] ++ extraPkgs;
        socatLegs = [ kaimonServerLeg ] ++ gateClientLegs;
        network = false;
        # `kaimon-gate` resolves to loopback but is not the literal `localhost`/`127.*`,
        # so Kaimon treats the bridged gate as a remote peer (see KaimonGate TCP bridge).
        extraHosts = "127.0.0.1 kaimon-gate\n";
        options =
          juliaDepotReadBinds ++
          kaimonCacheWriteBinds ++
          kaimonBridgeBinds ++
          kaimonConfigWriteBinds ++
          gateAutoConnectSeed;
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

    # shared dtach socket so vim-slime can push code to the REPL;
    slimeSocket = "${jailHomeDirectory}/.cache/slime/julia.sock";
    slimeSocketBinds = with jail.combinators; [
      (add-runtime "mkdir -p ${agentHomeDirectory}/.cache/slime")
      (rw-bind "${agentHomeDirectory}/.cache/slime" "${jailHomeDirectory}/.cache/slime")
    ];

    # proxiedNetwork = true : empty netns, internet only via the host allowlist proxy
    #   (e.g. the Julia registries). proxiedNetwork = false: full host network.
    # slimeSocket != null wraps the REPL in dtach -A so it can receive vim-slime's code;
    makeJailedJulia = { extraPkgs ? [], name ? "jailed-julia", allowedDomains ? [],
                        proxiedNetwork ? false, slimeSocket ? null }:
      makeJailed {
        inherit name proxiedNetwork allowedDomains;
        exe = if slimeSocket == null then julia-pkg
              else pkgs.writeShellScriptBin "julia" ''
                exec ${getExe pkgs.dtach} -A ${slimeSocket} ${getExe julia-pkg} -t auto "$@"
              '';
        extraPkgs = extraPkgs ++ [ pkgs.dtach ];
        network = !proxiedNetwork;
        socatLegs = pkgs.lib.optionals (slimeSocket != null) gateServerLegs;
        options = juliaDepotWriteBinds ++ kaimonCacheWriteBinds ++ nixLdBinds
          ++ pkgs.lib.optionals (slimeSocket != null) (slimeSocketBinds ++ gateTcpEnv);
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

    # wrap the personal flake's nvim (post-init, so both overrides beat the imported config):
    #  - override g:clipboard to OSC 52 so yanks reach tmux and the terminal
    #  - route vim-slime sends to the jailed-julia REPL's dtach socket, only inside jailed-shell
    nvim-pkg =
      let
        personalNvim = nixconfig.packages.${system}.default;
        osc52 = pkgs.writeText "osc52-clipboard.lua" ''
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
        slimeOverride = pkgs.writeText "slime-override.vim" ''
          if !empty($SLIME_DTACH_SOCKET)
            function! SlimeOverrideValidEnv() abort
              return 1
            endfunction
            function! SlimeOverrideValidConfig(config, ...) abort
              return 1
            endfunction
            function! SlimeOverrideSend(config, text) abort
              call system('${pkgs.dtach}/bin/dtach -p ' . shellescape($SLIME_DTACH_SOCKET), a:text)
            endfunction
          endif
        '';
      in pkgs.writeShellScriptBin "nvim" ''
        exec ${getExe personalNvim} -c "luafile ${osc52}" -c "source ${slimeOverride}" "$@"
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
          hostGitEnv ++
          slimeSocketBinds ++ [
            (ro-bind "${zshHomeFiles}/.config/zsh" "${jailHomeDirectory}/.config/zsh")
            (ro-bind "${zshHomeFiles}/.config/starship.toml" "${jailHomeDirectory}/.config/starship.toml")
            (add-runtime "mkdir -p ${agentHomeDirectory}/.local/state")
            (rw-bind "${agentHomeDirectory}/.local/state" "${jailHomeDirectory}/.local/state")
            (set-env "ZDOTDIR" "${jailHomeDirectory}/.config/zsh")
            (set-env "LANG" "C.UTF-8")
            (set-env "SLIME_DTACH_SOCKET" slimeSocket)
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

        # jailed-julia-repl: same as jailed-julia but under dtach, so vim-slime in
        # jailed-shell can push code to it; this is what the repl tmux window launches
        (makeJailedJulia {
          name = "jailed-julia-repl";
          extraPkgs = [ python3 nvim-pkg ];
          proxiedNetwork = true;
          allowedDomains = juliaAllowedDomains;
          slimeSocket = slimeSocket;
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
            # nvim and the CLIs it expects (found via :checkhealth),
            # julia is for language servers, dtach drives the jailed-julia-repl slime socket
            nvim-pkg julia-pkg fd gnutar dtach
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
