{ pkgs, jail, home-manager, devshellRoot, devshellHomeFolder,
  devshellHostHomeFolder, devshellUser, jailHomeDirectory, homeDirectory,
  forbiddenBindPaths ? [] }:

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

  hostGetCredHelper = pkgs.writeShellScriptBin "git-credential-hostget" ''
    [ "$1" = get ] || exit 0
    exec ${getExe pkgs.git} credential-store --file ${jailHomeDirectory}/.git-credentials get
  '';

  # Git config forced on every git run in the jail via GIT_CONFIG_* env vars
  # (command-line scope: outranks a repo-local .git/config, and is inherited by
  # git run from other tools, e.g. gh): no hooks, no fsmonitor/ssh/ext commands,
  # and the credential-helper list is reset (empty entry) to hostGetCredHelper.
  saferHostGitConfig = [
    { key = "core.hooksPath";     value = "${pkgs.emptyDirectory}"; }
    { key = "core.fsmonitor";     value = "false"; }
    { key = "core.sshCommand";    value = "false"; }
    { key = "protocol.ext.allow"; value = "never"; }
    { key = "credential.helper";  value = ""; }
    { key = "credential.helper";  value = "hostget"; }
  ];
  hostGitEnv = with jail.combinators;
    [ (set-env "GIT_CONFIG_NOSYSTEM" "1")
      (set-env "GIT_CONFIG_COUNT" (toString (builtins.length saferHostGitConfig)))
      (add-pkg-deps [ hostGetCredHelper ])
    ] ++ pkgs.lib.concatLists (pkgs.lib.imap0 (i: c: [
      (set-env "GIT_CONFIG_KEY_${toString i}" c.key)
      (set-env "GIT_CONFIG_VALUE_${toString i}" c.value)
    ]) saferHostGitConfig);

  # git wrapper that refuses to run while the repo-local/worktree config contains
  # keys that can execute code or redirect credentials and whose names hostGitEnv
  # cannot pre-override (alias.*, url.*.insteadOf, filter.*, diff drivers, …).
  # Shadows the plain git when listed after commonJailPkgs (add-pkg-deps prepends
  # each package to PATH, so the last one wins).
  saferHostGit = pkgs.writeShellScriptBin "git" ''
    _args=("$@")
    # Collect the repo-locating global options preceding the subcommand, so the
    # audit below inspects the repo git will actually operate on (git -C …, etc.).
    _repo_opts=()
    while [ $# -gt 0 ]; do
      case "$1" in
        # repo-locating, separate value
        -C|--git-dir|--work-tree|--namespace)
          [ $# -ge 2 ] || break
          _repo_opts+=("$1" "$2"); shift 2 ;;
        # repo-locating, inline value or none
        --git-dir=*|--work-tree=*|--namespace=*|--bare)
          _repo_opts+=("$1"); shift ;;
        # value-taking globals that don't affect repo discovery
        -c|--config-env|--attr-source)
          [ $# -ge 2 ] || break
          shift 2 ;;
        # any other global flag is valueless; first non-flag is the subcommand
        -*)
          shift ;;
        *)
          break ;;
      esac
    done
    # Audit only the local and worktree scopes: system is disabled, global is the
    # ro-bound host ~/.gitconfig, and command scope is hostGitEnv's own overrides.
    _cfg="$(${getExe pkgs.git} "''${_repo_opts[@]}" --no-pager config --list --show-scope 2>/dev/null |
      awk -F'\t' '$1 == "local" || $1 == "worktree" { print $2 }')" || _cfg=""
    _bad="$(printf '%s\n' "$_cfg" | grep -Ei '^(alias|url|filter|credential|include|includeif|submodule|http|protocol|pager|gpg|sendemail|browser|web|man|instaweb|difftool|mergetool)\.|^core\.(hookspath|fsmonitor|fsmonitorhookversion|sshcommand|gitproxy|pager|editor|askpass)|^sequence\.editor|^trailer\.[^.]+\.(command|cmd)|^diff\.(external|[^.]+\.(command|textconv))|^merge\.[^.]+\.driver|^remote\.[^.]+\.(uploadpack|receivepack|proxy|vcs)')" || _bad=""
    if [ -n "$_bad" ]; then
      {
        echo "git: refusing to run — dangerous repo-local git config (this checkout is agent-writable):"
        printf '%s\n' "$_bad" | awk '{ print "  " $0 }'
        echo "inspect .git/config (and .git/config.worktree), remove the offending keys, then retry"
      } >&2
      exit 1
    fi
    exec ${getExe pkgs.git} "''${_args[@]}"
  '';

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
  # Jail network whitelist logic (proxiedNetwork argument of makeJailed)
  #############################################################################

  # A network-restricted jail keeps jail.nix's default empty netns (kernel-enforced
  # deny-all egress) and reaches the outside world only through a host-side allowlist
  # proxy, bridged in over a unix socket by an in-jail socat.

  # The allowlist is enforced by tinyproxy. One instance runs on the host (host netns, real
  # DNS) per restricted-jail *process*, so several instances of the same jail can run at
  # once; tinyproxy speaks TCP only, so ip2unix makes it listen on a per-instance unix
  # socket instead, which is bound into the jail's empty netns (see makeJailed).

  cacertBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  proxyPort = 3128;                           # in-jail TCP that HTTP(S)_PROXY targets
  jailProxySock = "/run/jail-net/proxy.sock"; # host proxy socket, bound into the jail here

  # In-jail socat legs (for a jail's launcher).
  # Client legs listen on 127.0.0.1 and forward to a bound unix socket.
  proxyClientLeg = "socat TCP-LISTEN:${toString proxyPort},bind=127.0.0.1,nodelay,fork,reuseaddr UNIX-CONNECT:${jailProxySock} 2>/dev/null &";

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
  mkRestrictedNetOptions = name: allowedDomains: with jail.combinators; [
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
    # Per-instance host proxy socket (keyed by the launcher's PID) so concurrent
    # instances of this jail don't collide. ip2unix makes tinyproxy listen on it
    # directly; its TCP port is virtual, so instances cannot clash on it either.
    # SECURITY: never bind .cache/ or .cache/jail-net into a jail — it holds every
    # instance's proxy socket, and a jail reaching it could use another jail's
    # allowlist. Only the single socket file below enters the jail.
    (add-runtime ''
      _jn_dir="${homeDirectory}/.cache/jail-net"
      mkdir -p "$_jn_dir"
      JAIL_PROXY_HOST_SOCK="$_jn_dir/${name}.$$.sock"
      rm -f "$JAIL_PROXY_HOST_SOCK"
      ${getExe pkgs.ip2unix} -r in,tcp,port=${toString proxyPort},path="$JAIL_PROXY_HOST_SOCK" \
        ${getExe pkgs.tinyproxy} -d -c ${mkProxyConf name allowedDomains} \
        >>"$_jn_dir/${name}-proxy.log" 2>&1 &
      _jn_pid=$!
      # the socket appearing means tinyproxy accepted its conf and bound the listener
      _jn_w=0
      until [ -S "$JAIL_PROXY_HOST_SOCK" ]; do
        if ! kill -0 "$_jn_pid" 2>/dev/null || [ "$_jn_w" -gt 100 ]; then
          echo "${name}: could not start network proxy (see $_jn_dir/${name}-proxy.log)" >&2
          exit 1
        fi
        _jn_w=$((_jn_w + 1)); sleep 0.05
      done
      RUNTIME_ARGS+=(--bind "$JAIL_PROXY_HOST_SOCK" ${jailProxySock})
    '')
    (add-cleanup ''
      kill "''${_jn_pid-}" 2>/dev/null || true
      rm -f "''${JAIL_PROXY_HOST_SOCK-}"
    '')
  ];

  # Default-deny allowlist: a host is reachable iff it equals an allowed domain or is a
  # subdomain of it. Each domain d becomes the anchored ERE  (^|\.)d$  (dots escaped),
  # so `julialang.org` allows `pkg.julialang.org` but not `notjulialang.org` nor
  # `julialang.org.evil.com`.
  mkProxyFilterFile = name: domains: pkgs.writeText "${name}-proxy.filter"
    (pkgs.lib.concatMapStringsSep "\n"
      (d: "(^|\\.)" + (builtins.replaceStrings [ "." ] [ "\\." ] d) + "$")
      domains + "\n");

  # Build-time tinyproxy conf. The port is never bound on the host — ip2unix redirects
  # the listener to the per-instance unix socket (see makeJailed) — so it is a constant
  # and the whole conf can live in the store.
  mkProxyConf = name: domains: pkgs.writeText "${name}-tinyproxy.conf" ''
    Port ${toString proxyPort}
    Listen 127.0.0.1
    Timeout 86400 # long timout since Claude sometimes re-uses tunnel openned long ago (e.g., long time between calling advisor).
    MaxClients 100
    LogLevel Notice
    FilterDefaultDeny Yes
    Filter "${mkProxyFilterFile name domains}"
    FilterType ere
    FilterCaseSensitive Off
    ConnectPort 443
    ConnectPort 80
  '';


  #############################################################################
  # Server sockets (spawn a jailed server on demand from inside a jail)
  #############################################################################

  # Returns jail options that let programs inside the jail spawn `serverExe` (a
  # jailed launcher derivation) on demand, stdio-wired — the pattern MCP clients
  # and LSP hosts expect, made to work across the jail boundary. add-runtime
  # starts an idle per-instance host-side listener that spawns one fresh
  # `serverExe` process per connection (`pipes` gives it plain stdio fds), and
  # binds only the single socket file to `jailSockPath` inside the jail;
  # add-cleanup kills the listener and removes the socket when the jail exits.
  # The in-jail client connects with `socat - UNIX-CONNECT:<jailSockPath>`.
  # SECURITY: never bind .cache/<name>-sock itself into a jail — it holds every
  # instance's listener socket; add it to forbiddenBindPaths (cf. flake.nix).
  mkServerSocketOptions = name: serverExe: jailSockPath:
    let
      # shell variables are keyed by `name` so that several server sockets in
      # one jail cannot clobber each other's cleanup state; `r` is the
      # `$`-prefixed reference form (`$${…}` in the script would be literal)
      v = "_${builtins.replaceStrings [ "-" "." ] [ "_" "_" ] name}";
      r = "$" + v;
    in with jail.combinators; [
      (add-runtime ''
        ${v}_dir="${homeDirectory}/.cache/${name}-sock"
        mkdir -p "${r}_dir"
        ${v}_sock="${r}_dir/${name}.$$.sock"
        rm -f "${r}_sock"
        ${getExe pkgs.socat} UNIX-LISTEN:"${r}_sock",fork EXEC:"${getExe serverExe}",pipes \
          >>"${r}_dir/${name}.log" 2>&1 &
        ${v}_pid=$!
        ${v}_w=0
        until [ -S "${r}_sock" ]; do
          if ! kill -0 "${r}_pid" 2>/dev/null || [ "${r}_w" -gt 100 ]; then
            echo "could not start the ${name} listener" >&2
            exit 1
          fi
          ${v}_w=$((${v}_w + 1)); sleep 0.05
        done
        RUNTIME_ARGS+=(--bind "${r}_sock" ${jailSockPath})
      '')
      # `|| true`: cleanups run under errexit, and a failed kill (process already
      # gone) must not abort the remaining cleanup lines
      (add-cleanup ''
        kill "''${${v}_pid-}" 2>/dev/null || true
        rm -f "''${${v}_sock-}"
      '')
    ];


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

  # Host paths no jail may bind (directly, beneath, or via an ancestor bind source);
  # enforced at eval time by assertNoForbiddenBinds. Footgun check, not a boundary.
  # Per-jail exceptions (exact paths, human-approved) come in via makeJailed's
  # trustedBindPaths: they are blanked from the scanned text and accepted as sources.
  protectedHostPaths = [ "${homeDirectory}/.cache/jail-net" ] ++ forbiddenBindPaths;
  assertNoForbiddenBinds = name: trustedBindPaths: jailed:
    let
      scrubbedText = builtins.replaceStrings
        trustedBindPaths (map (_: "") trustedBindPaths) jailed.text;
      ancestors = path: pkgs.lib.foldl
        (acc: c: acc ++ [ "${pkgs.lib.last acc}/${c}" ]) [ "" ]
        (pkgs.lib.filter (c: c != "") (pkgs.lib.splitString "/" path));
      exposes = path:
        pkgs.lib.any
          (p: pkgs.lib.hasInfix " ${p} " scrubbedText || pkgs.lib.hasInfix "'${p}'" scrubbedText)
          (map (p: if p == "" then "/" else p) (ancestors path))
        || pkgs.lib.hasInfix "${path}/" scrubbedText;
      exposed = pkgs.lib.filter exposes protectedHostPaths;

      # static bind sources parsed from the bwrap args
      firstArg = s:
        if pkgs.lib.hasPrefix "'" s
        then builtins.head (pkgs.lib.splitString "'" (pkgs.lib.removePrefix "'" s))
        else builtins.head (pkgs.lib.splitString " " s);
      bindSources = pkgs.lib.imap0
        (i: chunk: if i == 0 || pkgs.lib.isList chunk then null else firstArg chunk)
        (builtins.split "--(ro-|dev-)?bind(-try)? +" jailed.text);
      allowedSource = s:
        pkgs.lib.hasPrefix "\"" s ||                       # runtime-expanded ("$PWD", …)
        pkgs.lib.hasPrefix builtins.storeDir s ||
        pkgs.lib.hasPrefix "${homeDirectory}/" s ||
        pkgs.lib.hasPrefix "~/.local/share/jail.nix/" s || # jail.nix fake-passwd data
        s == "/run/systemd/resolve" ||                     # jail.nix network combinator
        builtins.elem s trustedBindPaths;
      outside = pkgs.lib.filter (s: s != null && !allowedSource s) bindSources;
    in
    assert pkgs.lib.assertMsg (exposed == [])
      "${name}: a bind exposes ${toString exposed} inside the jail";
    assert pkgs.lib.assertMsg (outside == [])
      "${name}: bind sources outside ${homeDirectory} and the nix store: ${toString outside}";
    jailed;

  # Main function to create a sandboxed `exe`
  # `network` and `proxiedNetwork` are mutually exclusive.
  makeJailed = { name, exe, extraArgs ? "", socatLegs ? [], network ? false,
                 options ? [], extraPkgs ? [], proxiedNetwork ? false, allowedDomains ? [],
                 trustedBindPaths ? [] }:
    assert pkgs.lib.assertMsg (!(network && proxiedNetwork))
      "${name}: network and proxiedNetwork are mutually exclusive";
    assert pkgs.lib.assertMsg (proxiedNetwork || allowedDomains == [])
      "${name}: allowedDomains must be empty when proxiedNetwork = false";
    let
      allSocatLegs = pkgs.lib.optionals proxiedNetwork [ proxyClientLeg ] ++ socatLegs;
      program = mkLauncher name exe extraArgs allSocatLegs;
    in assertNoForbiddenBinds name trustedBindPaths (jail name program (
      [ (jail.combinators.add-runtime (assertInDevshell name)) ] ++
      commonJailOptions ++
      pkgs.lib.optionals network [ jail.combinators.network ] ++
      pkgs.lib.optionals (!network) localhostResolveBinds ++
      pkgs.lib.optionals proxiedNetwork (mkRestrictedNetOptions name allowedDomains) ++
      options ++
      [ (jail.combinators.add-pkg-deps extraPkgs) ]));

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
  inherit makeJailed mkServerSocketOptions gitReadBinds nixLdBinds hostGitEnv saferHostGit
          hostHomeManager newAgentSession attachAgentSession guardHostTool;
}
