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
        exit 1
        ;;
    esac
  '';

  withClaudeConfigInit = { name, inner }: pkgs.writeShellScriptBin name ''
    ${assertInDevshell name}
    # .claude.json needs to be created within the jail to be valid, but it is
    # linked to a temporary folder (the jail's home). This pre hook makes sure
    # that a writable .claude.json exists both on the host and in the jail.
    touch ${homeDirectory}/.claude.json
    exec ${inner}/bin/${name}-inner "$@"
  '';

  withJuliaInit = { name, inner }: pkgs.writeShellScriptBin name ''
    ${assertInDevshell name}
    [ -d ${homeDirectory} ]
    mkdir -p ${homeDirectory}/.cache/kaimon/sock
    exec ${inner}/bin/${name}-inner "$@"
  '';

  withKaimonInit = { name, inner }: pkgs.writeShellScriptBin name ''
    ${assertInDevshell name}
    [ -d ${homeDirectory} ]
    mkdir -p ${homeDirectory}/.cache/kaimon/sock
    mkdir -p ${homeDirectory}/.config/kaimon
    exec ${inner}/bin/${name}-inner "$@"
  '';

  makeJailedShell = { extraPkgs ? [], name ? "jailed-shell" }:
    let
      inner = jail "${name}-inner" pkgs.bashInteractive (with jail.combinators;
        commonJailOptions ++
        [ network ] ++
        claudeConfigWriteBinds ++
        juliaDepotWriteBinds ++
        kaimonConfigWriteBinds ++
        kaimonCacheWriteBinds ++
        nixLdBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
          (add-pkg-deps extraPkgs)
        ]);
    in withClaudeConfigInit { inherit name inner; };

  makeJailedClaude = { extraPkgs ? [], name ? "jailed-claude" }:
    let
      inner = jail "${name}-inner" claude-pkg (with jail.combinators;
        commonJailOptions ++
        [ network ] ++
        claudeConfigWriteBinds ++ [
          (add-pkg-deps extraPkgs)
        ]);
    in withClaudeConfigInit { inherit name inner; };

  makeJailedJulia = { extraPkgs ? [], network ? false, name ? "jailed-julia" }:
    let
      inner = jail "${name}-inner" julia-pkg (with jail.combinators;
        commonJailOptions ++
        (if network then [ jail.combinators.network ] else []) ++
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        nixLdBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
          (add-pkg-deps extraPkgs)
        ]);
    in withJuliaInit { inherit name inner; };

  makeJailedKaimon = { extraPkgs ? [], name ? "jailed-kaimon" }:
    let
      kaimonLauncher = pkgs.writeShellScriptBin "kaimon" ''
        exec ~/.julia/bin/kaimon "$@"
      '';
      inner = jail "${name}-inner" kaimonLauncher (with jail.combinators;
        commonJailOptions ++
        [ network ] ++
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        kaimonConfigWriteBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
          (add-pkg-deps [ julia-pkg ])
          (add-pkg-deps extraPkgs)
        ]);
    in withKaimonInit { inherit name inner; };

in {
  inherit makeJailedClaude makeJailedShell makeJailedJulia makeJailedKaimon;
}
