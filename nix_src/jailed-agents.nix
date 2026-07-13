{ pkgs, jail, julia-pkg, claude-pkg, devshellRoot, devshellProjectsFolder, devshellUser, homeDirectory }:

let
  inherit (pkgs.lib) getExe getExe';

  commonPkgs = with pkgs; [
    bashInteractive
    less
    curl
    # wget          # redundant with curl
    jq
    git
    socat           # tcp<->unix bridges for the network/MCP sockets
    which
    ripgrep
    gnugrep
    less
    # gawkInteractive  # awk text processor, not required
    ps              # required by Kaimon
    findutils
    # gzip          # archive tools, not required by Claude Code or Julia
    # unzip
    # gnutar
    diffutils
  ];

  jailHomeDirectory = "/home/${devshellUser}";

  net = import ./network-restrictions.nix { inherit pkgs jail jailHomeDirectory homeDirectory; };
  inherit (net)
    jailNetProxy jailProxySock proxyClientLeg kaimonClientLeg kaimonServerLeg
    restrictedNetOptions kaimonBridgeBinds localhostResolveBinds;

  # Build a jail launcher: run the given in-jail socat leg snippets, then exec the program.
  mkLauncher = name: exe: legs: pkgs.writeShellScriptBin name ''
    ${pkgs.lib.concatStringsSep "\n" legs}
    exec ${exe} "$@"
  '';

  commonJailOptions = with jail.combinators; [
    time-zone
    no-new-session
    mount-cwd
    (set-env "USER" devshellUser)
    (set-env "HOME" jailHomeDirectory)
    # writable tmpfs at /home/agents so programs can create transient files (e.g. lock files) in $HOME;
    (tmpfs jailHomeDirectory)
    (add-pkg-deps commonPkgs)
  ];

  claudeConfigWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.claude" "${jailHomeDirectory}/.claude")
    (rw-bind "${homeDirectory}/.claude.json" "${jailHomeDirectory}/.claude.json")
  ];

  gitReadBinds = with jail.combinators; [
    (try-ro-bind "${homeDirectory}/.gitconfig" "${jailHomeDirectory}/.gitconfig")
    (try-ro-bind "${homeDirectory}/.git-credentials" "${jailHomeDirectory}/.git-credentials")
  ];

  juliaDepotWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.julia" "${jailHomeDirectory}/.julia")
  ];

  # for Kaimon <-> Julia communication
  kaimonCacheWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.cache/kaimon" "${jailHomeDirectory}/.cache/kaimon")
  ];

  kaimonConfigWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.config/kaimon" "${jailHomeDirectory}/.config/kaimon")
  ];

  # Architecture specific ELF interpreter, e.g. /lib64/ld-linux-x86-64.so.2
  # for nix-ld support
  nixLdInterpreterPath = pkgs.lib.removeSuffix "\n" (builtins.readFile "${pkgs.nix-ld}/nix-support/ldpath");
  nixLdBinds = with jail.combinators; [
    (ro-bind "${pkgs.nix-ld}/libexec/nix-ld" nixLdInterpreterPath)
    (add-pkg-deps [ pkgs.glibc pkgs.stdenv.cc.cc pkgs.zlib ])
    (set-env "NIX_LD" pkgs.stdenv.cc.bintools.dynamicLinker)
    (set-env "NIX_LD_LIBRARY_PATH" (pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc pkgs.zlib ]))
  ];

  # script ensuring all jailed programs are launched from within the root directory
  assertInDevshell = name: ''
    set -e
    _cwd="$(${getExe' pkgs.coreutils "pwd"} -P)"
    case "$_cwd/" in
      "$(realpath "${devshellRoot}/${devshellProjectsFolder}")/"*) ;;
      *)
        echo "${name}: must be run from within ${devshellRoot}/${devshellProjectsFolder}" >&2
        echo "  current: $_cwd" >&2
        echo "  have you set devshellRoot in nix_src/flake.nix properly?" >&2
        exit 1
        ;;
    esac
  '';

  # `proxyDomains` (a domain list) makes the host wrapper start the allowlist proxy
  # for this jail on a unix socket bound in at jailProxySock, and tear it down when
  # the jail exits.
  makeJailed = { name, program, preHook ? "", network ? false, options ? [], extraPkgs ? [],
                 proxyDomains ? null }:
    let
      proxyBinds = pkgs.lib.optionals (proxyDomains != null) [
        (jail.combinators.rw-bind "${homeDirectory}/.cache/jail-net/${name}.sock" jailProxySock)
      ];
      inner = jail "${name}-inner" program (
        commonJailOptions ++
        pkgs.lib.optionals network [ jail.combinators.network ] ++
        proxyBinds ++
        options ++
        [ (jail.combinators.add-pkg-deps extraPkgs) ]);
      runInner =
        if proxyDomains == null then ''
          exec ${getExe inner} "$@"
        '' else ''
          _jn_dir="${homeDirectory}/.cache/jail-net"
          _jn_sock="$_jn_dir/${name}.sock"
          mkdir -p "$_jn_dir"
          rm -f "$_jn_sock"
          ${getExe jailNetProxy} "$_jn_sock" "${pkgs.lib.concatStringsSep "," proxyDomains}" >>"$_jn_dir/${name}-proxy.log" 2>&1 &
          _jn_pid=$!
          trap '_jn_st=$?; kill "$_jn_pid" 2>/dev/null; exit $_jn_st' EXIT INT TERM
          _jn_w=0
          while [ ! -S "$_jn_sock" ]; do
            if ! kill -0 "$_jn_pid" 2>/dev/null; then
              echo "${name}: network proxy exited before creating its socket" >&2
              exit 1
            fi
            [ "$_jn_w" -gt 200 ] && { echo "${name}: timed out waiting for network proxy socket" >&2; exit 1; }
            _jn_w=$((_jn_w + 1))
            sleep 0.05
          done
          ${getExe inner} "$@"
        '';
    in pkgs.writeShellScriptBin name ''
      ${assertInDevshell name}
      ${preHook}
      ${runInner}
    '';

  # restrictNetwork = true : empty netns, internet only via the host allowlist proxy.
  # restrictNetwork = false: full host network (for use on an isolated remote server).
  # The Claude<->Kaimon MCP socat bridge is present either way, since Kaimon always
  # runs in its own netns.
  makeJailedClaude = { extraPkgs ? [], name ? "jailed-claude", allowedDomains ? [],
                       restrictNetwork ? false, extraArgs ? "" }:
    makeJailed {
      inherit name extraPkgs;
      program = mkLauncher "claude" "${getExe claude-pkg} ${extraArgs}"
        (pkgs.lib.optional restrictNetwork proxyClientLeg ++ [ kaimonClientLeg ]);
      network = !restrictNetwork;
      proxyDomains = if restrictNetwork then allowedDomains else null;
      preHook = ''
        # makes sure a writable and host persisted .claude.json file exists
        [ -f ${homeDirectory}/.claude.json ] || echo '{}' > ${homeDirectory}/.claude.json
        # shared dir for the Claude<->Kaimon MCP socket
        mkdir -p ${homeDirectory}/.cache/kaimon-jail-sock
      '';
      options = claudeConfigWriteBinds ++ gitReadBinds ++ kaimonBridgeBinds
        ++ pkgs.lib.optionals restrictNetwork restrictedNetOptions;
    };

  # restrictNetwork = true : empty netns, internet only via the host allowlist proxy
  #   (e.g. the Julia registries). restrictNetwork = false: full host network.
  makeJailedJulia = { extraPkgs ? [], name ? "jailed-julia", allowedDomains ? [],
                      restrictNetwork ? true }:
    makeJailed {
      inherit name extraPkgs;
      program = if restrictNetwork
                then mkLauncher "julia" (getExe julia-pkg) [ proxyClientLeg ]
                else julia-pkg;
      network = !restrictNetwork;
      proxyDomains = if restrictNetwork then allowedDomains else null;
      preHook = ''
        [ -d ${homeDirectory} ]
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
      '';
      options = juliaDepotWriteBinds ++ kaimonCacheWriteBinds ++ nixLdBinds
        ++ pkgs.lib.optionals restrictNetwork restrictedNetOptions
        ++ (with jail.combinators; [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
        ]);
    };

  makeJailedKaimon = { extraPkgs ? [], name ? "jailed-kaimon" }:
    makeJailed {
      inherit name extraPkgs;
      program = mkLauncher "kaimon" "~/.julia/bin/kaimon" [ kaimonServerLeg ];
      network = false;
      preHook = ''
        [ -d ${homeDirectory} ]
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
        mkdir -p ${homeDirectory}/.cache/kaimon-jail-sock
        mkdir -p ${homeDirectory}/.config/kaimon
      '';
      options = with jail.combinators;
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        kaimonBridgeBinds ++
        kaimonConfigWriteBinds ++
        localhostResolveBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
          (add-pkg-deps [ julia-pkg ])
        ];
    };

  # This is for working within project folders and debugging the jails
  makeJailedShell = { extraPkgs ? [], name ? "jailed-shell" }:
    makeJailed {
      inherit name extraPkgs;
      program = pkgs.zsh;
      network = true;
      preHook = ''
        # makes sure a writable and host persisted .claude.json file exists
        [ -f ${homeDirectory}/.claude.json ] || echo '{}' > ${homeDirectory}/.claude.json
        # similar with Kaimon config folders
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
        mkdir -p ${homeDirectory}/.config/kaimon
      '';
      options = with jail.combinators;
        claudeConfigWriteBinds ++
        gitReadBinds ++
        juliaDepotWriteBinds ++
        kaimonConfigWriteBinds ++
        kaimonCacheWriteBinds ++
        nixLdBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
          (ro-bind "${homeDirectory}/.config/zsh" "${jailHomeDirectory}/.config/zsh")
          (set-env "ZDOTDIR" "${jailHomeDirectory}/.config/zsh")
          (set-env "LANG" "C.UTF-8")
          (set-env "TERMINFO_DIRS" "${pkgs.ncurses}/share/terminfo")
          (add-pkg-deps [ pkgs.zsh pkgs.ncurses ])
        ];
    };

in {
  inherit makeJailedClaude makeJailedShell makeJailedJulia makeJailedKaimon;
}
