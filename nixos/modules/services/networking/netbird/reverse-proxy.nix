{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    boolToString
    escapeShellArgs
    getExe'
    isBool
    last
    mapAttrs
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    optional
    optionalString
    optionals
    splitString
    ;

  inherit (lib.types)
    attrsOf
    bool
    either
    enum
    nullOr
    path
    str
    submodule
    ;

  cfg = config.services.netbird.server.reverseProxy;
  serverCfg = config.services.netbird.server;
  stateDir = "/var/lib/netbird-proxy";

  # The reverse proxy terminates its own TLS on this listener; on a single-IP
  # host the ingress front owns :443, so it L4 SNI-passthroughs to us here.
  listenPort = last (splitString ":" cfg.address);

  # An ingress front is selected, so the proxy is fronted rather than owning
  # its port directly. Contribute the L4 passthrough; the server-level assertion
  # rejects it unless that front is Traefik (nginx cannot forward TLS).
  fronted = serverCfg.ingress != null;
in

{
  options.services.netbird.server.reverseProxy = {
    enable = mkEnableOption "the NetBird reverse proxy, exposing NetBird network resources over the public internet";

    package = mkPackageOption pkgs "netbird-proxy" { };

    domain = mkOption {
      type = str;
      description = ''
        The domain at which this proxy is reached. Resources are exposed at
        `<subdomain>.<domain>`, so a wildcard DNS record `*.<domain>` must point
        at this host.
      '';
      example = "proxy.netbird.example.com";
    };

    managementAddress = mkOption {
      type = str;
      default = "https://${serverCfg.domain}";
      defaultText = lib.literalExpression ''"https://''${config.services.netbird.server.domain}"'';
      description = ''
        URL of the NetBird management server the proxy connects to, including
        the scheme. The scheme selects the transport: `https` uses TLS, anything
        else is plaintext and additionally requires
        {option}`services.netbird.server.reverseProxy.allowInsecure`.

        When the proxy runs on the same host as management, dialing the public
        management domain hairpins out to the public IP and back. Add a loopback
        override so it reaches the local ingress front directly (the TLS
        certificate still validates because the SNI matches):

        ```nix
        networking.hosts."127.0.0.1" = [ config.services.netbird.server.domain ];
        ```
      '';
    };

    address = mkOption {
      type = str;
      default = ":8443";
      description = ''
        Address the reverse proxy listens on. The default `:8443` avoids
        colliding with the ingress front on `:443`; the Traefik backend L4
        SNI-passthroughs to it. Use `:443` only on a dedicated host where the
        proxy owns the public IP.
      '';
    };

    tokenFile = mkOption {
      type = path;
      description = ''
        Path to a file containing the proxy access token (`nbx_...`), minted
        out-of-band on the management server (`netbird-mgmt admin token create` or the
        reverse-proxy REST API). The proxy refuses to start without it. The file
        should contain only the raw token value.
      '';
    };

    allowInsecure = mkOption {
      type = bool;
      default = false;
      description = ''
        Allow sending the proxy token over a non-TLS management connection.
        Required when {option}`services.netbird.server.reverseProxy.managementAddress`
        uses a plaintext (non-`https`) scheme, e.g. a loopback `http://` address.
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
      description = "Log level for the reverse proxy.";
    };

    forwardedProto = mkOption {
      type = enum [
        "auto"
        "http"
        "https"
      ];
      default = "auto";
      description = "Value of the `X-Forwarded-Proto` header sent to backends.";
    };

    trustedProxies = mkOption {
      type = str;
      default = "";
      description = ''
        Comma-separated list of trusted upstream proxy CIDR ranges. When the
        proxy sits behind an L4 front that adds PROXY protocol
        (see {option}`services.netbird.server.reverseProxy.proxyProtocol`), set this to
        the front's address so the real client IP is honoured, e.g. `127.0.0.1/32`
        for a loopback Traefik front.
      '';
      example = "127.0.0.1/32";
    };

    proxyProtocol = mkOption {
      type = bool;
      default = false;
      description = ''
        Expect PROXY protocol (v1/v2) on the proxy's TCP listener to recover the
        real client IP from an L4 front. Enable this when the Traefik backend L4
        SNI-passthroughs to the proxy; it also drives whether that passthrough
        wraps the forwarded stream in PROXY protocol v2, keeping both sides
        consistent. Also set {option}`services.netbird.server.reverseProxy.trustedProxies`.
      '';
    };

    supportsCustomPorts = mkOption {
      type = bool;
      default = true;
      description = ''
        Advertise to management that the proxy may bind arbitrary inbound ports
        for raw TCP/UDP passthrough resources (beyond the standard HTTPS
        listener). Standard HTTP(S)/TLS resources work regardless. These extra
        ports bypass any ingress front and are chosen by management at runtime,
        so opening them needs a matching firewall rule the module cannot derive.
      '';
    };

    requireSubdomain = mkOption {
      type = bool;
      default = false;
      description = ''
        Require a subdomain label in front of the proxy's domain, so resources
        cannot be created on the bare {option}`services.netbird.server.reverseProxy.domain`.
      '';
    };

    wireguardPort = mkOption {
      type = lib.types.port;
      default = 0;
      description = ''
        WireGuard listen port for the tunnel to peers (0 = random). The tunnel is
        outbound-only, so this needs no inbound firewall port. A fixed port only
        works with single-account deployments.
      '';
    };

    healthAddress = mkOption {
      type = str;
      default = "localhost:8080";
      description = "Address of the health probe endpoint (`/healthz/live`, `/healthz/ready`, `/healthz/startup`), which also serves `/metrics`.";
    };

    presharedKeyFile = mkOption {
      type = nullOr path;
      default = null;
      description = ''
        Path to a file containing a pre-shared key for the tunnel between the
        proxy and peers (set globally, not per account). The file should contain
        only the raw key value.
      '';
    };

    acme = {
      enable = mkOption {
        type = bool;
        default = true;
        description = ''
          Obtain per-resource certificates automatically through ACME. Disable to
          serve TLS from a static certificate instead
          (see {option}`services.netbird.server.reverseProxy.certificateDirectory` or
          {option}`services.netbird.server.reverseProxy.wildcardCertDir`).
        '';
      };

      challengeType = mkOption {
        type = enum [
          "tls-alpn-01"
          "http-01"
        ];
        default = "tls-alpn-01";
        description = ''
          ACME challenge type. `tls-alpn-01` uses the main TLS listener only;
          `http-01` additionally needs the plaintext
          {option}`services.netbird.server.reverseProxy.acme.address`.
        '';
      };

      address = mkOption {
        type = str;
        default = ":80";
        description = "HTTP address for ACME `http-01` challenges (only used when `acme.challengeType` is `http-01`).";
      };

      directory = mkOption {
        type = str;
        default = "https://acme-v02.api.letsencrypt.org/directory";
        description = "URL of the ACME challenge directory.";
      };

      eab = {
        kid = mkOption {
          type = str;
          default = "";
          description = "ACME External Account Binding key identifier for account registration.";
        };

        hmacKeyFile = mkOption {
          type = nullOr path;
          default = null;
          description = ''
            Path to a file containing the ACME External Account Binding HMAC key.
            The file should contain only the raw key value.
          '';
        };
      };
    };

    certificateDirectory = mkOption {
      type = str;
      default = "${stateDir}/certs";
      description = "Directory the proxy stores and reads certificates in.";
    };

    certificateFile = mkOption {
      type = str;
      default = "tls.crt";
      description = "TLS certificate filename within {option}`services.netbird.server.reverseProxy.certificateDirectory` (used when `acme.enable` is false).";
    };

    certificateKeyFile = mkOption {
      type = str;
      default = "tls.key";
      description = "TLS certificate key filename within {option}`services.netbird.server.reverseProxy.certificateDirectory` (used when `acme.enable` is false).";
    };

    certLockMethod = mkOption {
      type = enum [
        "auto"
        "flock"
        "k8s-lease"
      ];
      default = "auto";
      description = "Certificate lock method for coordinating certificate writes across replicas.";
    };

    wildcardCertDir = mkOption {
      type = str;
      default = "";
      description = ''
        Directory containing wildcard certificate pairs (`<name>.crt`/`<name>.key`);
        wildcard patterns are extracted from the certificates' SAN lists. An
        alternative to ACME for serving resources from an operator-supplied
        wildcard certificate.
      '';
    };

    geoDataDir = mkOption {
      type = str;
      default = "";
      description = ''
        Directory holding the GeoLite2 MMDB file, used for country-based access
        restrictions. Empty (the default) disables geolocation. Set to a writable
        directory to enable it; the database is auto-downloaded on first start,
        which needs outbound network access.
      '';
      example = "/var/lib/netbird-proxy/geolocation";
    };

    environment = mkOption {
      type = attrsOf (either str bool);
      default = { };
      description = ''
        Extra environment variables for the netbird-proxy service (NetBird reads
        `NB_PROXY_*` variables), for tuning knobs without a dedicated option such
        as `NB_PROXY_PREALLOCATED_BUFFERS` or `NB_PROXY_MAX_BATCH_SIZE`. Do not
        put secrets here, as they would be world-readable in the unit; use the
        dedicated secret options such as
        {option}`services.netbird.server.reverseProxy.tokenFile` instead.
      '';
    };

    extraOptions = mkOption {
      type = lib.types.listOf str;
      default = [ ];
      description = "Additional command-line options passed to the reverse proxy.";
    };

    openFirewall = mkOption {
      type = bool;
      default = false;
      description = "Whether to open the proxy's listener port in the firewall. Not needed when an L4 front reaches the proxy over loopback.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      systemd.services.netbird-proxy = {
        description = "NetBird Reverse Proxy";
        documentation = [ "https://docs.netbird.io/" ];

        # ACME issuance and (optional) GeoLite2 download need DNS/outbound
        # access, so wait for the network to be online on cold boot.
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [
          cfg.address
          cfg.managementAddress
          cfg.domain
          cfg.logLevel
          cfg.proxyProtocol
          cfg.supportsCustomPorts
        ];

        serviceConfig = {
          LoadCredential = [
            "token:${cfg.tokenFile}"
          ]
          ++ optional (cfg.presharedKeyFile != null) "preshared-key:${cfg.presharedKeyFile}"
          ++ optional (cfg.acme.eab.hmacKeyFile != null) "acme-eab-hmac-key:${cfg.acme.eab.hmacKeyFile}";

          ExecStart =
            let
              args = [
                (getExe' cfg.package "netbird-proxy")
                "--log-level"
                cfg.logLevel
                "--mgmt"
                cfg.managementAddress
                "--addr"
                cfg.address
                "--domain"
                cfg.domain
                "--cert-dir"
                cfg.certificateDirectory
                "--cert-file"
                cfg.certificateFile
                "--cert-key-file"
                cfg.certificateKeyFile
                "--cert-lock-method"
                cfg.certLockMethod
                "--forwarded-proto"
                cfg.forwardedProto
                "--health-addr"
                cfg.healthAddress
                "--geo-data-dir"
                cfg.geoDataDir
                "--supports-custom-ports=${boolToString cfg.supportsCustomPorts}"
              ]
              ++ optionals cfg.acme.enable (
                [
                  "--acme-certs"
                  "--acme-challenge-type"
                  cfg.acme.challengeType
                  "--acme-dir"
                  cfg.acme.directory
                ]
                ++ optionals (cfg.acme.challengeType == "http-01") [
                  "--acme-addr"
                  cfg.acme.address
                ]
                ++ optionals (cfg.acme.eab.kid != "") [
                  "--acme-eab-kid"
                  cfg.acme.eab.kid
                ]
              )
              ++ optionals (cfg.wildcardCertDir != "") [
                "--wildcard-cert-dir"
                cfg.wildcardCertDir
              ]
              ++ optionals (cfg.wireguardPort != 0) [
                "--wg-port"
                (toString cfg.wireguardPort)
              ]
              ++ optional cfg.proxyProtocol "--proxy-protocol"
              ++ optional cfg.requireSubdomain "--require-subdomain"
              ++ optionals (cfg.trustedProxies != "") [
                "--trusted-proxies"
                cfg.trustedProxies
              ]
              ++ cfg.extraOptions;
            in
            # The token and other secrets are read from systemd credentials at
            # runtime instead of baking them into the world-readable store or
            # unit environment; NetBird only reads them from NB_PROXY_* env vars.
            "${pkgs.writeShellScript "netbird-proxy" ''
              export NB_PROXY_TOKEN="$(< "$CREDENTIALS_DIRECTORY/token")"
              ${optionalString cfg.allowInsecure "export NB_PROXY_ALLOW_INSECURE=true"}
              ${optionalString (
                cfg.presharedKeyFile != null
              ) ''export NB_PROXY_PRESHARED_KEY="$(< "$CREDENTIALS_DIRECTORY/preshared-key")"''}
              ${optionalString (
                cfg.acme.eab.hmacKeyFile != null
              ) ''export NB_PROXY_ACME_EAB_HMAC_KEY="$(< "$CREDENTIALS_DIRECTORY/acme-eab-hmac-key")"''}
              exec ${escapeShellArgs args}
            ''}";

          Restart = "always";
          RuntimeDirectory = "netbird-proxy";
          RuntimeDirectoryMode = "0750";
          StateDirectory = "netbird-proxy";
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

          # The proxy binds the TLS listener (and, behind an L4 front, port 443)
          # but embeds a userspace-netstack client, so it needs no TUN/NET_ADMIN.
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        };

        environment = mapAttrs (
          _: value: if isBool value then boolToString value else value
        ) cfg.environment;

        stopIfChanged = false;
      };

      # The proxy authenticates to management over the ProxyService gRPC route,
      # contributed unconditionally by the management component.
    }

    # When an ingress front is selected, the proxy is reached through it: on a
    # single-IP host the front owns :443 and L4 SNI-passthroughs any otherwise
    # unmatched SNI to the proxy's own TLS listener. Mirrors NetBird's own
    # built-in-Traefik proxy passthrough (v0.74.6):
    # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L719-L727
    (mkIf fronted {
      services.netbird.server.ingressPassthrough.netbird-proxy = {
        upstream = "127.0.0.1:${listenPort}";
        proxyProtocol = cfg.proxyProtocol;
      };
    })

    (mkIf cfg.openFirewall {
      networking.firewall.allowedTCPPorts = [ (lib.toInt listenPort) ];
    })
  ]);
}
