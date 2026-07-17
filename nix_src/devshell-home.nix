{ pkgs, home-manager, devshellUser, homeDirectory, forHost ? false, tmuxServer ? "" }:

# Shared home-manager module for the zsh config (oh-my-zsh, aliases, history),
# instantiated twice: once for `.hosthome` (forHost = true, activated for real on
# the host, also carries tmux + direnv for the interactive panes), and once for
# jailed-shell (forHost = false, never activated — only `config.home-files` and
# `config.xdg.configFile` are consumed, as build-time nix-store artifacts bound
# straight into the jail). Keeping one module definition means both stay in sync.
home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [({ config, lib, ... }:
  let
    # 30% orange blended over the kitty #0a0a0a background for the host shells;
    # the jailed prompt keeps the terminal background.
    promptBg = if forHost then "#543007" else null;
    # starship has no global background option: append it to every module style
    bg = style: if promptBg == null then style else "${style} bg:${promptBg}";
  in {
    home.username = devshellUser;
    home.homeDirectory = homeDirectory;
    home.stateVersion = "25.11";

    programs = {
      # Program configurations available to both host development sell and jailed-shell
      zsh = {
        enable = true;

        dotDir = "${config.xdg.configHome}/zsh";

        shellAliases = {
          v   = "nvim";
          vim = "nvim";
          vs = "nvim -c ':vert Git'";

          tm   = "tmux";
          tmd  = "tmux detach";
          tmgl = "tmux -L ${tmuxServer} ls";
          tmga = "tmux -L ${tmuxServer} attach -t";

          g   = "git";
          gs  = "git status";
          gd  = "git diff";
          gf  = "git fetch";
          gk  = "git checkout";

          ju  = "jailed-julia -t auto";
          jug = "jailed-julia -t auto -i -e \"using Gridap; " +
            "using Gridap.Helpers;     using Gridap.Io;            using Gridap.Algebra;" +
            "using Gridap.Arrays;      using Gridap.TensorValues;  using Gridap.Fields;" +
            "using Gridap.Polynomials; using Gridap.ReferenceFEs;  using Gridap.Geometry;" +
            "using Gridap.CellData;    using Gridap.Visualization; using Gridap.FESpaces;" +
            "using Gridap.MultiField;  using Gridap.ODEs;          using Gridap.Adaptivity;" +
            "using FillArrays;         using LinearAlgebra;\" ";
          jus = "jailed-julia -t auto -i -e \"using Pkg; Pkg.activate(\"subdivision_surfaces\");" +
            "using GridapSubdivisionSurfaces; using Gridap; " +
            "using Gridap.Helpers;     using Gridap.Io;            using Gridap.Algebra;" +
            "using Gridap.Arrays;      using Gridap.TensorValues;  using Gridap.Fields;" +
            "using Gridap.Polynomials; using Gridap.ReferenceFEs;  using Gridap.Geometry;" +
            "using Gridap.CellData;    using Gridap.Visualization; using Gridap.FESpaces;" +
            "using Gridap.MultiField;  using Gridap.ODEs;          using Gridap.Adaptivity;" +
            "using FillArrays;         using LinearAlgebra;\" ";
        };

        autosuggestion.enable = true;
        enableCompletion = true;
        syntaxHighlighting.enable = true;

        history = {
          path = "${config.xdg.stateHome}/zsh_history";
          size = 50000;
        };

        initContent = lib.mkOrder 700 ''
          export AGNOSTER_DIR_BG=${if forHost then "208" else "blue"}
          export STARSHIP_CONFIG=${config.xdg.configHome}/starship.toml
        '';

        oh-my-zsh = {
          enable = true;
          plugins = [ "git" ];
          theme = "agnoster";
        };
      };

      starship = {
        enable = true;
        settings = {
          format = "$username$hostname$directory$git_branch$git_status$julia"
            + lib.optionalString (promptBg != null) "[](fg:${promptBg})"
            + "$line_break$character";
          username = {
            show_always = true;
            format = "[ $user]($style)";
            style_user = bg "bold yellow";
            style_root = bg "bold red";
          };
          hostname = {
            ssh_only = false;
            format = "[@$hostname ]($style)";
            style = bg "bold yellow";
          };
          directory = {
            format = "[ $path ]($style)";
            style = bg "bold cyan";
          };
          git_branch = {
            format = "[$symbol$branch ]($style)";
            style = bg "bold purple";
          };
          git_status = {
            format = "([$all_status$ahead_behind ]($style))";
            style = bg "bold red";
          };
          julia = {
            format = "[$symbol($version) ]($style)";
            style = bg "bold purple";
          };
        };
      };
    } // pkgs.lib.optionalAttrs forHost {

      # Program configurations only for the development sell of the host

      # necessary to auto load direnv in new tmux panes
      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      tmux = {
        enable = true;

        keyMode = "vi";
        customPaneNavigationAndResize = true;

        prefix = "C-t";
        shell = "${pkgs.zsh}/bin/zsh";

        # neovim compatibility https://github.com/neovim/neovim/wiki/FAQ
        escapeTime = 10;

        plugins = with pkgs; [
          tmuxPlugins.cpu
          tmuxPlugins.gruvbox
          tmuxPlugins.yank
          {
            # prefix+Ctrl+s to save session, prefix+Ctrl+r to restore
            plugin = tmuxPlugins.resurrect;
            extraConfig = "set -g @resurrect-strategy-nvim 'session'";
          }
        ];

        extraConfig = ''
          set-environment -g ZDOTDIR ${config.xdg.configHome}/zsh
          set -g default-terminal "tmux-256color"
          set -g mouse on

          # OSC 52 clipboard: nvim (and copy-mode) hand off through the terminal,
          # so no X server is needed inside the jail; tmux also keeps it in a buffer
          set -g set-clipboard on
          set -as terminal-features ',*:clipboard'

          # 2x C-t goes back and fourth between most recent windows
          bind-key C-t last-window

          # neovim compatibility https://github.com/neovim/neovim/wiki/FAQ
          set -g focus-events on

          # Update the status line every seconds
          set -g status-interval 1

          # Create new window (in the project dir) and name it directly
          bind C command-prompt -p "Name of new window: " "new-window -b -t '{end}' -c '#{@proj}' -n '%%'"

          # Cd to current directory when spliting window
          bind '"' split-window -v -c "#{pane_current_path}"
          bind  %  split-window -h -c "#{pane_current_path}"
          bind  c  new-window      -c "#{pane_current_path}"

          # index window and panes from 1
          set -g base-index 1
          set -g pane-base-index 1
          set-window-option -g pane-base-index 1
          set-option -g renumber-windows on

          # vim-like pane switching and edditing
          bind -T copy-mode-vi v   send-keys -X begin-selection
          bind -T copy-mode-vi C-v send-keys -X rectangle-toggle
          bind -T copy-mode-vi y   send-keys -X copy-pipe-and-cancel 'xclip -in -selection clipboard'
          bind -T copy-mode-vi s   send-keys -X cursor-up
          bind -T copy-mode-vi t   send-keys -X cursor-down
          bind -T copy-mode-vi c   send-keys -X cursor-left
          bind -T copy-mode-vi r   send-keys -X cursor-right
          bind -r ^ last-window
          bind -r s select-pane -U
          bind -r t select-pane -D
          bind -r c select-pane -L
          bind -r r select-pane -R
        '';
      };
    };
  })];
}
