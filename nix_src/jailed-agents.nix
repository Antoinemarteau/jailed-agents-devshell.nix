{ pkgs, jail, julia-pkg, claude-pkg, devshellRoot, devshellProjectsFolder, devshellUser, homeDirectory }:

let
  inherit (pkgs.lib) getExe getExe';

  commonPkgs = with pkgs; [
    bashInteractive
    less
    curl
    # wget          # redundant with curl
    jq
    git
    socat           # tcp<->unix bridges for the network/MCP sockets
    which
    ripgrep
    gnugrep
    # gawkInteractive  # awk text processor, not required
    ps              # required by Kaimon
    findutils
    # gzip          # archive tools, not required by Claude Code or Julia
    # unzip
    # gnutar
    diffutils
  ];

  jailHomeDirectory = "/home/${devshellUser}";

  commonJailOptions = with jail.combinators; [
    time-zone
    no-new-session
    mount-cwd
    (set-env "USER" devshellUser)
    (set-env "HOME" jailHomeDirectory)
    # writable tmpfs at /home/agents so programs can create transient files (e.g. lock files) in $HOME;
    (tmpfs jailHomeDirectory)
    (add-pkg-deps commonPkgs)
  ];

  claudeConfigWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.claude" "${jailHomeDirectory}/.claude")
    (rw-bind "${homeDirectory}/.claude.json" "${jailHomeDirectory}/.claude.json")
  ];

  gitReadBinds = with jail.combinators; [
    (try-ro-bind "${homeDirectory}/.gitconfig" "${jailHomeDirectory}/.gitconfig")
    (try-ro-bind "${homeDirectory}/.git-credentials" "${jailHomeDirectory}/.git-credentials")
  ];

  localhostResolveBinds = with jail.combinators; [
    (write-text "/etc/hosts" "127.0.0.1 localhost\n::1 localhost\n")
    (write-text "/etc/nsswitch.conf" "hosts: files dns\n")
  ];

  juliaDepotWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.julia" "${jailHomeDirectory}/.julia")
  ];

  # for Kaimon <-> Julia communication
  kaimonCacheWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.cache/kaimon" "${jailHomeDirectory}/.cache/kaimon")
  ];

  mcpBridgeBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.cache/kaimon-jail-sock" "${jailHomeDirectory}/.cache/kaimon-jail-sock")
  ];

  kaimonConfigWriteBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.config/kaimon" "${jailHomeDirectory}/.config/kaimon")
  ];

  # Architecture specific ELF interpreter, e.g. /lib64/ld-linux-x86-64.so.2
  # for nix-ld support
  nixLdInterpreterPath = pkgs.lib.removeSuffix "\n" (builtins.readFile "${pkgs.nix-ld}/nix-support/ldpath");
  nixLdBinds = with jail.combinators; [
    (ro-bind "${pkgs.nix-ld}/libexec/nix-ld" nixLdInterpreterPath)
    (add-pkg-deps [ pkgs.glibc pkgs.stdenv.cc.cc pkgs.zlib ])
    (fwd-env "NIX_LD")
    (fwd-env "NIX_LD_LIBRARY_PATH")
  ];

  # ── Network restriction (no srt) ──────────────────────────────────────────
  # A network-restricted jail keeps jail.nix's default empty netns (no `network`
  # combinator = kernel-enforced deny-all egress) and reaches the outside world
  # only through a host-side allowlist proxy, bridged in over a unix socket by an
  # in-jail socat. Claude<->Kaimon MCP is bridged the same way over a shared unix
  # socket, so localhost:2828 keeps working once both jails leave the host netns.
  proxyPort = 3128;                                   # in-jail TCP that HTTP(S)_PROXY targets
  mcpPort = 2828;                                     # in-jail TCP for Kaimon's MCP server
  jailProxySock = "/run/jail-net/proxy.sock";         # host proxy socket, bound into the jail here
  jailMcpSock = "${jailHomeDirectory}/.cache/kaimon-jail-sock/mcp.sock"; # shared MCP socket (both jails)
  cacertBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # Default egress allowlist for Claude. Suffix-matched, so "anthropic.com" also
  # allows api.anthropic.com etc. github.com/githubusercontent.com cover git push
  # over HTTPS with the configured token.
  defaultAllowedDomains = [
    "anthropic.com"
    "claude.ai"
    "claude.com"
    "github.com"
    "githubusercontent.com"
  ];

  # Minimal filtering HTTP proxy: allowlists CONNECT (HTTPS) and absolute-form
  # HTTP by hostname suffix + port (80/443), listens on a unix socket. Runs on the
  # host (host netns, real DNS); the jail can only reach it via the bound socket.
  jailNetProxyPy = pkgs.writeText "jail-net-proxy.py" ''
    import sys
    import os
    import socket
    import threading
    from urllib.parse import urlsplit

    ALLOWED = []
    ALLOWED_PORTS = {80, 443}

    def host_allowed(host):
        if not host:
            return False
        host = host.lower().rstrip(".")
        for d in ALLOWED:
            if host == d or host.endswith("." + d):
                return True
        return False

    def read_head(sock):
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
            if len(buf) > 65536:
                break
        head, _, rest = buf.partition(b"\r\n\r\n")
        return head, rest

    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def tunnel(client, upstream):
        t = threading.Thread(target=pump, args=(client, upstream), daemon=True)
        t.start()
        pump(upstream, client)
        t.join()

    def deny(client, code, msg):
        try:
            client.sendall(("HTTP/1.1 " + code + " " + msg +
                "\r\nContent-Length: 0\r\nConnection: close\r\nX-Jail-Proxy: blocked\r\n\r\n").encode())
        except OSError:
            pass

    def handle(client):
        try:
            head, rest = read_head(client)
            if not head:
                return
            lines = head.split(b"\r\n")
            parts = lines[0].split(b" ")
            if len(parts) < 3:
                return
            method = parts[0].decode("latin1")
            target = parts[1].decode("latin1")
            version = parts[2].decode("latin1")
            if method.upper() == "CONNECT":
                hp = target.rsplit(":", 1)
                host = hp[0]
                port = int(hp[1]) if len(hp) == 2 else 443
                if port not in ALLOWED_PORTS or not host_allowed(host):
                    sys.stderr.write("jail-net-proxy: BLOCK CONNECT " + host + ":" + str(port) + "\n")
                    deny(client, "403", "Forbidden")
                    return
                try:
                    upstream = socket.create_connection((host, port), timeout=30)
                except OSError:
                    deny(client, "502", "Bad Gateway")
                    return
                client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                if rest:
                    upstream.sendall(rest)
                tunnel(client, upstream)
                return
            u = urlsplit(target)
            host = u.hostname
            port = u.port or 80
            if not host or port not in ALLOWED_PORTS or not host_allowed(host):
                sys.stderr.write("jail-net-proxy: BLOCK " + method + " " + target + "\n")
                deny(client, "403", "Forbidden")
                return
            path = u.path or "/"
            if u.query:
                path = path + "?" + u.query
            try:
                upstream = socket.create_connection((host, port), timeout=30)
            except OSError:
                deny(client, "502", "Bad Gateway")
                return
            out = [method + " " + path + " " + version]
            for line in lines[1:]:
                low = line.lower()
                if low.startswith(b"proxy-") or low.startswith(b"connection:"):
                    continue
                out.append(line.decode("latin1"))
            out.append("Connection: close")
            upstream.sendall(("\r\n".join(out) + "\r\n\r\n").encode("latin1"))
            if rest:
                upstream.sendall(rest)
            tunnel(client, upstream)
        except Exception:
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass

    def main():
        if len(sys.argv) < 3:
            sys.stderr.write("usage: jail-net-proxy SOCKET ALLOWED_CSV\n")
            sys.exit(2)
        sockpath = sys.argv[1]
        global ALLOWED
        ALLOWED = [d.strip().lower().rstrip(".") for d in sys.argv[2].split(",") if d.strip()]
        try:
            os.unlink(sockpath)
        except OSError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(sockpath)
        srv.listen(128)
        sys.stderr.write("jail-net-proxy: listening on " + sockpath + " allow=" + ",".join(ALLOWED) + "\n")
        while True:
            try:
                client, _ = srv.accept()
            except OSError:
                continue
            threading.Thread(target=handle, args=(client,), daemon=True).start()

    if __name__ == "__main__":
        main()
  '';

  jailNetProxy = pkgs.writeShellScriptBin "jail-net-proxy" ''
    exec ${getExe pkgs.python3} ${jailNetProxyPy} "$@"
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

  # `proxyDomains` (a domain list) makes the host wrapper start the allowlist proxy
  # for this jail on a unix socket bound in at jailProxySock, and tear it down when
  # the jail exits.
  makeJailed = { name, program, preHook ? "", network ? false, options ? [], extraPkgs ? [],
                 proxyDomains ? null }:
    let
      proxyBinds = pkgs.lib.optionals (proxyDomains != null) [
        (jail.combinators.rw-bind "${homeDirectory}/.cache/jail-net/${name}.sock" jailProxySock)
      ];
      inner = jail "${name}-inner" program (
        commonJailOptions ++
        pkgs.lib.optionals network [ jail.combinators.network ] ++
        proxyBinds ++
        options ++
        [ (jail.combinators.add-pkg-deps extraPkgs) ]);
      runInner =
        if proxyDomains == null then ''
          exec ${getExe inner} "$@"
        '' else ''
          _jn_dir="${homeDirectory}/.cache/jail-net"
          _jn_sock="$_jn_dir/${name}.sock"
          mkdir -p "$_jn_dir"
          rm -f "$_jn_sock"
          ${getExe jailNetProxy} "$_jn_sock" "${pkgs.lib.concatStringsSep "," proxyDomains}" >>"$_jn_dir/${name}-proxy.log" 2>&1 &
          _jn_pid=$!
          trap '_jn_st=$?; kill "$_jn_pid" 2>/dev/null; exit $_jn_st' EXIT INT TERM
          _jn_w=0
          while [ ! -S "$_jn_sock" ]; do
            if ! kill -0 "$_jn_pid" 2>/dev/null; then
              echo "${name}: network proxy exited before creating its socket" >&2
              exit 1
            fi
            [ "$_jn_w" -gt 200 ] && { echo "${name}: timed out waiting for network proxy socket" >&2; exit 1; }
            _jn_w=$((_jn_w + 1))
            sleep 0.05
          done
          ${getExe inner} "$@"
        '';
    in pkgs.writeShellScriptBin name ''
      ${assertInDevshell name}
      ${preHook}
      ${runInner}
    '';

  makeJailedClaude = { extraPkgs ? [], name ? "jailed-claude", allowedDomains ? defaultAllowedDomains }:
    let
      claudeLauncher = pkgs.writeShellScriptBin "claude" ''
        # empty netns: reach the internet only through the host allowlist proxy
        socat TCP-LISTEN:${toString proxyPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailProxySock} 2>/dev/null &
        # reach Kaimon's MCP server over the shared unix socket (localhost bypasses the proxy via NO_PROXY)
        socat TCP-LISTEN:${toString mcpPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailMcpSock} 2>/dev/null &
        exec ${getExe claude-pkg} "$@"
      '';
    in makeJailed {
      inherit name extraPkgs;
      program = claudeLauncher;
      network = false;
      proxyDomains = allowedDomains;
      preHook = ''
        # makes sure a writable and host persisted .claude.json file exists
        [ -f ${homeDirectory}/.claude.json ] || echo '{}' > ${homeDirectory}/.claude.json
        # shared dir for the Claude<->Kaimon MCP socket
        mkdir -p ${homeDirectory}/.cache/kaimon-jail-sock
      '';
      options = claudeConfigWriteBinds ++ gitReadBinds ++ mcpBridgeBinds ++ localhostResolveBinds ++ (with jail.combinators; [
        (set-env "HTTP_PROXY"  "http://127.0.0.1:${toString proxyPort}")
        (set-env "HTTPS_PROXY" "http://127.0.0.1:${toString proxyPort}")
        (set-env "http_proxy"  "http://127.0.0.1:${toString proxyPort}")
        (set-env "https_proxy" "http://127.0.0.1:${toString proxyPort}")
        (set-env "NO_PROXY"    "localhost,127.0.0.1")
        (set-env "no_proxy"    "localhost,127.0.0.1")
        # no /etc/ssl in an empty netns jail; point TLS clients at the cacert bundle
        (set-env "SSL_CERT_FILE"       cacertBundle)
        (set-env "NIX_SSL_CERT_FILE"   cacertBundle)
        (set-env "GIT_SSL_CAINFO"      cacertBundle)
        (set-env "CURL_CA_BUNDLE"      cacertBundle)
        (set-env "NODE_EXTRA_CA_CERTS" cacertBundle)
        (add-pkg-deps [ pkgs.cacert ])
      ]);
    };

  makeJailedJulia = { extraPkgs ? [], network ? false, name ? "jailed-julia" }:
    makeJailed {
      inherit name extraPkgs network;
      program = julia-pkg;
      preHook = ''
        [ -d ${homeDirectory} ]
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
      '';
      options = with jail.combinators;
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        nixLdBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
        ];
    };

  makeJailedKaimon = { extraPkgs ? [], name ? "jailed-kaimon" }:
    let
      kaimonLauncher = pkgs.writeShellScriptBin "kaimon" ''
        # expose Kaimon's local MCP server on the shared unix socket for the jailed client
        rm -f ${jailMcpSock}
        socat UNIX-LISTEN:${jailMcpSock},fork,reuseaddr TCP:127.0.0.1:${toString mcpPort} 2>/dev/null &
        exec ~/.julia/bin/kaimon "$@"
      '';
    in makeJailed {
      inherit name extraPkgs;
      program = kaimonLauncher;
      network = false;
      preHook = ''
        [ -d ${homeDirectory} ]
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
        mkdir -p ${homeDirectory}/.cache/kaimon-jail-sock
        mkdir -p ${homeDirectory}/.config/kaimon
      '';
      options = with jail.combinators;
        juliaDepotWriteBinds ++
        kaimonCacheWriteBinds ++
        mcpBridgeBinds ++
        kaimonConfigWriteBinds ++
        localhostResolveBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
          (add-pkg-deps [ julia-pkg ])
        ];
    };

  # This is for working within project folders and debugging the jails
  makeJailedShell = { extraPkgs ? [], name ? "jailed-shell" }:
    makeJailed {
      inherit name extraPkgs;
      program = pkgs.zsh;
      network = true;
      preHook = ''
        # makes sure a writable and host persisted .claude.json file exists
        [ -f ${homeDirectory}/.claude.json ] || echo '{}' > ${homeDirectory}/.claude.json
        # similar with Kaimon config folders
        mkdir -p ${homeDirectory}/.cache/kaimon/sock
        mkdir -p ${homeDirectory}/.config/kaimon
      '';
      options = with jail.combinators;
        claudeConfigWriteBinds ++
        gitReadBinds ++
        juliaDepotWriteBinds ++
        kaimonConfigWriteBinds ++
        kaimonCacheWriteBinds ++
        nixLdBinds ++ [
          (share-ns "pid") # required for Kaimon <-> Julia servers comm.
          (ro-bind "${homeDirectory}/.config/zsh" "${jailHomeDirectory}/.config/zsh")
          (set-env "ZDOTDIR" "${jailHomeDirectory}/.config/zsh")
          (set-env "LANG" "C.UTF-8")
          (set-env "TERMINFO_DIRS" "${pkgs.ncurses}/share/terminfo")
          (add-pkg-deps [ pkgs.zsh pkgs.ncurses ])
        ];
    };

in {
  inherit makeJailedClaude makeJailedShell makeJailedJulia makeJailedKaimon;
}
