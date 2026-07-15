{
  lib,
  pkgs,
  ...
}:
let
  # A self-signed default certificate lets this air-gapped test exercise the
  # real websecure (TLS-terminating) routers without reaching Let's Encrypt.
  tlsCert = pkgs.runCommand "netbird-traefik-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=server" -addext "subjectAltName=DNS:server" \
      -keyout "$out/key.pem" -out "$out/cert.pem"
  '';
in
{
  name = "netbird-server-ingress-traefik";

  meta.maintainers = with lib.maintainers; [
    RafaelKr
  ];

  nodes = {
    server =
      { ... }:
      {
        # The relay auth secret is read at unit start (LoadCredential) and while
        # templating the management config, so it must exist before activation.
        environment.etc."netbird/relay-secret".text = "test-relay-secret";

        services.netbird.server = {
          enable = true;
          domain = "server";

          relay.enable = true;
          relay.authSecretFile = "/etc/netbird/relay-secret";

          management.settings.DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
          # Geolocation downloads a database on startup, which fails in the
          # sandboxed (network-isolated) test VM.
          management.environment.NB_DISABLE_GEOLOCATION = true;
          dashboard.settings.AUTH_AUTHORITY = "http://server/oauth2";

          # Serve every plane through the bundled Traefik ingress.
          ingress.traefik = {
            enable = true;
            # Air-gapped: no Let's Encrypt. Terminate with the self-signed cert
            # provided as Traefik's default certificate below.
            acme.enable = false;
            dynamicConfigOptions.tls.stores.default.defaultCertificate = {
              certFile = "${tlsCert}/cert.pem";
              keyFile = "${tlsCert}/key.pem";
            };
            # Expose Traefik's API so the test can inspect the generated routing.
            staticConfigOptions = {
              api.insecure = true;
              entryPoints.traefik.address = ":8080";
            };
          };

          # Stub L4 passthrough route (the NetBird reverse proxy lands here once
          # its own module exists) to exercise the HostSNI(*) + PROXY-protocol
          # render. The upstream has no listener; only the routing is asserted.
          ingressPassthrough.proxy.upstream = "127.0.0.1:8443";
        };
      };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("netbird-management.service")
    server.wait_for_unit("netbird-signal.service")
    server.wait_for_unit("netbird-relay.service")
    # The loopback nginx that serves the static dashboard, and Traefik itself.
    server.wait_for_unit("nginx.service")
    server.wait_for_unit("traefik.service")
    server.wait_for_open_port(8011)
    server.wait_for_open_port(8012)
    server.wait_for_open_port(8083)
    server.wait_for_open_port(443)
    server.wait_for_open_port(8080)

    # The SNI must be the management domain so the specific-SNI L7 routers win
    # over the HostSNI(*) passthrough; --resolve pins it to loopback.
    curl = "curl -sk --resolve server:443:127.0.0.1"

    with subtest("dashboard static export is served through Traefik over TLS"):
        code = server.succeed(f"{curl} -o /dev/null -w '%{{http_code}}' https://server/")
        assert code == "200", f"expected 200 for the dashboard, got {code}"

    with subtest("unknown routes fall back to the exported 404.html app shell"):
        code = server.succeed(f"{curl} -o /dev/null -w '%{{http_code}}' https://server/does-not-exist")
        assert code == "404", f"expected 404 SPA fallback, got {code}"

    with subtest("/api reaches the management backend (no 502)"):
        code = server.succeed(f"{curl} -o /dev/null -w '%{{http_code}}' https://server/api/")
        assert code != "502", "Traefik could not reach the management backend"

    with subtest("every plane is wired into Traefik's dynamic config"):
        routers = server.succeed("curl -sSf http://localhost:8080/api/http/routers")
        for r in [
            "netbird-dashboard",
            "netbird-management-api",
            "netbird-management-grpc",
            "netbird-signal-grpc",
            "netbird-relay-ws",
        ]:
            assert r in routers, f"missing http router {r}"

    with subtest("gRPC upstreams use the h2c scheme"):
        services = server.succeed("curl -sSf http://localhost:8080/api/http/services")
        assert "h2c://" in services, "no h2c (gRPC) upstream in Traefik services"

    with subtest("the NetBird reverse proxy L4 SNI passthrough is wired"):
        tcp = server.succeed("curl -sSf http://localhost:8080/api/tcp/routers")
        assert "netbird-proxy" in tcp, "missing HostSNI(*) passthrough router"
  '';
}
