{ pkgs, jail, julia-pkg, claude-pkg, devshellRoot, devshellProjectsFolder, devshellUser, homeDirectory }:

let
  commonPkgs = with pkgs; [
    bashInteractive
    curl
    # wget          # redundant with curl
    jq
    git
    which
    ripgrep
    gnugrep
    # gawkInteractive  # awk text processor, not required
    ps              # required by Kaimon
    findutils
    # gzip          # archive tools, not required by Claude Code or Julia
    # unzip
    # gnutar
    diffutils
  ];

  jailHomeDirectory = "/home/${devshellUser}";

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
    (fwd-env "NIX_LD")
    (fwd-env "NIX_LD_LIBRARY_PATH")
  ];

  # script ensuring all jailed programs are launched from within the root directory
  assertInDevshell = name: ''
    set -e
    _cwd="$(${pkgs.coreutils}/bin/pwd -P)"
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

  makeJailed ={ name, program, preHook ? "", network ? false, options ? [], extraPkgs ? [] }:
    let
      inner = jail "${name}-inner" program (
        commonJailOptions ++
        pkgs.lib.optionals network [ jail.combinators.network ] ++
        options ++
        [ (jail.combinators.add-pkg-deps extraPkgs) ]);
    in pkgs.writeShellScriptBin name ''
      ${assertInDevshell name}
      ${preHook}
      exec ${inner}/bin/${name}-inner "$@"
    '';

  makeJailedClaude = { extraPkgs ? [], name ? "jailed-claude" }:
    makeJailed {
      inherit name extraPkgs;
      program = claude-pkg;
      network = true;
      preHook = ''
        # makes sure a writable and host persisted .claude.json file exists
        [ -f ${homeDirectory}/.claude.json ] || echo '{}' > ${homeDirectory}/.claude.json
      '';
      options = claudeConfigWriteBinds ++ gitReadBinds;
    };

  makeJailedJulia = { extraPkgs ? [], network ? false, name ? "jailed-julia" }:
    makeJailed {
      inherit name extraPkgs network;
      program = julia-pkg;
      preHook = ''
        [ -d ${homeDirectory} ]
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
      '';
      options = with jail.combinators;
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        nixLdBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
        ];
    };

  makeJailedKaimon = { extraPkgs ? [], name ? "jailed-kaimon" }:
    let
      kaimonLauncher = pkgs.writeShellScriptBin "kaimon" ''
        exec ~/.julia/bin/kaimon "$@"
      '';
    in makeJailed {
      inherit name extraPkgs;
      program = kaimonLauncher;
      network = true;
      preHook = ''
        [ -d ${homeDirectory} ]
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
        mkdir -p ${homeDirectory}/.config/kaimon
      '';
      options = with jail.combinators;
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        kaimonConfigWriteBinds ++ [
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
