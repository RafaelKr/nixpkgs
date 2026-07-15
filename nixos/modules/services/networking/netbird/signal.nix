{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  inherit (lib)
    getExe'
    mkEnableOption
    mkIf
    mkPackageOption
    mkOption
    optionals
    ;

  inherit (lib.types)
    bool
    listOf
    enum
    nullOr
    path
    port
    str
    ;

  inherit (utils) escapeSystemdExecArgs;

  cfg = config.services.netbird.server.signal;
  stateDir = "/var/lib/netbird-signal";
in

{
  options.services.netbird.server.signal = {
    enable = mkEnableOption "NetBird's Signal Service";

    package = mkPackageOption pkgs "netbird-signal" { };

    domain = mkOption {
      type = str;
      description = "The domain name for the signal service.";
    };

    port = mkOption {
      type = port;
      default = 8012;
      description = "Internal port of the signal server.";
    };

    metricsPort = mkOption {
      type = port;
      default = 9091;
      description = "Internal port of the metrics server.";
    };

    tls = {
      enable = mkEnableOption "TLS for the signal server";

      letsencrypt = {
        domain = mkOption {
          type = nullOr str;
          default = null;
          description = ''
            Domain for automatic Let's Encrypt certificate.
            When set, the signal server will automatically obtain and renew certificates.
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

    openFirewall = mkOption {
      type = bool;
      default = false;
      description = ''
        Whether to open the signal server port in the firewall.
      '';
    };

    extraOptions = mkOption {
      type = listOf str;
      default = [ ];
      description = ''
        Additional options given to netbird-signal as commandline arguments.
      '';
    };

    logLevel = mkOption {
      type = enum [
        "ERROR"
        "WARN"
        "INFO"
        "DEBUG"
      ];
      default = "INFO";
      description = "Log level of the NetBird signal service.";
    };
  };

  config = mkIf cfg.enable {

    assertions = [
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
    ];

    systemd.services.netbird-signal = {
      description = "The signal server for NetBird, a wireguard VPN";
      documentation = [ "https://netbird.io/docs/" ];

      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        cfg.port
        cfg.logLevel
      ];

      serviceConfig = {
        ExecStart = escapeSystemdExecArgs (
          [
            (getExe' cfg.package "netbird-signal")
            "run"
            # Port to listen on
            "--port"
            cfg.port
            # Port the internal prometheus server listens on
            "--metrics-port"
            cfg.metricsPort
            # Log to stdout
            "--log-file"
            "console"
            # Log level
            "--log-level"
            cfg.logLevel
          ]
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
          ++ cfg.extraOptions
        );

        Restart = "always";
        RuntimeDirectory = "netbird-signal";
        RuntimeDirectoryMode = "0750";
        StateDirectory = "netbird-signal";
        StateDirectoryMode = "0750";
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

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };

    # NetBird signal route (v0.74.6): "/signalexchange.SignalExchange/" -> gRPC (h2c).
    # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L854-L860
    services.netbird.server.ingressRoutes.signal-grpc = {
      path = "/signalexchange.SignalExchange/";
      backend.grpc.upstream = "127.0.0.1:${toString cfg.port}";
    };

    # NetBird signal WebSocket-proxy route (v0.74.6): "/ws-proxy/signal" — gRPC
    # over WebSocket for browser/WASM clients (not the reverse-proxy feature).
    # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L861-L867
    services.netbird.server.ingressRoutes.signal-wsproxy = {
      path = "/ws-proxy/signal";
      backend.websocket.upstream = "127.0.0.1:${toString cfg.port}";
    };
  };
}
