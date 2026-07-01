{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, jail-nix, llm-agents, flake-utils, ... }:
  flake-utils.lib.eachDefaultSystem (system:
  let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
    jail = jail-nix.lib.init pkgs;

    # I'm using crush and opencode, but you could swap in others.
    opencode-pkg = llm-agents.packages.${system}.opencode;
    claude-pkg = llm-agents.packages.${system}.claude-code;

    commonPkgs = with pkgs; [
      bashInteractive
      curl
      wget
      jq
      git
      which
      ripgrep
      gnugrep
      gawkInteractive
      ps
      findutils
      gzip
      unzip
      gnutar
      diffutils
    ];

    commonJailOptions = with jail.combinators; [
      network
      time-zone
      no-new-session
      mount-cwd
      (fwd-env "USER") # important to be able to re-use the .claude.json, which depend on the user
    ];

    claudeConfigBinds = with jail.combinators; [
      (rw-bind (noescape "\"$JAILED_CLAUDE_CONFIG\"") (noescape "~/.claude"))
      (rw-bind (noescape "\"$JAILED_CLAUDE_CONFIG/.claude.json\"") (noescape "~/.claude.json"))
    ];

    # .claude.json needs to be created within the jail to be valid, but it is
    # linked to a temporary folder (the jail's home). This pre hook makes sure
    # that a writable .claude.json exists both on the host and in the jail.
    withClaudeConfigInit = { name, inner }: pkgs.writeShellScriptBin name ''
      set -e
      if [ -z "''${JAILED_CLAUDE_CONFIG:-}" ]; then
        echo "${name}: JAILED_CLAUDE_CONFIG must be set" >&2
        exit 1
      fi
      mkdir -p "$JAILED_CLAUDE_CONFIG"
      touch "$JAILED_CLAUDE_CONFIG/.claude.json"
      exec ${inner}/bin/${name}-inner "$@"
    '';

    makeJailedShell = { extraPkgs ? [] }:
      let
        inner = jail "jailed-shell-inner" pkgs.bashInteractive (with jail.combinators;
          commonJailOptions ++ claudeConfigBinds ++ [
            (add-pkg-deps commonPkgs)
            (add-pkg-deps extraPkgs)
          ]);
      in withClaudeConfigInit { name = "jailed-shell"; inherit inner; };

    makeJailedClaude = { extraPkgs ? [] }:
      let
        inner = jail "jailed-claude-inner" claude-pkg (with jail.combinators;
          commonJailOptions ++ claudeConfigBinds ++ [
            (add-pkg-deps commonPkgs)
            (add-pkg-deps extraPkgs)
          ]);
      in withClaudeConfigInit { name = "jailed-claude"; inherit inner; };

    #makeJailedOpencode = { extraPkgs ? [] }: jail "jailed-opencode" opencode-pkg (with jail.combinators; (
    #  commonJailOptions ++ [
    #    # Give it a safe spot for its own config and cache.
    #    # This also lets it remember things between sessions.
    #    (readwrite (noescape "~/.config/opencode"))
    #    (readwrite (noescape "~/.local/share/opencode"))
    #    (readwrite (noescape "~/.local/state/opencode"))
    #    (add-pkg-deps commonPkgs)
    #    (add-pkg-deps extraPkgs)
    #  ]));

  in
  {
    lib = {
      inherit makeJailedClaude;
      inherit makeJailedShell;
    };

    devShells.default = pkgs.mkShell {
      packages = [
        (makeJailedShell {})
        (makeJailedClaude {})
        #(makeJailedOpencode {})
      ];
    };
  });
}
