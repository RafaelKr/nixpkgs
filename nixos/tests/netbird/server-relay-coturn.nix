{
  lib,
  ...
}:
{
  name = "netbird-server-relay-coturn";

  meta.maintainers = with lib.maintainers; [
    RafaelKr
  ];

  nodes = {
    server =
      { ... }:
      {
        # The relay's embedded STUN and coturn both default to UDP 3478; move
        # coturn aside so the two STUN listeners coexist instead of colliding
        # (the collision is what services.netbird.server asserts against).
        services.coturn.listening-port = 3480;

        # Secrets are read at unit start (LoadCredential) and while templating the
        # management config, so they must exist before activation.
        environment.etc."netbird/relay-secret".text = "test-relay-secret";
        environment.etc."netbird/coturn-password".text = "test-coturn-password";

        services.netbird.server = {
          enable = true;
          domain = "server";

          # This test targets the relay/coturn axis, not the frontend. Disabling
          # the dashboard avoids an unrelated AUTH_AUTHORITY requirement.
          dashboard.enable = false;

          # Relay is the primary provider; coturn runs alongside it as the legacy
          # TURN fallback to exercise the "both enabled" path.
          relay.enable = true;
          relay.authSecretFile = "/etc/netbird/relay-secret";

          coturn = {
            enable = true;
            passwordFile = "/etc/netbird/coturn-password";
          };

          management.settings.DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
          # Geolocation downloads a database on startup, which fails in the
          # sandboxed (network-isolated) test VM.
          management.environment.NB_DISABLE_GEOLOCATION = true;
        };
      };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("netbird-relay.service")
    server.wait_for_unit("coturn.service")
    server.wait_for_unit("netbird-management.service")
    server.wait_for_unit("netbird-signal.service")

    # Relay TCP plane and management API bind.
    server.wait_for_open_port(33080)
    server.wait_for_open_port(8011)

    with subtest("relay STUN and coturn bind distinct UDP ports without colliding"):
        # The relay's embedded STUN keeps 3478; coturn was moved to 3480.
        server.wait_until_succeeds("ss -ulnH 'sport = :3478' | grep -q :3478")
        server.wait_until_succeeds("ss -ulnH 'sport = :3480' | grep -q :3480")

    with subtest("management advertises both the relay and the coturn TURN server"):
        server.succeed("grep -q 'rels://server:443' /var/lib/netbird-mgmt/management.json")
        server.succeed("grep -q 'turn:server:3480' /var/lib/netbird-mgmt/management.json")
  '';
}
