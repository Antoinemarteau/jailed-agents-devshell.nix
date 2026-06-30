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
        # Override base permissions to omit --tmpfs ~ (the default mounts a
        # tmpfs at the host user's home, which would create a spurious
        # /home/<username> directory alongside our /home/agent bind mount).
        jail = jail-nix.lib.extend {
            inherit pkgs;
            basePermissions = combinators: with combinators; [
                (compose [
                    (unsafe-add-raw-args "--proc /proc")
                    (unsafe-add-raw-args "--dev /dev")
                    (unsafe-add-raw-args "--tmpfs /tmp")
                    (ro-bind "${pkgs.bash}/bin/sh" "/bin/sh")
                    (add-path "/bin")
                    (add-pkg-deps [ pkgs.coreutils pkgs.bash ])
                    (unsafe-add-raw-args "--clearenv")
                    (fwd-env "LANG")
                    (fwd-env "HOME")
                    (fwd-env "TERM")
                ])
                bind-nix-store-runtime-closure
                fake-passwd
            ];
        };

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

                    programs.zsh = {
                        enable = true;
                        autosuggestion.enable = true;
                        enableCompletion = true;
                        syntaxHighlighting.enable = true;
                        oh-my-zsh = {
                            enable = true;
                            plugins = [ "git" ];
                            theme = "agnoster";
                        };
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
            claude-code gh curl wget git which
            ripgrep gnugrep gawk findutils
            gzip unzip gnutar diffutils jq
            neovim
        ];

        sandboxedAgent = jail "claude-agent"
            (pkgs.writeScriptBin "claude-agent" ''
                #!${pkgs.bash}/bin/bash
                HOME=/home/agent USER=agent HOME_MANAGER_BACKUP_EXT=bak \
                    ${agentHome.config.home.activationPackage}/activate 2>/dev/null || true
                cd /home/agent/workspace
                exec ${pkgs.zsh}/bin/zsh "$@"
            '')
            (with jail.combinators; [
                network
                time-zone
                no-new-session
                (rw-bind (noescape "\"$(dirname \"$AGENT_WORKDIR\")/.home\"") "/home/agent")
                (rw-bind (noescape "\"$AGENT_WORKDIR\"") "/home/agent/workspace")
                (set-env "HOME" "/home/agent")
                (add-pkg-deps agentPkgs)
                (add-pkg-deps [agentHome.activationPackage])
                (add-path "${agentHome.activationPackage}/home-path/bin")
            ]);

        # Outer wrapper: validates AGENT_WORKDIR and launches the jail
        agentLauncher = pkgs.writeScriptBin "claude-agent" ''
            #!${pkgs.bash}/bin/bash
            set -e
            export AGENT_WORKDIR="''${AGENT_WORKDIR:-$PWD}"
            export SOPS_AGE_SSH_PRIVATE_KEY_FILE="''${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-$HOME/.ssh/id_ed25519_agent}"
            AGENT_HOME="$(dirname "$AGENT_WORKDIR")/.home"
            mkdir -p "$AGENT_HOME/workspace"
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
