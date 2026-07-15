{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  inherit (lib)
    any
    boolToString
    concatMap
    escapeShellArgs
    getExe'
    isBool
    literalExpression
    mapAttrs
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    optional
    optionals
    optionalAttrs
    optionalString
    recursiveUpdate
    ;

  inherit (lib.types)
    attrTag
    attrsOf
    bool
    either
    enum
    listOf
    nullOr
    path
    port
    str
    submodule
    ;

  inherit (utils) genJqSecretsReplacementSnippet;

  cfg = config.services.netbird.server.management;

  stateDir = "/var/lib/netbird-mgmt";

  settingsFormat = pkgs.formats.json { };

  # netbird-mgmt reads the SQL DSN only from a per-engine env var, never from
  # management.json. Follow the *effective* engine (settings.StoreConfig.Engine
  # overrides store.engine via recursiveUpdate) so the DSN is wired for the same
  # engine that lands in the rendered config; null unless a dsnFile is provided.
  storeDsn =
    let
      engine = managementConfig.StoreConfig.Engine;
    in
    if cfg.store.dsnFile == null then
      null
    else if engine == "postgres" then
      {
        env = "NB_STORE_ENGINE_POSTGRES_DSN";
        file = cfg.store.dsnFile;
      }
    else if engine == "mysql" then
      {
        env = "NB_STORE_ENGINE_MYSQL_DSN";
        file = cfg.store.dsnFile;
      }
    else
      null;

  embeddedIdpEnabled = (cfg.idp ? embedded) && cfg.idp.embedded.enable;

  defaultSettings = {
    Stuns = [
      {
        Proto = "udp";
        URI = "stun:${cfg.turnDomain}:3478";
        Username = "";
        Password = null;
      }
    ];

    TURNConfig = {
      Turns = [ ];

      CredentialsTTL = "12h";
      Secret = null;
      TimeBasedCredentials = false;
    };

    Relay = {
      Addresses = cfg.relayAddresses;
      CredentialsTTL = "24h";
      Secret = if cfg.relaySecretFile != null then { _secret = cfg.relaySecretFile; } else "";
    };

    Signal = {
      Proto = "https";
      URI = "${cfg.domain}:443";
      Username = "";
      Password = null;
    };

    ReverseProxy = {
      TrustedHTTPProxies = [ ];
      TrustedHTTPProxiesCount = 0;
      TrustedPeers = [ "0.0.0.0/0" ];
    };

    Datadir = "${stateDir}/data";
    DataStoreEncryptionKey = null;
    StoreConfig.Engine = cfg.store.engine;

    HttpConfig = {
      Address = "127.0.0.1:${toString cfg.port}";
      IdpSignKeyRefreshEnabled = true;
      OIDCConfigEndpoint = cfg.oidcConfigEndpoint;
    };

    IdpManagerConfig = {
      ManagerType = "none";
      ClientConfig = {
        Issuer = if embeddedIdpEnabled then "https://${cfg.domain}/oauth2" else "";
        TokenEndpoint = "";
        ClientID = "netbird";
        ClientSecret = "";
        GrantType = "client_credentials";
      };
      ExtraConfig = { };
      Auth0ClientCredentials = null;
      AzureClientCredentials = null;
      KeycloakClientCredentials = null;
      ZitadelClientCredentials = null;
    };

    DeviceAuthorizationFlow = {
      Provider = "none";
      ProviderConfig = {
        Audience = "netbird";
        Domain = null;
        ClientID = "netbird";
        TokenEndpoint = null;
        DeviceAuthEndpoint = "";
        Scope = "openid profile email";
        UseIDToken = false;
      };
    };

    PKCEAuthorizationFlow = {
      ProviderConfig = {
        Audience = "netbird";
        ClientID = "netbird";
        ClientSecret = "";
        AuthorizationEndpoint = "";
        TokenEndpoint = "";
        Scope = "openid profile email";
        RedirectURLs = [ "http://localhost:53000" ];
        UseIDToken = false;
      };
    };
  }
  // optionalAttrs embeddedIdpEnabled {
    EmbeddedIdP = {
      Enabled = true;
      Issuer = "https://${cfg.domain}/oauth2";
      LocalAddress = "127.0.0.1:${toString cfg.port}";
      Storage = {
        Type = "sqlite3";
        Config.File = "${stateDir}/idp.db";
      };
      DashboardRedirectURIs = [
        "https://${cfg.domain}/nb-auth"
        "https://${cfg.domain}/nb-silent-auth"
      ];
      CLIRedirectURIs = [
        "http://localhost:53000/"
        "http://localhost:54000/"
      ];
      Owner = {
        Email = "";
        Hash = "";
        Username = "";
      };
    };
  };

  managementConfig = recursiveUpdate defaultSettings cfg.settings;

  managementFile = settingsFormat.generate "config.json" managementConfig;
in

{
  imports = [
    (lib.mkRenamedOptionModule
      [
        "services"
        "netbird"
        "server"
        "management"
        "singleAccountModeDomain"
      ]
      [
        "services"
        "netbird"
        "server"
        "management"
        "singleAccountMode"
        "domain"
      ]
    )
    (lib.mkRemovedOptionModule [
      "services"
      "netbird"
      "server"
      "management"
      "disableSingleAccountMode"
    ] "Use services.netbird.server.management.singleAccountMode.enable = false instead.")
  ];

  options.services.netbird.server.management = {
    enable = mkEnableOption "NetBird Management Service";

    package = mkPackageOption pkgs "netbird-management" { };

    domain = mkOption {
      type = str;
      description = "The domain under which the management API runs.";
    };

    turnDomain = mkOption {
      type = str;
      description = "The domain of the TURN server to use.";
    };

    turnPort = mkOption {
      type = port;
      default = 3478;
      description = ''
        The port of the TURN server to use.
      '';
    };

    dnsDomain = mkOption {
      type = str;
      default = "netbird.selfhosted";
      description = "Domain used for peer resolution.";
    };

    singleAccountMode = {
      enable = mkOption {
        type = bool;
        default = true;
        description = ''
          Enable single account mode where all users are grouped under a single account.
          If the installation already has more than one account, this setting is ineffective.
        '';
      };

      domain = mkOption {
        type = str;
        default = "netbird.selfhosted";
        description = ''
          Domain used to group users in single account mode.
          Only used when `singleAccountMode.enable` is true.
        '';
      };
    };

    disableAnonymousMetrics = mkOption {
      type = bool;
      default = true;
      description = "Disables push of anonymous usage metrics to NetBird.";
    };

    environment = mkOption {
      type = submodule {
        freeformType = attrsOf (either str bool);
        options.NB_DISABLE_GEOLOCATION = mkOption {
          type = nullOr bool;
          default = null;
          description = ''
            Disable the GeoLite2 geolocation service. When geolocation is left
            enabled (the NetBird default), netbird-management downloads the
            GeoLite2-City database on startup and fails to start without network
            access or a database pre-provisioned in its data directory. Set to
            `true` for air-gapped deployments.
          '';
        };
      };
      default = { };
      description = ''
        Extra environment variables for the netbird-management service (NetBird
        reads `NB_*` variables). Do not put secrets here, as they would be
        world-readable in the unit; use the dedicated secret options such as
        `store.dsnFile` instead.
      '';
    };

    port = mkOption {
      type = port;
      default = 8011;
      description = "Internal port of the management server.";
    };

    metricsPort = mkOption {
      type = port;
      default = 9090;
      description = "Internal port of the metrics server.";
    };

    extraOptions = mkOption {
      type = listOf str;
      default = [ ];
      description = ''
        Additional options given to netbird-mgmt as commandline arguments.
      '';
    };

    oidcConfigEndpoint = mkOption {
      type = str;
      default = "";
      description = "The oidc discovery endpoint. Not required when using embedded IDP.";
      example = "https://example.eu.auth0.com/.well-known/openid-configuration";
    };

    # Relay configuration
    relayAddresses = mkOption {
      type = listOf str;
      default = [ ];
      description = ''
        List of relay server addresses to advertise to clients.
      '';
      example = [ "rels://relay.example.com:443" ];
    };

    relaySecretFile = mkOption {
      type = nullOr path;
      default = null;
      description = ''
        Path to file containing the shared secret for relay authentication.
        This must match the auth-secret configured on the relay server.
      '';
    };

    # TLS configuration
    tls = {
      enable = mkEnableOption "TLS for the management server";

      letsencrypt = {
        domain = mkOption {
          type = nullOr str;
          default = null;
          description = ''
            Domain for automatic Let's Encrypt certificate.
            When set, the management server will automatically obtain and renew certificates.
          '';
        };
      };

      certFile = mkOption {
        type = nullOr path;
        default = null;
        description = "Path to the TLS certificate file.";
      };

      certKey = mkOption {
        type = nullOr path;
        default = null;
        description = "Path to the TLS certificate key file.";
      };
    };

    # Identity provider
    idp = mkOption {
      type = nullOr (attrTag {
        embedded = mkOption {
          type = submodule {
            options.enable = mkEnableOption "NetBird's built-in (embedded Dex) identity provider";
          };
          default = { };
          description = ''
            Run NetBird's built-in (embedded Dex) identity provider, served by
            the management server under `/oauth2`. It configures the
            `EmbeddedIdP` section with defaults derived from the domain;
            customize it through the {option}`settings` freeform option (e.g.
            `settings.EmbeddedIdP.Owner.Email = "admin@example.com"`).
          '';
        };
      });
      default = null;
      description = ''
        Identity provider backend for the management API. Select and enable a
        backend, e.g. `idp.embedded.enable = true`. Leave unset to use an
        external OIDC provider configured via {option}`oidcConfigEndpoint`.
      '';
    };

    # Database backend configuration
    store = {
      engine = mkOption {
        type = enum [
          "sqlite"
          "postgres"
          "mysql"
        ];
        default = "sqlite";
        description = ''
          Database engine for the management store, rendered to NetBird's
          `StoreConfig.Engine`. `sqlite` keeps the database in the management
          state directory; `postgres` and `mysql` connect using {option}`dsnFile`.
        '';
      };

      dsnFile = mkOption {
        type = nullOr path;
        default = null;
        description = ''
          Path to a file containing the connection DSN for the `postgres` or
          `mysql` engine (NetBird reads it from `NB_STORE_ENGINE_<ENGINE>_DSN`).
          It is passed to netbird-mgmt as a systemd credential, so the DSN stays
          out of the Nix store and the unit environment. Unused for `sqlite`.

          Example (postgres): `host=localhost user=netbird dbname=netbird`

          Example (mysql): `netbird:password@tcp(localhost:3306)/netbird`
        '';
      };
    };

    settings = mkOption {
      inherit (settingsFormat) type;

      defaultText = literalExpression ''
        defaultSettings = {
          Stuns = [
            {
              Proto = "udp";
              URI = "stun:''${cfg.turnDomain}:3478";
              Username = "";
              Password = null;
            }
          ];

          TURNConfig = {
            Turns = [ ];

            CredentialsTTL = "12h";
            Secret = null;
            TimeBasedCredentials = false;
          };

          Relay = {
            Addresses = cfg.relayAddresses;
            CredentialsTTL = "24h";
            Secret = "";
          };

          Signal = {
            Proto = "https";
            URI = "''${cfg.domain}:443";
            Username = "";
            Password = null;
          };

          ReverseProxy = {
            TrustedHTTPProxies = [ ];
            TrustedHTTPProxiesCount = 0;
            TrustedPeers = [ "0.0.0.0/0" ];
          };

          Datadir = "''${stateDir}/data";
          DataStoreEncryptionKey = null;
          StoreConfig = { Engine = "sqlite"; };

          HttpConfig = {
            Address = "127.0.0.1:''${toString cfg.port}";
            IdpSignKeyRefreshEnabled = true;
            OIDCConfigEndpoint = cfg.oidcConfigEndpoint;
          };

          IdpManagerConfig = {
            ManagerType = "none";
            ClientConfig = {
              Issuer = "";
              TokenEndpoint = "";
              ClientID = "netbird";
              ClientSecret = "";
              GrantType = "client_credentials";
            };

            ExtraConfig = { };
            Auth0ClientCredentials = null;
            AzureClientCredentials = null;
            KeycloakClientCredentials = null;
            ZitadelClientCredentials = null;
          };

          DeviceAuthorizationFlow = {
            Provider = "none";
            ProviderConfig = {
              Audience = "netbird";
              Domain = null;
              ClientID = "netbird";
              TokenEndpoint = null;
              DeviceAuthEndpoint = "";
              Scope = "openid profile email";
              UseIDToken = false;
            };
          };

          PKCEAuthorizationFlow = {
            ProviderConfig = {
              Audience = "netbird";
              ClientID = "netbird";
              ClientSecret = "";
              AuthorizationEndpoint = "";
              TokenEndpoint = "";
              Scope = "openid profile email";
              RedirectURLs = [ "http://localhost:53000" ];
              UseIDToken = false;
            };
          };
        };
      '';

      default = { };

      description = ''
        Configuration of the NetBird management server.
        Options containing secret data should be set to an attribute set containing the attribute _secret
        - a string pointing to a file containing the value the option should be set to.
        See the example to get a better picture of this: in the resulting management.json file,
        the `DataStoreEncryptionKey` key will be set to the contents of the /run/agenix/netbird_mgmt-data_store_encryption_key file.
      '';

      example = {
        DataStoreEncryptionKey = {
          _secret = "/run/agenix/netbird_mgmt-data_store_encryption_key";
        };
      };
    };

    logLevel = mkOption {
      type = enum [
        "ERROR"
        "WARN"
        "INFO"
        "DEBUG"
      ];
      default = "INFO";
      description = "Log level of the NetBird services.";
    };
  };

  config = mkIf cfg.enable {
    warnings =
      concatMap
        (
          { check, name }:
          optional check "${name} is world-readable in the Nix Store, you should provide it as a _secret."
        )
        [
          {
            check = builtins.isString managementConfig.TURNConfig.Secret;
            name = "The TURNConfig.Secret";
          }
          {
            check = builtins.isString managementConfig.DataStoreEncryptionKey;
            name = "The DataStoreEncryptionKey";
          }
          {
            check = any (T: (T ? Password) && builtins.isString T.Password) managementConfig.TURNConfig.Turns;
            name = "A TURNConfig.Turns password";
          }
          {
            check =
              cfg.relayAddresses != [ ]
              && managementConfig ? Relay
              && builtins.isString (managementConfig.Relay.Secret or "");
            name = "The Relay.Secret";
          }
        ]
      ++
        optional (cfg.environment.NB_DISABLE_GEOLOCATION != true)
          "netbird-management: geolocation is enabled; it downloads the GeoLite2-City database on startup and fails to start without network access or a database pre-provisioned in its data directory. Set services.netbird.server.management.environment.NB_DISABLE_GEOLOCATION = true for air-gapped deployments."
      ++
        optional
          (
            (cfg.settings.StoreConfig.Engine or null) != null
            && cfg.settings.StoreConfig.Engine != cfg.store.engine
          )
          "netbird-management: settings.StoreConfig.Engine (${
            cfg.settings.StoreConfig.Engine or ""
          }) overrides store.engine (${cfg.store.engine}); the settings value wins and drives the DSN credential. Set store.engine instead of overriding it via settings."
      ++
        optional
          (
            !embeddedIdpEnabled
            && (managementConfig.HttpConfig.OIDCConfigEndpoint or "") == ""
            && (managementConfig.HttpConfig.AuthIssuer or "") == ""
          )
          "netbird-management: no identity provider is configured (neither idp.embedded nor oidcConfigEndpoint, and no settings.HttpConfig.AuthIssuer). The management API has no working authentication and the dashboard cannot log in. Select idp.embedded.enable = true or set oidcConfigEndpoint.";

    assertions = [
      {
        assertion = managementConfig.StoreConfig.Engine == "sqlite" || cfg.store.dsnFile != null;
        message = "services.netbird.server.management.store.dsnFile is required for the '${managementConfig.StoreConfig.Engine}' store engine.";
      }
      {
        assertion = cfg.port != cfg.metricsPort;
        message = "The primary listen port cannot be the same as the listen port for the metrics endpoint";
      }
      {
        assertion =
          cfg.tls.enable
          -> (cfg.tls.letsencrypt.domain != null || (cfg.tls.certFile != null && cfg.tls.certKey != null));
        message = "When TLS is enabled, either letsencrypt.domain or both certFile and certKey must be set";
      }
      {
        assertion = cfg.tls.certFile != null -> cfg.tls.certKey != null;
        message = "certKey must be set when certFile is set";
      }
      {
        assertion = cfg.tls.certKey != null -> cfg.tls.certFile != null;
        message = "certFile must be set when certKey is set";
      }
      {
        assertion = !embeddedIdpEnabled || cfg.oidcConfigEndpoint == "";
        message = "oidcConfigEndpoint should not be set when using embedded IDP";
      }
      {
        assertion = managementConfig.DataStoreEncryptionKey != null;
        message = ''
          services.netbird.server.management.settings.DataStoreEncryptionKey must be set.
          Generate a key with `openssl rand -base64 32` and provide it as a secret, e.g.
          management.settings.DataStoreEncryptionKey._secret = "/run/secrets/netbird-datastore-key".
        '';
      }
      {
        assertion =
          !managementConfig.TURNConfig.TimeBasedCredentials || managementConfig.TURNConfig.Secret != null;
        message = "settings.TURNConfig.Secret must be set when TURNConfig.TimeBasedCredentials is enabled";
      }
    ];

    systemd.services.netbird-management = {
      description = "The management server for NetBird, a wireguard VPN";
      documentation = [ "https://netbird.io/docs/" ];

      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ managementFile ];

      preStart = genJqSecretsReplacementSnippet managementConfig "${stateDir}/management.json";

      environment = mapAttrs (_: value: if isBool value then boolToString value else value) (
        removeAttrs cfg.environment [ "_module" ]
      );

      serviceConfig = {
        ExecStart =
          let
            args = [
              (getExe' cfg.package "netbird-mgmt")
              "management"
              "--config"
              "${stateDir}/management.json"
              "--datadir"
              "${stateDir}/data"
              "--dns-domain"
              cfg.dnsDomain
              "--port"
              cfg.port
              "--metrics-port"
              cfg.metricsPort
              "--log-file"
              "console"
              "--log-level"
              cfg.logLevel
              "--idp-sign-key-refresh-enabled"
            ]
            # Single account mode
            ++ optionals cfg.singleAccountMode.enable [
              "--single-account-mode-domain"
              cfg.singleAccountMode.domain
            ]
            ++ (optional (!cfg.singleAccountMode.enable) "--disable-single-account-mode")
            ++ (optional cfg.disableAnonymousMetrics "--disable-anonymous-metrics")
            # Always disable GeoLite updates for self-hosted (privacy default)
            ++ [ "--disable-geolite-update" ]
            # TLS options
            ++ optionals (cfg.tls.letsencrypt.domain != null) [
              "--letsencrypt-domain"
              cfg.tls.letsencrypt.domain
            ]
            ++ optionals (cfg.tls.certFile != null) [
              "--cert-file"
              cfg.tls.certFile
            ]
            ++ optionals (cfg.tls.certKey != null) [
              "--cert-key"
              cfg.tls.certKey
            ]
            ++ cfg.extraOptions;
          in
          # The SQL DSN is a secret and netbird-mgmt only reads it from an env
          # var, so export it from a systemd credential at runtime instead of
          # baking it into the world-readable store or unit environment.
          "${pkgs.writeShellScript "netbird-management" ''
            ${optionalString (storeDsn != null) ''
              export ${storeDsn.env}="$(< "$CREDENTIALS_DIRECTORY/store-dsn")"
            ''}
            exec ${escapeShellArgs args}
          ''}";
        Restart = "always";
        LoadCredential = optional (storeDsn != null) "store-dsn:${storeDsn.file}";
        RuntimeDirectory = "netbird-mgmt";
        StateDirectory = [
          "netbird-mgmt"
          "netbird-mgmt/data"
        ];
        StateDirectoryMode = "0750";
        RuntimeDirectoryMode = "0750";
        WorkingDirectory = stateDir;

        # hardening
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateMounts = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };

      stopIfChanged = false;
    };

    services.netbird.server.ingressRoutes = {
      # NetBird management API route (v0.74.6): "/api" -> HTTP (backend router).
      # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L861-L867
      management-api = {
        path = "/api";
        backend.proxy.upstream = "127.0.0.1:${toString cfg.port}";
      };

      # NetBird management gRPC route (v0.74.6): "/management.ManagementService/" -> gRPC (h2c).
      # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L854-L860
      management-grpc = {
        path = "/management.ManagementService/";
        backend.grpc.upstream = "127.0.0.1:${toString cfg.port}";
      };

      # NetBird management WebSocket-proxy route (v0.74.6): "/ws-proxy/management" —
      # gRPC over WebSocket for browser/WASM clients (not the reverse-proxy feature).
      # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L861-L867
      management-wsproxy = {
        path = "/ws-proxy/management";
        backend.websocket.upstream = "127.0.0.1:${toString cfg.port}";
      };
    }
    // optionalAttrs embeddedIdpEnabled {
      # The embedded IdP is served by the management server under /oauth2.
      # NetBird route (v0.74.6): "/oauth2" -> HTTP (backend router).
      # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L861-L867
      management-oauth2 = {
        path = "/oauth2";
        backend.proxy.upstream = "127.0.0.1:${toString cfg.port}";
      };
    };
  };
}
