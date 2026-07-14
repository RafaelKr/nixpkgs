{
  lib,
  ...
}:
{
  name = "netbird-server-ingress";

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

          useRelay = true;
          relayAuthSecretFile = "/etc/netbird/relay-secret";

          management.settings.DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
          # Geolocation downloads a database on startup, which fails in the
          # sandboxed (network-isolated) test VM.
          management.environment.NB_DISABLE_GEOLOCATION = true;
          dashboard.settings.AUTH_AUTHORITY = "http://server/oauth2";

          # Serve every plane through the bundled nginx ingress.
          ingress.nginx.enable = true;
        };
      };
  };

  testScript =
    { nodes, ... }:
    ''
      start_all()

      server.wait_for_unit("netbird-management.service")
      server.wait_for_unit("netbird-signal.service")
      server.wait_for_unit("netbird-relay.service")
      server.wait_for_unit("nginx.service")
      # Wait for the backends to actually bind before proxying through nginx.
      server.wait_for_open_port(8011)
      server.wait_for_open_port(8012)
      server.wait_for_open_port(80)

      with subtest("dashboard static export is served"):
          server.succeed("curl -sSf http://localhost/ -o /dev/null")

      with subtest("unknown routes fall back to the exported 404.html app shell"):
          code = server.succeed(
              "curl -s -o /dev/null -w '%{http_code}' http://localhost/does-not-exist"
          )
          assert code == "404", f"expected 404 SPA fallback, got {code}"

      with subtest("/api reaches the management backend (no 502)"):
          code = server.succeed(
              "curl -s -o /dev/null -w '%{http_code}' http://localhost/api/"
          )
          assert code != "502", "nginx could not reach the management backend"

      with subtest("gRPC and relay planes are wired into the vhost"):
          # Dump the exact config nginx was started with (its own `-c`), not the
          # package-default config a bare `nginx -T` would read.
          cfg = server.succeed("${nodes.server.systemd.services.nginx.serviceConfig.ExecStart} -T 2>&1")
          assert "signalexchange.SignalExchange" in cfg, "signal gRPC location missing"
          assert "management.ManagementService" in cfg, "management gRPC location missing"
          assert "grpc_pass" in cfg, "gRPC pass directive missing"
          assert "/relay" in cfg, "relay websocket location missing"
    '';
}
