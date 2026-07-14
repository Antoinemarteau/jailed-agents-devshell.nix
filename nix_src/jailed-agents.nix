{ pkgs, jail, home-manager, devshellRoot, devshellHomeFolder,
  devshellHostHomeFolder, devshellUser, jailHomeDirectory, homeDirectory }:

let
  inherit (pkgs.lib) getExe getExe';

  # host dir for the coding projects (under the agent home)
  devshellProjectsFolder = "${devshellHomeFolder}/projects";

  # tmux server name
  tmuxServer = "julia_agents";
  # user-editable window layout
  tmuxSessionFile = "${devshellRoot}/${devshellHostHomeFolder}/.config/tmux/default-session.conf";

  commonJailPkgs = with pkgs; [
    bashInteractive
    less
    curl
    wget
    jq
    git
    socat           # tcp<->unix bridges for the network/MCP sockets
    which
    ripgrep
    gnugrep
    less
    gawkInteractive # awk text processor, not required
    ps              # required by Kaimon
    findutils
    diffutils
  ];

  commonJailOptions = with jail.combinators; [
    time-zone
    no-new-session
    mount-cwd
    (set-env "USER" devshellUser)
    (set-env "HOME" jailHomeDirectory)
    # writable tmpfs at /home/agents so programs can create transient files (e.g. lock files) in $HOME;
    (tmpfs jailHomeDirectory)
    (add-pkg-deps commonJailPkgs)
  ];

  gitReadBinds = with jail.combinators; [
    (try-ro-bind "${homeDirectory}/.gitconfig" "${jailHomeDirectory}/.gitconfig")
    (try-ro-bind "${homeDirectory}/.git-credentials" "${jailHomeDirectory}/.git-credentials")
  ];

  # Architecture specific ELF interpreter, e.g. /lib64/ld-linux-x86-64.so.2
  # for nix-ld support
  nixLdInterpreterPath = pkgs.lib.removeSuffix "\n" (builtins.readFile "${pkgs.nix-ld}/nix-support/ldpath");
  nixLdBinds = with jail.combinators; [
    (ro-bind "${pkgs.nix-ld}/libexec/nix-ld" nixLdInterpreterPath)
    (add-pkg-deps [ pkgs.glibc pkgs.stdenv.cc.cc pkgs.zlib ])
    (set-env "NIX_LD" pkgs.stdenv.cc.bintools.dynamicLinker)
    (set-env "NIX_LD_LIBRARY_PATH" (pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc pkgs.zlib ]))
  ];

  # devshell-home.nix defines the zsh config (oh-my-zsh, aliases, history) once; this is
  # the instantiation that also carries tmux + direnv and is activated for real into
  # <devshellRoot>/.hosthome. The other instantiation (jailShellHomeManager, never
  # activated — only its build-time `home-files` output is consumed) is program-specific
  # to jailed-shell and lives in flake.nix instead.
  hostHomeManager = import ./devshell-home.nix {
    inherit pkgs home-manager devshellUser;
    homeDirectory = devshellRoot + "/" + devshellHostHomeFolder;
    forHost = true;
  };
  hostHomeDirectory = hostHomeManager.config.home.homeDirectory;
  configFile = hostHomeManager.config.xdg.configFile;


  #############################################################################
  # Jail network whitelist logic (restrictNetwork argument of makeJailed)
  #############################################################################

  # A network-restricted jail keeps jail.nix's default empty netns (kernel-enforced
  # deny-all egress) and reaches the outside world only through a host-side allowlist
  # proxy, bridged in over a unix socket by an in-jail socat.

  # The allowlist is enforced by tinyproxy. One instance runs on the host (host netns, real
  # DNS) per restricted-jail *process*, so several instances of the same jail can run at
  # once; tinyproxy speaks TCP only, so it is bridged into the jail's empty netns over a
  # per-instance bound unix socket (see jailNetProxy and makeJailed).

  cacertBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  proxyPort = 3128;                           # in-jail TCP that HTTP(S)_PROXY targets
  jailProxySock = "/run/jail-net/proxy.sock"; # host proxy socket, bound into the jail here

  # In-jail socat legs (for a jail's launcher).
  # Client legs listen on 127.0.0.1 and forward to a bound unix socket.
  proxyClientLeg = "socat TCP-LISTEN:${toString proxyPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailProxySock} 2>/dev/null &";

  # Any jail without full host network has no /etc/hosts or /etc/nsswitch.conf (the
  # `network` combinator otherwise provides them), so `localhost` won't resolve —
  # needed even by fully offline jails (e.g. Kaimon), not just restricted ones.
  localhostResolveBinds = with jail.combinators; [
    (write-text "/etc/hosts" "127.0.0.1 localhost\n::1 localhost\n")
    (write-text "/etc/nsswitch.conf" "hosts: files dns\n")
  ];

  # Point HTTP clients at the in-jail proxy endpoint and supply a CA bundle
  # since /etc/ssl is unbound (localhost resolution is handled by makeJailed
  # itself for every jail without full host network).
  restrictedNetOptions = with jail.combinators; [
    (set-env "HTTP_PROXY"  "http://127.0.0.1:${toString proxyPort}")
    (set-env "HTTPS_PROXY" "http://127.0.0.1:${toString proxyPort}")
    (set-env "http_proxy"  "http://127.0.0.1:${toString proxyPort}")
    (set-env "https_proxy" "http://127.0.0.1:${toString proxyPort}")
    (set-env "NO_PROXY"    "localhost,127.0.0.1")
    (set-env "no_proxy"    "localhost,127.0.0.1")
    (set-env "SSL_CERT_FILE"       cacertBundle)
    (set-env "NIX_SSL_CERT_FILE"   cacertBundle)
    (set-env "GIT_SSL_CAINFO"      cacertBundle)
    (set-env "CURL_CA_BUNDLE"      cacertBundle)
    (set-env "NODE_EXTRA_CA_CERTS" cacertBundle)
    (add-pkg-deps [ pkgs.cacert ])
    # per-instance host proxy socket, bound in at runtime (see makeJailed)
    (unsafe-add-raw-args ''--bind "''${JAIL_PROXY_HOST_SOCK-}" ${jailProxySock}'')
  ];

  # Default-deny allowlist: a host is reachable iff it equals an allowed domain or is a
  # subdomain of it. Each domain d becomes the anchored ERE  (^|\.)d$  (dots escaped),
  # so `julialang.org` allows `pkg.julialang.org` but not `notjulialang.org` nor
  # `julialang.org.evil.com`.
  mkProxyFilterFile = name: domains: pkgs.writeText "${name}-proxy.filter"
    (pkgs.lib.concatMapStringsSep "\n"
      (d: "(^|\\.)" + (builtins.replaceStrings [ "." ] [ "\\." ] d) + "$")
      domains + "\n");

  # Host-side launcher (args: SOCKET FILTER PORT): run one tinyproxy for a jail instance
  # on 127.0.0.1:PORT with the given (build-time, store) allowlist FILTER, then expose it
  # on the bound unix SOCKET via socat (tinyproxy speaks TCP only). The tiny conf wrapper
  # is built here at runtime because PORT is chosen per instance (so several instances of
  # the same jail can run at once). The socket is created only AFTER tinyproxy is confirmed
  # listening, so its existence signals readiness to the caller (which retries on a port
  # clash). Runs in the foreground; the trap tears down both children and the temp conf.
  jailNetProxy = pkgs.writeShellScriptBin "jail-net-proxy" ''
    set -eu
    _sock="$1"; _filter="$2"; _port="$3"
    _tp=""; _so=""
    _dir="$(${getExe' pkgs.coreutils "mktemp"} -d)"
    trap 'kill $_tp $_so 2>/dev/null || true; ${getExe' pkgs.coreutils "rm"} -rf "$_dir"' EXIT INT TERM

    _conf="$_dir/tinyproxy.conf"
    {
      printf 'Port %s\n'            "$_port"
      printf 'Listen 127.0.0.1\n'
      printf 'Timeout 600\n'
      printf 'MaxClients 100\n'
      printf 'LogLevel Notice\n'
      printf 'FilterDefaultDeny Yes\n'
      printf 'Filter "%s"\n'        "$_filter"
      printf 'FilterType ere\n'
      printf 'FilterCaseSensitive Off\n'
      printf 'ConnectPort 443\n'
      printf 'ConnectPort 80\n'
    } > "$_conf"

    ${getExe pkgs.tinyproxy} -d -c "$_conf" &
    _tp=$!
    # Wait until tinyproxy is accepting on its port, or has died (e.g. the port was taken).
    _w=0
    until (exec 3<>/dev/tcp/127.0.0.1/"$_port") 2>/dev/null; do
      kill -0 "$_tp" 2>/dev/null || exit 1
      [ "$_w" -gt 100 ] && exit 1
      _w=$((_w + 1)); sleep 0.05
    done
    ${getExe' pkgs.coreutils "rm"} -f "$_sock"
    ${getExe pkgs.socat} UNIX-LISTEN:"$_sock",fork,reuseaddr TCP:127.0.0.1:"$_port" &
    _so=$!
    wait -n
  '';


  #############################################################################
  # Jailed program logic
  #############################################################################

  # Resolve `exe` (a derivation, resolved via `getExe`, or a literal path string) into the
  # program to jail: passed through unchanged when there's nothing to run first (then it
  # must be a derivation), otherwise wrapped to run `legs` (in-jail socat leg snippets)
  # before `exec`ing it with `extraArgs`.
  mkLauncher = name: exe: extraArgs: legs:
    if legs == [] && extraArgs == "" then exe
    else
      let exePath = if pkgs.lib.isDerivation exe then getExe exe else exe;
      in pkgs.writeShellScriptBin name ''
        ${pkgs.lib.concatStringsSep "\n" legs}
        exec ${exePath} ${extraArgs} "$@"
      '';

  # script ensuring all jailed programs are launched from within the root directory
  assertInDevshell = name: ''
    set -e
    _cwd="$(${getExe' pkgs.coreutils "pwd"} -P)"
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

  # Main function to create a sandboxed `exe`
  # `network` and `restrictNetwork` are mutually exclusive.
  makeJailed = { name, exe, extraArgs ? "", socatLegs ? [], preHook ? "", network ? false,
                 options ? [], extraPkgs ? [], restrictNetwork ? false, allowedDomains ? [] }:
    assert pkgs.lib.assertMsg (!(network && restrictNetwork))
      "${name}: network and restrictNetwork are mutually exclusive";
    assert pkgs.lib.assertMsg (restrictNetwork || allowedDomains == [])
      "${name}: allowedDomains must be empty when restrictNetwork = false";
    let
      allSocatLegs = pkgs.lib.optionals restrictNetwork [ proxyClientLeg ] ++ socatLegs;
      program = mkLauncher name exe extraArgs allSocatLegs;

      inner = jail "${name}-inner" program (
        commonJailOptions ++
        pkgs.lib.optionals network [ jail.combinators.network ] ++
        pkgs.lib.optionals (!network) localhostResolveBinds ++
        pkgs.lib.optionals restrictNetwork restrictedNetOptions ++
        options ++
        [ (jail.combinators.add-pkg-deps extraPkgs) ]);

      runInner =
        if !restrictNetwork then ''
          exec ${getExe inner} "$@"
        '' else ''
          # Per-instance host proxy socket (keyed by this wrapper's PID) so concurrent
          # instances of this jail don't collide.
          _jn_dir="${homeDirectory}/.cache/jail-net"
          mkdir -p "$_jn_dir"
          JAIL_PROXY_HOST_SOCK="$_jn_dir/${name}.$$.sock"
          export JAIL_PROXY_HOST_SOCK

          # Start the allowlist proxy. tinyproxy needs its own host TCP port; pick a random
          # one and retry on a clash (the launcher only creates the socket once tinyproxy is
          # up, so the socket appearing means success).
          _jn_ok=0
          for _jn_try in 1 2 3 4 5 6 7 8 9 10; do
            _jn_port=$(( (RANDOM % 20000) + 20000 ))
            ${getExe jailNetProxy} "$JAIL_PROXY_HOST_SOCK" "${mkProxyFilterFile name allowedDomains}" "$_jn_port" \
              >>"$_jn_dir/${name}-proxy.log" 2>&1 &
            _jn_pid=$!
            _jn_w=0
            while [ ! -S "$JAIL_PROXY_HOST_SOCK" ]; do
              kill -0 "$_jn_pid" 2>/dev/null || break
              [ "$_jn_w" -gt 100 ] && break
              _jn_w=$((_jn_w + 1))
              sleep 0.05
            done
            if [ -S "$JAIL_PROXY_HOST_SOCK" ]; then _jn_ok=1; break; fi
            kill "$_jn_pid" 2>/dev/null || true
            wait "$_jn_pid" 2>/dev/null || true
          done
          if [ "$_jn_ok" -ne 1 ]; then
            echo "${name}: could not start network proxy" >&2
            exit 1
          fi
          trap '_jn_st=$?; kill "$_jn_pid" 2>/dev/null; rm -f "$JAIL_PROXY_HOST_SOCK"; exit $_jn_st' EXIT INT TERM
          ${getExe inner} "$@"
        '';
    in pkgs.writeShellScriptBin name ''
      ${assertInDevshell name}
      ${preHook}
      ${runInner}
    '';

  # Launch (or reset) a tmux development session for the current project.
  # Entering the devShell (via direnv or `nix develop`) only puts the tools
  # on PATH — running this builds and attaches the session.
  newAgentSession = pkgs.writeShellScriptBin "new_agent_session" ''
    # Require running from within the projects dir, where the jailed agents operate.
    _projects="${devshellRoot}/${devshellProjectsFolder}"
    if [ ! -d "$_projects" ]; then
      echo "ERROR: devshellRoot in flake.nix is '${devshellRoot}'," >&2
      echo "  but its projects directory ($_projects) does not exist." >&2
      echo "  set devshellRoot to this repo's absolute path in flake.nix, then reload the env." >&2
      exit 1
    fi
    _cwd="$(pwd -P)"
    case "$_cwd/" in
      "$(realpath "$_projects")/"*) ;;
      *)
        echo "ERROR: new_agent_session must be run from within $_projects" >&2
        echo "  current: $_cwd" >&2
        exit 1
        ;;
    esac
    _session="$(basename "$_cwd")"
    _session="''${_session//[^a-zA-Z0-9_-]/_}"

    # The session windows launch jailed agents from PATH; ensure the devShell env is loaded.
    if ! command -v jailed-kaimon >/dev/null 2>&1; then
      echo "ERROR: devShell tools not on PATH — enter the env first (direnv, or 'nix develop ${devshellRoot}/nix_src')" >&2
      exit 1
    fi

    # Refuse to run inside any other tmux session — new-session cannot attach when nested.
    if [ -n "''${TMUX:-}" ]; then
      echo "ERROR: cannot start the tmux development session within a tmux session — detach first (Ctrl-b d)" >&2
      exit 1
    fi

    # Activate home-manager config into the .hosthome dir (never touches real $HOME).
    HOME=${hostHomeDirectory} USER=${devshellUser} HOME_MANAGER_BACKUP_EXT=bak \
      ${hostHomeManager.activationPackage}/activate

    # Create or reset the tmux session, then apply the user-editable window
    # layout. @proj is the project dir.
    _layout="${tmuxSessionFile}"
    if [ ! -f "$_layout" ]; then
      echo "ERROR: tmux session file not found: $_layout" >&2
      exit 1
    fi
    tmux -L ${tmuxServer} kill-session -t "=$_session" 2>/dev/null || true
    tmux -L ${tmuxServer} -f ${configFile."tmux/tmux.conf".source} new-session -d -s "$_session" -c "$_cwd"
    tmux -L ${tmuxServer} set-option  -t "$_session" @proj "$_cwd"
    tmux -L ${tmuxServer} source-file -t "$_session:" "$_layout"
    tmux -L ${tmuxServer} attach-session -t "$_session"
  '';

  attachAgentSession = pkgs.writeShellScriptBin "attach_agent_session" ''
    _session="$(basename "$(pwd -P)")"
    _session="''${_session//[^a-zA-Z0-9_-]/_}"

    # Refuse to attach inside another tmux session — attach cannot nest.
    if [ -n "''${TMUX:-}" ]; then
      echo "ERROR: cannot attach within a tmux session — detach first (Ctrl-b d)" >&2
      exit 1
    fi

    if ! tmux -L ${tmuxServer} has-session -t "=$_session" 2>/dev/null; then
      echo "ERROR: no tmux session '$_session' for this folder — start one with new_agent_session" >&2
      exit 1
    fi
    tmux -L ${tmuxServer} attach-session -t "=$_session"
  '';

  # Shadow a host dev tool inside the agent-writable tree (homeDirectory, which holds the
  # jail-bound agent data and the projects). The interactive devshell home lives in a
  # separate tree (.hosthome/), so its startup files can never become agent-writable. This
  # is a footgun-reducer, NOT a security boundary: absolute paths (/usr/bin/git) and tools
  # that use git without exec'ing it (libgit2, gh's internal git) bypass it.
  guardHostTool = name: pkgs.writeShellScriptBin name ''
    _cwd="$(${pkgs.coreutils}/bin/pwd -P)/"
    case "$_cwd" in
      "$(${pkgs.coreutils}/bin/realpath -m "${homeDirectory}")/"*)
        echo "⛔ '${name}' is disabled here: this tree is written by the sandboxed agents." >&2
        echo "   Running host '${name}' could execute agent-planted hooks/config on your host." >&2
        echo "   Use the jailed tools, or run '${name}' from inside 'jailed-shell', or from outside the sandbox after reviewing the diff." >&2
        exit 1 ;;
    esac
    # Outside the agent-writable tree: hand off to the real host tool (skip this wrapper).
    readarray -t _paths < <(type -aP ${name})
    _real="''${_paths[1]:-}"
    if [ -z "$_real" ]; then
      echo "${name}: no host '${name}' found on PATH" >&2
      exit 127
    fi
    exec "$_real" "$@"
  '';

in {
  inherit makeJailed gitReadBinds nixLdBinds hostHomeManager
          newAgentSession attachAgentSession guardHostTool;
}
