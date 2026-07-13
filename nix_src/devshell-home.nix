{ pkgs, home-manager, devshellRoot, devshellUser, devshellHostHomeFolder, nvim-pkg }:

home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [({ config, ... }: {
    home.username = devshellUser;
    home.homeDirectory = devshellRoot + "/" + devshellHostHomeFolder;
    home.stateVersion = "25.11";

    home.packages = [ nvim-pkg ];

    programs = {
      # necessary to auto load direnv in new tmux panes
      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

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

        oh-my-zsh = {
          enable = true;
          plugins = [ "git" ];
          theme = "agnoster";
        };
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
          set -g mouse on

          # 2x C-t goes back and fourth between most recent windows
          bind-key C-t last-window

          # neovim compatibility https://github.com/neovim/neovim/wiki/FAQ
          set -g focus-events on

          # Update the status line every seconds
          set -g status-interval 1

          # Create new window (in the project dir) and name it directly
          bind C command-prompt -p "Name of new window: " "new-window -c '#{@proj}' -n '%%'"

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
