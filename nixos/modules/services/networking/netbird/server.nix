{ config, lib, ... }:

let
  inherit (lib)
    attrValues
    getAttrFromPath
    intersectLists
    mkChangedOptionModule
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    optionalAttrs
    ;

  inherit (lib.types)
    attrTag
    attrsOf
    nullOr
    path
    str
    submodule
    ;

  cfg = config.services.netbird.server;

  # The ingress routes below mirror NetBird's own self-hosted routing.
  # Upstream references (netbird v0.74.6):
  #   - route set (built-in Traefik router rules):
  #     https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L826-L871
  #   - nginx directives (grpc_pass / ws upgrade / long-lived-stream timeouts):
  #     https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/nginx.tmpl.conf
  # NetBird's own setup runs the COMBINED binary (one netbird-server:80, h2c for
  # gRPC); this module runs the STANDALONE components on separate loopback ports,
  # so the routes are keyed per-component here rather than grouped by container.
  # Re-check the links above when syncing a NetBird routing change.
  #
  # Render a backend-agnostic ingress route (contributed by the server
  # components) into an nginx `locations` fragment.
  grpcExtraConfig = upstream: ''
    # gRPC proxying, mirroring NetBird's nginx template location blocks:
    # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/nginx.tmpl.conf#L68-L74
    # Keep long-lived gRPC streams from being closed early.
    # See https://stackoverflow.com/a/67805465
    client_body_timeout 1d;

    grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    grpc_pass grpc://${upstream};
    grpc_read_timeout 1d;
    grpc_send_timeout 1d;
    grpc_socket_keepalive on;
  '';

  websocketExtraConfig = upstream: ''
    # WebSocket proxying (relay + ws-proxy), mirroring NetBird's nginx template:
    # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/nginx.tmpl.conf#L96-L102
    proxy_pass http://${upstream};
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 86400;
  '';

  # Backends that reverse-proxy to an upstream share a single `host:port` option.
  upstreamBackend = {
    options.upstream = mkOption {
      type = str;
      description = "`host:port` of the backend this route proxies to.";
    };
  };

  renderNginxRoute =
    route:
    let
      backend = route.backend;
    in
    if backend ? static then
      # The dashboard is a static Next.js export: serve per-route .html and
      # fall back to the exported 404.html app shell (matches the upstream
      # NetBird dashboard container). Root is set per-location to avoid
      # clashing with the user's ingress.nginx vhost scalars.
      {
        ${route.path} = {
          root = backend.static.root;
          tryFiles = "$uri $uri.html $uri/ =404";
          extraConfig = "error_page 404 /404.html;";
        };
        "= /404.html" = {
          root = backend.static.root;
          extraConfig = "internal;";
        };
      }
    else if backend ? grpc then
      { ${route.path}.extraConfig = grpcExtraConfig backend.grpc.upstream; }
    else if backend ? websocket then
      { ${route.path}.extraConfig = websocketExtraConfig backend.websocket.upstream; }
    else if backend ? proxy then
      { ${route.path}.proxyPass = "http://${backend.proxy.upstream}"; }
    else
      throw "netbird ingressRoutes: no backend selected for route '${route.path}'";

  nginxLocations = mkMerge (map renderNginxRoute (attrValues cfg.ingressRoutes));
in

{
  meta = {
    maintainers = with lib.maintainers; [ RafaelKr ];
    doc = ./server.md;
  };

  # Import the separate components
  imports = [
    ./coturn.nix
    ./dashboard.nix
    ./management.nix
    ./relay.nix
    ./signal.nix
  ]
  # Backward compat: the released `enableNginx` booleans (server-level and
  # per-component) now select the nginx `ingress` backend.
  ++
    map
      (
        oldPath:
        mkChangedOptionModule oldPath [ "services" "netbird" "server" "ingress" ] (
          config: mkIf (getAttrFromPath oldPath config) { nginx.enable = true; }
        )
      )
      [
        [
          "services"
          "netbird"
          "server"
          "enableNginx"
        ]
        [
          "services"
          "netbird"
          "server"
          "dashboard"
          "enableNginx"
        ]
        [
          "services"
          "netbird"
          "server"
          "management"
          "enableNginx"
        ]
        [
          "services"
          "netbird"
          "server"
          "signal"
          "enableNginx"
        ]
      ];

  options.services.netbird.server = {
    enable = mkEnableOption "Netbird Server stack, comprising the dashboard, management API and signal service";

    ingress = mkOption {
      type = nullOr (attrTag {
        nginx = mkOption {
          type = submodule {
            options = {
              enable = mkEnableOption "Nginx as the ingress for the NetBird server stack";
              settings = mkOption {
                type = submodule (import ../../web-servers/nginx/vhost-options.nix);
                default = { };
                description = ''
                  nginx virtual-host configuration (see
                  {option}`services.nginx.virtualHosts.<name>`) merged onto the
                  locations the module generates for the dashboard, management
                  API + gRPC, signal and relay. Configure TLS here, e.g.
                  `{ enableACME = true; forceSSL = true; }`.
                '';
              };
            };
          };
          default = { };
          description = ''
            Serve the NetBird server stack behind an nginx ingress.

            Enable it with
            `services.netbird.server.ingress.nginx.enable = true` and
            configure the virtual host through
            {option}`services.netbird.server.ingress.nginx.settings`.
          '';
        };
      });
      default = null;
      description = ''
        The ingress that serves the NetBird server stack.

        Select and enable a backend, e.g.
        `services.netbird.server.ingress.nginx.enable = true`. Leave unset to
        run the services without a bundled ingress.
      '';
    };

    ingressRoutes = mkOption {
      internal = true;
      visible = false;
      default = { };
      type = attrsOf (
        submodule (
          { name, ... }:
          {
            options = {
              path = mkOption {
                type = str;
                default = name;
                description = "Request path served by this route.";
              };
              backend = mkOption {
                type = attrTag {
                  static = mkOption {
                    type = submodule {
                      options.root = mkOption {
                        type = path;
                        description = "Filesystem root served for this route.";
                      };
                    };
                    description = "Serve a static filesystem tree.";
                  };
                  proxy = mkOption {
                    type = submodule upstreamBackend;
                    description = "HTTP reverse proxy to an upstream.";
                  };
                  grpc = mkOption {
                    type = submodule upstreamBackend;
                    description = "gRPC reverse proxy to an upstream.";
                  };
                  websocket = mkOption {
                    type = submodule upstreamBackend;
                    description = "WebSocket reverse proxy to an upstream.";
                  };
                };
                description = "How the selected ingress serves this route (exactly one backend).";
              };
            };
          }
        )
      );
      description = ''
        Internal seam: ingress routes contributed by the server
        components (dashboard, management, signal, relay) and rendered into
        the selected {option}`services.netbird.server.ingress` backend.
      '';
    };

    domain = mkOption {
      type = str;
      description = "The domain under which the netbird server runs.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      let
        # The relay's embedded STUN and coturn both default to UDP 3478, so their
        # STUN listeners collide when both run on one host. coturn additionally
        # binds alt-listening-port (listening-port + 1) for RFC 5780 NAT-behaviour
        # discovery.
        coturnUdpPorts = with config.services.coturn; [
          listening-port
          alt-listening-port
        ];
        collidingStunPorts = intersectLists cfg.relay.stun.ports coturnUdpPorts;
        stunCoturnCollision =
          cfg.relay.enable && cfg.relay.stun.enable && cfg.coturn.enable && collidingStunPorts != [ ];
      in
      [
        {
          assertion = !stunCoturnCollision;
          message = ''
            services.netbird.server: the relay's embedded STUN server and coturn both bind
            UDP ${toString collidingStunPorts} on this host. Resolve the collision with one of:
              - services.netbird.server.relay.stun.enable = false;  # keep only coturn's STUN
              - services.netbird.server.relay.stun.ports = [ <free-udp-port> ];
              - services.coturn.listening-port = <free-udp-port>;
          '';
        }
      ];

    warnings =
      let
        # By default management advertises stun:${turnDomain}:3478 pointing at this
        # host. A delegated turnDomain or an emptied settings.Stuns means STUN is
        # not meant to be served locally, so a missing local STUN listener is not a
        # misconfiguration.
        advertisesLocalStun =
          cfg.management.turnDomain == cfg.domain && (cfg.management.settings.Stuns or null) != [ ];
        danglingStunAdvertisement =
          cfg.relay.enable && !cfg.relay.stun.enable && !cfg.coturn.enable && advertisesLocalStun;
      in
      optional danglingStunAdvertisement "services.netbird.server: the management server advertises a STUN endpoint (stun:${cfg.management.turnDomain}:3478) but no local STUN server is enabled (relay.stun and coturn are both off). Enable services.netbird.server.relay.stun, enable coturn, or point management.turnDomain at a host that answers STUN.";

    services.netbird.server = {
      dashboard = {
        domain = mkDefault cfg.domain;
        enable = mkDefault cfg.enable;

        managementServer = mkDefault "https://${cfg.domain}";
      };

      management = {
        domain = mkDefault cfg.domain;
        enable = mkDefault cfg.enable;
        # When using relay without coturn, turnDomain still needs a value.
        # Default to the server domain so the management config evaluates.
        turnDomain = mkDefault cfg.domain;
      }
      // (optionalAttrs cfg.coturn.enable rec {
        turnDomain = cfg.domain;
        turnPort = config.services.coturn.listening-port;
        # We cannot merge a list of attrsets so we have to redefine the whole list
        settings = {
          TURNConfig.Turns = mkDefault [
            {
              Proto = "udp";
              URI = "turn:${turnDomain}:${toString turnPort}";
              Username = "netbird";
              Password =
                if (cfg.coturn.password != null) then
                  cfg.coturn.password
                else
                  { _secret = cfg.coturn.passwordFile; };
            }
          ];
        };
      })
      // (optionalAttrs cfg.relay.enable {
        relayAddresses = mkDefault [ "rels://${cfg.domain}:443" ];
        relaySecretFile = mkDefault cfg.relay.authSecretFile;
      });

      signal = {
        domain = mkDefault cfg.domain;
        enable = mkDefault cfg.enable;
      };

      relay = mkIf cfg.relay.enable {
        exposedAddress = mkDefault "rels://${cfg.domain}:443";
      };

      coturn = {
        domain = mkDefault cfg.domain;
      };
    };

    services.nginx = mkIf ((cfg.ingress ? nginx) && cfg.ingress.nginx.enable) {
      enable = true;

      virtualHosts.${cfg.domain} = mkMerge [
        cfg.ingress.nginx.settings
        { locations = nginxLocations; }
      ];
    };
  };
}
