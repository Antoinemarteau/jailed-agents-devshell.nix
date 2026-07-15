{ pkgs, home-manager, devshellUser, homeDirectory, forHost ? false }:

# Shared home-manager module for the zsh config (oh-my-zsh, aliases, history),
# instantiated twice: once for `.hosthome` (forHost = true, activated for real on
# the host, also carries tmux + direnv for the interactive panes), and once for
# jailed-shell (forHost = false, never activated — only `config.home-files` and
# `config.xdg.configFile` are consumed, as build-time nix-store artifacts bound
# straight into the jail). Keeping one module definition means both stay in sync.
home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [({ config, lib, ... }: {
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
        '';

        oh-my-zsh = {
          enable = true;
          plugins = [ "git" ];
          theme = "agnoster";
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

          # 2x C-b goes back and fourth between most recent windows
          bind-key C-b last-window

          # Create new window (in the project dir) and name it directly
          bind C command-prompt -p "Name of new window: " "new-window -c '#{@proj}' -n '%%'"

          # Cd to current directory when spliting window
          bind '"' split-window -v -c "#{pane_current_path}"
          bind  %  split-window -h -c "#{pane_current_path}"
          bind  c  new-window      -c "#{pane_current_path}"

          # Update the status line every seconds
          set -g status-interval 1

          # neovim compatibility https://github.com/neovim/neovim/wiki/FAQ
          set -g focus-events on

          # vim-like copy mode selection and yank
          bind -T copy-mode-vi v   send-keys -X begin-selection
          bind -T copy-mode-vi C-v send-keys -X rectangle-toggle
          bind -T copy-mode-vi y   send-keys -X copy-pipe-and-cancel 'xclip -in -selection clipboard'

          # index window and panes from 1
          set -g base-index 1
          set -g pane-base-index 1
          set-window-option -g pane-base-index 1
          set-option -g renumber-windows on
        '';
      };
    };
  })];
}
