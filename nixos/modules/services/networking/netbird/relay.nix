{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatStringsSep
    escapeShellArgs
    getExe'
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    optionals
    ;

  inherit (lib.types)
    bool
    listOf
    enum
    path
    port
    str
    ;

  cfg = config.services.netbird.server.relay;
  stateDir = "/var/lib/netbird-relay";
in

{
  options.services.netbird.server.relay = {
    enable = mkEnableOption "NetBird's native relay server, the modern and recommended replacement for coturn";

    package = mkPackageOption pkgs "netbird-relay" { };

    port = mkOption {
      type = port;
      default = 33080;
      description = ''
        Port the relay server listens on.
        When served behind an ingress, this is the internal port it proxies to.
      '';
    };

    exposedAddress = mkOption {
      type = str;
      description = ''
        The public URL where clients can reach this relay server.
        This is advertised to clients via the management server.
      '';
      example = "rels://relay.example.com:443";
    };

    authSecretFile = mkOption {
      type = path;
      description = ''
        Path to a file containing the relay authentication secret.
        The file should contain only the raw secret value.
        This must match the relaySecretFile configured in the management server;
        when the full server stack is used
        ({option}`services.netbird.server.enable`), the management server's
        relaySecretFile is derived from this automatically.
      '';
    };

    logLevel = mkOption {
      type = enum [
        "panic"
        "fatal"
        "error"
        "warn"
        "info"
        "debug"
        "trace"
      ];
      default = "info";
      description = "Log level for the relay server.";
    };

    stun = {
      enable = mkOption {
        type = bool;
        default = true;
        description = ''
          Enable the embedded STUN server.
          This provides STUN functionality alongside the relay server.
        '';
      };

      ports = mkOption {
        type = listOf port;
        default = [ 3478 ];
        description = "UDP ports for the embedded STUN server.";
      };
    };

    openFirewall = mkOption {
      type = bool;
      default = false;
      description = ''
        Whether to open the relay and STUN ports in the firewall.
      '';
    };

    metricsPort = mkOption {
      type = port;
      default = 9092;
      description = "Port for the relay metrics endpoint.";
    };

    extraOptions = mkOption {
      type = listOf str;
      default = [ ];
      description = ''
        Additional command-line options passed to the relay server.
        Use this for advanced settings like TLS configuration
        (e.g. `["--tls-cert-file" "/path/to/cert" "--tls-key-file" "/path/to/key"]`).
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      systemd.services.netbird-relay = {
        description = "NetBird Relay Server";
        documentation = [ "https://docs.netbird.io/" ];

        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [
          cfg.port
          cfg.logLevel
          cfg.exposedAddress
          cfg.stun.enable
        ];

        serviceConfig = {
          LoadCredential = [ "auth-secret:${cfg.authSecretFile}" ];

          ExecStart =
            let
              args = [
                (getExe' cfg.package "netbird-relay")
                "--listen-address"
                ":${toString cfg.port}"
                "--exposed-address"
                cfg.exposedAddress
                "--log-level"
                cfg.logLevel
                "--log-file"
                "console"
              ]
              ++ [
                "--metrics-port"
                (toString cfg.metricsPort)
              ]
              ++ optionals cfg.stun.enable [
                "--enable-stun"
                "--stun-ports"
                (concatStringsSep "," (map toString cfg.stun.ports))
              ]
              ++ cfg.extraOptions;
            in
            "${pkgs.writeShellScript "netbird-relay" ''
              export NB_AUTH_SECRET=$(< "$CREDENTIALS_DIRECTORY/auth-secret")
              exec ${escapeShellArgs args}
            ''}";

          Restart = "always";
          RuntimeDirectory = "netbird-relay";
          RuntimeDirectoryMode = "0750";
          StateDirectory = "netbird-relay";
          StateDirectoryMode = "0750";
          WorkingDirectory = stateDir;
          DynamicUser = true;

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

          # Relay may need to bind to privileged ports when not behind nginx
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        };

        stopIfChanged = false;
      };

      # NetBird relay route (v0.74.6): "/relay" -> WebSocket.
      # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L861-L867
      services.netbird.server.ingressRoutes.relay-ws = {
        path = "/relay";
        backend.websocket.upstream = "127.0.0.1:${toString cfg.port}";
      };
    }

    (mkIf cfg.openFirewall {
      networking.firewall = {
        allowedTCPPorts = [ cfg.port ];
        allowedUDPPorts = mkIf cfg.stun.enable cfg.stun.ports;
      };
    })
  ]);
}
