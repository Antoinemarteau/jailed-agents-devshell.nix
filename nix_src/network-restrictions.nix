# Network-restriction plumbing for the jails
#
# A network-restricted jail keeps jail.nix's default empty netns (kernel-enforced
# deny-all egress) and reaches the outside world only through a host-side allowlist
# proxy, bridged in over a unix socket by an in-jail socat. The Claude<->Kaimon MCP
# channel is bridged the same way over a shared unix socket, so localhost:2828 keeps
# working once both jails leave the host netns.
{ pkgs, jail, jailHomeDirectory, homeDirectory }:

let
  inherit (pkgs.lib) getExe;

  cacertBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # Minimal filtering HTTP proxy: allowlists CONNECT (HTTPS) and absolute-form HTTP
  # by hostname suffix + port (80/443), listens on a unix socket. Runs on the host
  # (host netns, real DNS); the jail can only reach it via the bound socket.
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

in rec {

  ################################
  # Jail network whitelist logic #
  ################################

  proxyPort = 3128;                                   # in-jail TCP that HTTP(S)_PROXY targets
  jailProxySock = "/run/jail-net/proxy.sock";         # host proxy socket, bound into the jail here
  jailNetProxy = pkgs.writeShellScriptBin "jail-net-proxy" ''
    exec ${getExe pkgs.python3} ${jailNetProxyPy} "$@"
  '';

  # Empty-netns jails have no /etc/hosts or /etc/nsswitch.conf (the `network`
  # combinator used to provide them), so `localhost` won't resolve. Provide minimal
  # ones; must NOT be combined with the `network` combinator (which binds its own).
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
