{
    description = "Sandboxed Claude Code agent for Julia development";

    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
        home-manager = {
            url = "github:nix-community/home-manager/release-25.11";
            inputs.nixpkgs.follows = "nixpkgs";
        };
        scientific-fhs.url = "github:Antoinemarteau/scientific-fhs";
        jail-nix.url = "sourcehut:~alexdavid/jail.nix";
        sops-nix = {
            url = "github:Mic92/sops-nix";
            inputs.nixpkgs.follows = "nixpkgs";
        };
    };

    outputs = { self, nixpkgs, home-manager, scientific-fhs, jail-nix, sops-nix }:
    let
        system = "x86_64-linux";
        pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [
                "claude-code"
            ];
        };
        jail = jail-nix.lib.init pkgs;

        # Home-manager configuration for the agent user
        agentHome = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
                scientific-fhs.nixosModules.default
                sops-nix.homeManagerModules.sops
                {
                    home.username = "agent";
                    home.homeDirectory = "/home/agent";
                    home.stateVersion = "25.11";

                    programs.scientific-fhs = {
                        enable = true;
                        juliaVersions = [
                            { version = "1.12.5"; default = true; }
                            { version = "1.10.10"; }
                        ];
                        enableNVIDIA = false;
                    };

                    home.packages = with pkgs; [
                        bashInteractive
                        curl
                        git
                        ripgrep
                        jq
                        claude-code
                    ];
                }
            ];
        };

        agentPkgs = with pkgs; [
            claude-code curl wget git which
            ripgrep gnugrep gawk findutils
            gzip unzip gnutar diffutils jq
            neovim
        ];

        sandboxedAgent = jail "claude-agent"
            (pkgs.writeScriptBin "claude-agent" ''
                #!${pkgs.bashInteractive}/bin/bash
                cd /workspace
                exec ${pkgs.bashInteractive}/bin/bash "$@"
            '')
            (with jail.combinators; [
                network
                time-zone
                no-new-session
                (rw-bind (noescape "\"$AGENT_WORKDIR\"") "/workspace")
                (set-env "CLAUDE_CONFIG_DIR" "/workspace/.claude")
                (fwd-env "CLAUDE_CODE_OAUTH_TOKEN")
                (add-pkg-deps agentPkgs)
            ]);

        # Outer wrapper: validates AGENT_WORKDIR and launches the jail
        agentLauncher = pkgs.writeScriptBin "claude-agent" ''
            #!${pkgs.bash}/bin/bash
            set -e
            export AGENT_WORKDIR="''${AGENT_WORKDIR:-$PWD}"
            export SOPS_AGE_SSH_PRIVATE_KEY_FILE="''${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-$HOME/.ssh/id_ed25519_agent}"
            set -a
            source <(${pkgs.sops}/bin/sops --decrypt --output-type dotenv "$AGENT_WORKDIR/secrets.yaml")
            set +a
            exec ${sandboxedAgent}/bin/claude-agent "$@"
        '';
    in {
        packages.${system} = {
            default = agentLauncher;
            agentHome = agentHome.activationPackage;
        };

        apps.${system}.default = {
            type = "app";
            program = "${agentLauncher}/bin/claude-agent";
        };
    };
}
