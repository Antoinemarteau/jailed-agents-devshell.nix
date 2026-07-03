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
    # ps               # process listing, not required
    findutils
    # gzip          # archive tools, not required by Claude Code or Julia
    # unzip
    # gnutar
    diffutils
  ];

  jailHomeDirectory = "/home/${devshellUser}";

  commonJailOptions = with jail.combinators; [
    network
    time-zone
    no-new-session
    mount-cwd
    (set-env "USER" devshellUser)
    (set-env "HOME" jailHomeDirectory)
    # read-only view of agentshome into jail's /home/agents
    (ro-bind homeDirectory jailHomeDirectory)
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

  makeJailedShell = { extraPkgs ? [] }:
    let
      inner = jail "jailed-shell-inner" pkgs.bashInteractive (with jail.combinators;
        commonJailOptions ++
        claudeConfigWriteBinds ++
        juliaDepotWriteBinds ++
        kaimonConfigWriteBinds ++
        kaimonCacheWriteBinds ++ [
          (add-pkg-deps extraPkgs)
        ]);
    in withClaudeConfigInit { name = "jailed-shell"; inherit inner; };

  makeJailedClaude = { extraPkgs ? [] }:
    let
      inner = jail "jailed-claude-inner" claude-pkg (with jail.combinators;
        commonJailOptions ++
        claudeConfigWriteBinds ++ [
          (add-pkg-deps extraPkgs)
        ]);
    in withClaudeConfigInit { name = "jailed-claude"; inherit inner; };

  makeJailedJulia = { extraPkgs ? [] }:
    let
      inner = jail "jailed-julia-inner" julia-pkg (with jail.combinators;
        commonJailOptions ++
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++ [
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
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        kaimonConfigWriteBinds ++ [
          (add-pkg-deps [ julia-pkg ])
          (add-pkg-deps extraPkgs)
        ]);
    in withKaimonInit { name = "jailed-kaimon"; inherit inner; };

in {
  inherit makeJailedClaude makeJailedShell makeJailedJulia makeJailedKaimon;
}
