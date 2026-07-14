{
  lib,
  ...
}:
{
  name = "netbird-server-management";

  meta.maintainers = with lib.maintainers; [
    RafaelKr
  ];

  # Geolocation downloads a database on startup, which fails in the sandboxed
  # (network-isolated) test VMs; disable it for every node.
  defaults.services.netbird.server.management.environment.NB_DISABLE_GEOLOCATION = true;

  nodes = {
    management = {
      services.netbird.server.management = {
        enable = true;
        domain = "mgmt.test";
        turnDomain = "turn.test";
        port = 8011;
        metricsPort = 9090;
        logLevel = "DEBUG";
        settings = {
          # Use a test encryption key
          DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
        };
      };
    };

    managementWithRelay = {
      services.netbird.server.management = {
        enable = true;
        domain = "mgmt-relay.test";
        turnDomain = "turn.test";
        port = 8011;
        metricsPort = 9090;

        # Configure relay
        relayAddresses = [ "rels://relay.test:443" ];
        relaySecretFile = "/run/secrets/relay-secret";

        settings = {
          # Use a test encryption key
          DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
        };
      };

      # Create a test secret file
      systemd.services.netbird-management.preStart = lib.mkBefore ''
        mkdir -p /run/secrets
        echo "test-relay-secret" > /run/secrets/relay-secret
      '';
    };

    managementWithPostgres = {
      services.netbird.server.management = {
        enable = true;
        domain = "mgmt-pg.test";
        turnDomain = "turn.test";
        port = 8011;
        metricsPort = 9090;

        store = {
          engine = "postgres";
          dsnFile = "/etc/netbird/store-dsn";
        };

        settings = {
          # Use a test encryption key
          DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
        };
      };

      # LoadCredential reads the DSN before the unit starts, so it must exist
      # up front rather than being written in preStart.
      environment.etc."netbird/store-dsn".text =
        "host=/run/postgresql user=netbird dbname=netbird sslmode=disable";

      services.postgresql = {
        enable = true;
        ensureDatabases = [ "netbird" ];
        ensureUsers = [
          {
            name = "netbird";
            ensureDBOwnership = true;
          }
        ];
        # Let the management service connect over the peer socket without a password.
        authentication = lib.mkForce "local all all trust";
      };

      systemd.services.netbird-management = {
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
      };
    };

    managementWithMysql =
      { pkgs, ... }:
      {
        services.netbird.server.management = {
          enable = true;
          domain = "mgmt-my.test";
          turnDomain = "turn.test";
          port = 8011;
          metricsPort = 9090;

          store = {
            engine = "mysql";
            dsnFile = "/etc/netbird/store-dsn";
          };

          settings = {
            # Use a test encryption key
            DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
          };
        };

        # netbird-mgmt runs as root, so connect as the socket-authenticated root
        # user (go-sql-driver accepts a unix(...) DSN).
        environment.etc."netbird/store-dsn".text = "root@unix(/run/mysqld/mysqld.sock)/netbird";

        services.mysql = {
          enable = true;
          package = pkgs.mariadb;
          ensureDatabases = [ "netbird" ];
        };

        systemd.services.netbird-management = {
          after = [ "mysql.service" ];
          requires = [ "mysql.service" ];
        };
      };

    managementWithEmbeddedIdp = {
      services.netbird.server.management = {
        enable = true;
        domain = "mgmt-idp.test";
        turnDomain = "turn.test";
        port = 8011;
        metricsPort = 9090;

        # Enable the embedded identity provider (selects the attrTag + enables it).
        idp.embedded.enable = true;

        settings = {
          # Use a test encryption key
          DataStoreEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
          # The embedded Dex IdP needs a 16/24/32-byte session cookie key to boot.
          EmbeddedIdP.SessionCookieEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
        };
      };
    };
  };

  testScript = ''
    start_all()

    # Test basic management server
    management.wait_for_unit("netbird-management.service")
    management.wait_for_open_port(8011)
    management.wait_for_open_port(9090)

    # Verify state directory exists
    management.succeed("test -d /var/lib/netbird-mgmt")
    management.succeed("test -d /var/lib/netbird-mgmt/data")

    # Verify config file was generated
    management.succeed("test -f /var/lib/netbird-mgmt/management.json")

    # Verify the default store selects the sqlite engine
    management.succeed(
        "grep -qE '\"Engine\":[[:space:]]*\"sqlite\"' /var/lib/netbird-mgmt/management.json"
    )

    # Test management with relay configuration
    managementWithRelay.wait_for_unit("netbird-management.service")
    managementWithRelay.wait_for_open_port(8011)

    # Verify relay config is in the generated config
    managementWithRelay.succeed("grep -q 'Relay' /var/lib/netbird-mgmt/management.json")
    managementWithRelay.succeed("grep -q 'rels://relay.test:443' /var/lib/netbird-mgmt/management.json")

    # Test management with PostgreSQL
    managementWithPostgres.wait_for_unit("postgresql.service")
    managementWithPostgres.wait_for_unit("netbird-management.service")
    managementWithPostgres.wait_for_open_port(8011)

    # Verify postgres engine is in config
    managementWithPostgres.succeed(
        "grep -qE '\"Engine\":[[:space:]]*\"postgres\"' /var/lib/netbird-mgmt/management.json"
    )

    # Test management with MySQL
    managementWithMysql.wait_for_unit("mysql.service")
    managementWithMysql.wait_for_unit("netbird-management.service")
    managementWithMysql.wait_for_open_port(8011)

    # Verify mysql engine is in config
    managementWithMysql.succeed(
        "grep -qE '\"Engine\":[[:space:]]*\"mysql\"' /var/lib/netbird-mgmt/management.json"
    )

    # Test management with the embedded identity provider (idp.embedded attrTag)
    managementWithEmbeddedIdp.wait_for_unit("netbird-management.service")
    managementWithEmbeddedIdp.wait_for_open_port(8011)

    # Verify the embedded IdP block was rendered into the config
    managementWithEmbeddedIdp.succeed(
        "grep -q '\"EmbeddedIdP\"' /var/lib/netbird-mgmt/management.json"
    )
  '';
}
