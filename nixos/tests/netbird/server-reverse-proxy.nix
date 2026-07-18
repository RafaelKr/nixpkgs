{
  lib,
  ...
}:
{
  name = "netbird-server-reverse-proxy";

  meta.maintainers = with lib.maintainers; [
    RafaelKr
  ];

  nodes = {
    proxy =
      { pkgs, ... }:
      let
        # The proxy loads a static certificate when ACME is disabled, and that
        # load is fatal on failure, so ship a self-signed pair. The management
        # stream, by contrast, retries forever and never blocks startup.
        testCert = pkgs.runCommand "netbird-proxy-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
          mkdir -p $out
          openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout $out/tls.key -out $out/tls.crt -subj "/CN=proxy.test"
        '';
      in
      {
        services.netbird.server.reverseProxy = {
          enable = true;
          domain = "proxy.test";
          # Unreachable management: the gRPC client is created lazily, so the
          # proxy stays up and retries in the background.
          managementAddress = "https://management.invalid";
          address = ":8443";
          # pkgs.writeText is world-readable but acceptable for tests.
          tokenFile = pkgs.writeText "proxy-token" "nbx_test_token";
          acme.enable = false;
          logLevel = "debug";
          openFirewall = true;
        };

        # Place the self-signed certificate where the proxy reads it (the
        # StateDirectory is created before ExecStartPre runs).
        systemd.services.netbird-proxy.preStart = ''
          install -D -m0400 ${testCert}/tls.crt /var/lib/netbird-proxy/certs/tls.crt
          install -D -m0400 ${testCert}/tls.key /var/lib/netbird-proxy/certs/tls.key
        '';
      };
  };

  testScript = ''
    start_all()

    proxy.wait_for_unit("netbird-proxy.service")

    # The main TLS listener binds and the health probe comes up, both without a
    # management connection.
    proxy.wait_for_open_port(8443)
    proxy.wait_for_open_port(8080)
    proxy.succeed("test -d /var/lib/netbird-proxy")
    proxy.succeed("journalctl -u netbird-proxy.service | grep -q 'proxy main listener bound'")

    # Liveness is 200; readiness is 503 until management connects (never here).
    proxy.wait_until_succeeds("curl -sf -o /dev/null http://localhost:8080/healthz/live", timeout=30)
    proxy.succeed(
        "test \"$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/healthz/ready)\" = 503"
    )
    proxy.succeed(
        "curl -s http://localhost:8080/healthz | grep -qE '\"management_connected\":[[:space:]]*false'"
    )

    # The management stream is retrying (non-fatal).
    proxy.wait_until_succeeds(
        "journalctl -u netbird-proxy.service | grep -q 'management connection failed, retrying'",
        timeout=30,
    )

    # The listener port is opened in the firewall.
    proxy.succeed("iptables -L -n | grep -q 8443")
  '';
}
