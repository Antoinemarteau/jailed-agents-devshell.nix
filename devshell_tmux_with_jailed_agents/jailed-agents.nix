{ pkgs, jail, julia-pkg, claude-pkg, devshellRoot, devshellProjectsFolder, homeDirectory }:

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
    # ps               # process listing, not required
    findutils
    # gzip          # archive tools, not required by Claude Code or Julia
    # unzip
    # gnutar
    diffutils
  ];

  commonJailOptions = with jail.combinators; [
    network
    time-zone
    no-new-session
    mount-cwd
    (set-env "USER" "agents")
    (add-pkg-deps commonPkgs)
  ];

  claudeConfigBinds = with jail.combinators; [
    (rw-bind (noescape "\"${homeDirectory}/.claude\"") (noescape "~/.claude"))
    (rw-bind (noescape "\"${homeDirectory}/.claude/.claude.json\"") (noescape "~/.claude.json"))
  ];

  juliaDepotBinds = with jail.combinators; [
    (rw-bind (noescape "\"${homeDirectory}/.julia\"") (noescape "~/.julia"))
  ];

  # for Kaimon <-> Julia communication
  kaimonCacheBinds = with jail.combinators; [
    (rw-bind (noescape "\"${homeDirectory}/.cache/kaimon\"") (noescape "~/.cache/kaimon"))
  ];

  kaimonConfigBinds = with jail.combinators; [
    (rw-bind (noescape "\"${homeDirectory}/.config/kaimon\"") (noescape "~/.config/kaimon"))
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
    touch ${homeDirectory}/.claude/.claude.json
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

  makeJailedShell = { extraPkgs ? [] }:
    let
      inner = jail "jailed-shell-inner" pkgs.bashInteractive (with jail.combinators;
        commonJailOptions ++
        claudeConfigBinds ++
        juliaDepotBinds ++
        kaimonConfigBinds ++
        kaimonCacheBinds ++ [
          (add-pkg-deps extraPkgs)
        ]);
    in withClaudeConfigInit { name = "jailed-shell"; inherit inner; };

  makeJailedClaude = { extraPkgs ? [] }:
    let
      inner = jail "jailed-claude-inner" claude-pkg (with jail.combinators;
        commonJailOptions ++ claudeConfigBinds ++ [
          (add-pkg-deps extraPkgs)
        ]);
    in withClaudeConfigInit { name = "jailed-claude"; inherit inner; };

  makeJailedJulia = { extraPkgs ? [] }:
    let
      inner = jail "jailed-julia-inner" julia-pkg (with jail.combinators;
        commonJailOptions ++
        juliaDepotBinds ++
        kaimonCacheBinds ++ [
          (add-pkg-deps extraPkgs)
        ]);
    in withJuliaInit { name = "jailed-julia"; inherit inner; };

  makeJailedKaimon = { extraPkgs ? [] }:
    let
      kaimonLauncher = pkgs.writeShellScriptBin "kaimon" ''
        exec ~/.julia/bin/kaimon "$@"
      '';
      inner = jail "jailed-kaimon-inner" kaimonLauncher (with jail.combinators;
        commonJailOptions ++
        juliaDepotBinds ++
        kaimonCacheBinds ++
        kaimonConfigBinds ++ [
          (add-pkg-deps [ julia-pkg ])
          (add-pkg-deps extraPkgs)
        ]);
    in withKaimonInit { name = "jailed-kaimon"; inherit inner; };

in {
  inherit makeJailedClaude makeJailedShell makeJailedJulia makeJailedKaimon;
}
