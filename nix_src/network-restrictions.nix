{ pkgs, jail, jailHomeDirectory, homeDirectory }:

let
  inherit (pkgs.lib) getExe;

  cacertBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

in rec {

  ################################
  # Jail network whitelist logic #
  ################################

  # A network-restricted jail keeps jail.nix's default empty netns (kernel-enforced
  # deny-all egress) and reaches the outside world only through a host-side allowlist
  # proxy, bridged in over a unix socket by an in-jail socat.

  # The allowlist is enforced by tinyproxy. One instance runs per restricted jail on the
  # host (host netns, real DNS); tinyproxy speaks TCP only, so it is bridged into the
  # jail's empty netns over a bound unix socket (see jailNetProxy).

  proxyPort = 3128;                           # in-jail TCP that HTTP(S)_PROXY targets
  jailProxySock = "/run/jail-net/proxy.sock"; # host proxy socket, bound into the jail here

  # Default-deny allowlist: a host is reachable iff it equals an allowed domain or is a
  # subdomain of it. Each domain d becomes the anchored ERE  (^|\.)d$  (dots escaped),
  # so `julialang.org` allows `pkg.julialang.org` but not `notjulialang.org` nor
  # `julialang.org.evil.com`.
  mkProxyFilterFile = name: domains: pkgs.writeText "${name}-proxy.filter"
    (pkgs.lib.concatMapStringsSep "\n"
      (d: "(^|\\.)" + (builtins.replaceStrings [ "." ] [ "\\." ] d) + "$")
      domains + "\n");

  mkProxyConfFile = name: hostPort: domains: pkgs.writeText "${name}-tinyproxy.conf" ''
    Port ${toString hostPort}
    Listen 127.0.0.1
    Timeout 600
    MaxClients 100
    LogLevel Notice
    FilterDefaultDeny Yes
    Filter "${mkProxyFilterFile name domains}"
    FilterType ere
    FilterCaseSensitive Off
    ConnectPort 443
    ConnectPort 80
  '';

  # Host-side launcher (args: SOCKET CONF PORT): start tinyproxy for a jail, then expose
  # it on the bound unix socket with socat (tinyproxy speaks TCP only). Runs in the
  # foreground; when the wrapper kills it, the trap tears down both children. Exits as
  # soon as either child dies, so the wrapper's liveness check notices a dead proxy.
  jailNetProxy = pkgs.writeShellScriptBin "jail-net-proxy" ''
    set -eu
    _sock="$1"; _conf="$2"; _port="$3"
    ${getExe pkgs.tinyproxy} -d -c "$_conf" &
    _tp=$!
    rm -f "$_sock"
    ${getExe pkgs.socat} UNIX-LISTEN:"$_sock",fork,reuseaddr TCP:127.0.0.1:"$_port" &
    _so=$!
    trap 'kill "$_tp" "$_so" 2>/dev/null' EXIT INT TERM
    wait -n
  '';

  # Empty-netns jails have no /etc/hosts or /etc/nsswitch.conf (the `network`
  # combinator used to provide them), so `localhost` won't resolve.
  localhostResolveBinds = with jail.combinators; [
    (write-text "/etc/hosts" "127.0.0.1 localhost\n::1 localhost\n")
    (write-text "/etc/nsswitch.conf" "hosts: files dns\n")
  ];

  # In-jail socat legs (for a jail's launcher).
  # Client legs listen on 127.0.0.1 and forward to a bound unix socket.
  proxyClientLeg = "socat TCP-LISTEN:${toString proxyPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailProxySock} 2>/dev/null &";

  # Options a restricted (proxied) jail needs: point HTTP clients at the in-jail proxy
  # endpoint, keep localhost direct, and supply a CA bundle since /etc/ssl is unbound.
  restrictedNetOptions = localhostResolveBinds ++ (with jail.combinators; [
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
  ]);


  ###################################
  # Kaimon specific in-jail sockets #
  ###################################

  # The Claude<->Kaimon MCP channel is bridged the same way over a shared unix
  # socket, so localhost:2828 keeps working once both jails leave the host netns.

  kaimonPort = 2828;                                  # in-jail TCP for Kaimon's MCP server
  jailKaimonSock = "${jailHomeDirectory}/.cache/kaimon-jail-sock/kaimon.sock";

  # Shared dir for the Claude<->Kaimon MCP socket, kept OUTSIDE .cache/kaimon which
  # Kaimon wipes on startup.
  kaimonBridgeBinds = with jail.combinators; [
    (rw-bind "${homeDirectory}/.cache/kaimon-jail-sock" "${jailHomeDirectory}/.cache/kaimon-jail-sock")
  ];

  kaimonClientLeg = "socat TCP-LISTEN:${toString kaimonPort},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${jailKaimonSock} 2>/dev/null &";
  kaimonServerLeg = "rm -f ${jailKaimonSock}; socat UNIX-LISTEN:${jailKaimonSock},fork,reuseaddr TCP:127.0.0.1:${toString kaimonPort} 2>/dev/null &";
}
