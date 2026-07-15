{ config, lib, ... }:

let
  inherit (lib)
    attrValues
    filterAttrs
    getAttrFromPath
    intersectLists
    mapAttrs'
    mkChangedOptionModule
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optional
    optionalAttrs
    recursiveUpdate
    ;

  inherit (lib.types)
    attrTag
    attrs
    attrsOf
    bool
    nullOr
    path
    port
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

  # Traefik has no file server, so the static dashboard is served by a loopback
  # nginx and reverse-proxied by Traefik; every other route Traefik serves itself.
  staticRoutes = filterAttrs (_: route: route.backend ? static) cfg.ingressRoutes;

  # `ingress` is an optional attrTag, so guard the tag access with `?`.
  nginxEnabled = (cfg.ingress ? nginx) && cfg.ingress.nginx.enable;
  traefikEnabled = (cfg.ingress ? traefik) && cfg.ingress.traefik.enable;
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
    enable = mkEnableOption "NetBird Server stack, comprising the dashboard, management API and signal service";

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
        traefik = mkOption {
          type = submodule {
            options = {
              enable = mkEnableOption "Traefik as the ingress for the NetBird server stack";
              acme = {
                enable = mkOption {
                  type = bool;
                  default = true;
                  description = ''
                    Obtain the management-domain certificate through ACME
                    (Let's Encrypt, TLS-ALPN-01). Disable to terminate TLS with a
                    certificate you supply through
                    {option}`services.netbird.server.ingress.traefik.dynamicConfigOptions`.
                  '';
                };
                email = mkOption {
                  type = nullOr str;
                  default = null;
                  description = "Contact email for the Let's Encrypt account. Required when `acme.enable` is true.";
                };
              };
              staticListenPort = mkOption {
                type = port;
                default = 8083;
                description = ''
                  Loopback port of the internal nginx that serves the static
                  dashboard. Traefik has no file server, so it proxies its `/`
                  route to this address.
                '';
              };
              staticConfigOptions = mkOption {
                type = attrs;
                default = { };
                description = ''
                  Extra Traefik static configuration merged onto the generated
                  one (entry points, certificate resolvers, ...). See
                  {option}`services.traefik.staticConfigOptions`.
                '';
              };
              dynamicConfigOptions = mkOption {
                type = attrs;
                default = { };
                description = ''
                  Extra Traefik dynamic configuration merged onto the generated
                  routers and services (TLS certificates and stores, middlewares,
                  ...). See {option}`services.traefik.dynamicConfigOptions`.
                '';
              };
            };
          };
          default = { };
          description = ''
            Serve the NetBird server stack behind Traefik: L7-terminate the
            management domain (dashboard, API + gRPC, signal, relay) and, for the
            NetBird reverse proxy, L4 SNI-passthrough every other SNI. Mirrors
            NetBird's own built-in-Traefik topology.

            Enable it with
            `services.netbird.server.ingress.traefik.enable = true`. A loopback
            nginx serves the static dashboard (Traefik has no file server).
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

    ingressPassthrough = mkOption {
      internal = true;
      visible = false;
      default = { };
      type = attrsOf (submodule {
        options = {
          sni = mkOption {
            type = str;
            default = "*";
            description = "SNI matched for L4 TLS passthrough (Traefik `HostSNI`); `*` catches every otherwise-unmatched SNI.";
          };
          upstream = mkOption {
            type = str;
            description = "`host:port` of the TLS backend the raw stream is forwarded to.";
          };
          proxyProtocol = mkOption {
            type = bool;
            default = true;
            description = "Wrap the forwarded stream in PROXY protocol v2 so the backend sees the real client IP.";
          };
        };
      });
      description = ''
        Internal seam: L4 SNI-passthrough routes contributed by the server
        components (the NetBird reverse proxy). Only the
        {option}`services.netbird.server.ingress.traefik` backend can serve
        these; nginx cannot do TLS passthrough.
      '';
    };

    domain = mkOption {
      type = str;
      description = "The domain under which the NetBird server runs.";
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
        {
          assertion = cfg.ingressPassthrough == { } || traefikEnabled;
          message = ''
            services.netbird.server.ingressPassthrough is set but the Traefik
            ingress backend is not enabled. L4 SNI passthrough (for the NetBird
            reverse proxy) requires services.netbird.server.ingress.traefik.enable;
            nginx cannot forward TLS without terminating it.
          '';
        }
        {
          assertion =
            !traefikEnabled || !cfg.ingress.traefik.acme.enable || cfg.ingress.traefik.acme.email != null;
          message = "services.netbird.server.ingress.traefik.acme.email is required when services.netbird.server.ingress.traefik.acme.enable is true.";
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

    services.nginx = mkMerge [
      # nginx as the ingress (serves every route directly).
      (mkIf nginxEnabled {
        enable = true;

        virtualHosts.${cfg.domain} = mkMerge [
          cfg.ingress.nginx.settings
          { locations = nginxLocations; }
        ];
      })
      # Traefik backend: a loopback-only nginx that serves just the static
      # routes (Traefik has no file server); Traefik reverse-proxies "/" here.
      (mkIf traefikEnabled {
        enable = true;

        virtualHosts."netbird-static" = {
          listen = [
            {
              addr = "127.0.0.1";
              port = cfg.ingress.traefik.staticListenPort;
            }
          ];
          locations = mkMerge (map renderNginxRoute (attrValues staticRoutes));
        };
      })
    ];

    # The Traefik config below mirrors NetBird's own built-in-Traefik setup
    # (netbird v0.74.6, infrastructure_files/getting-started.sh:
    # render_docker_compose_traefik_builtin + render_traefik_dynamic). NetBird
    # runs the COMBINED binary (one netbird-server:80, h2c for gRPC); this module
    # runs the STANDALONE components on separate loopback ports, so routers are
    # per-component here. Per-block upstream permalinks are inline below.
    services.traefik = mkIf traefikEnabled (
      let
        tcfg = cfg.ingress.traefik;
        acmeEnabled = tcfg.acme.enable;
        staticUpstream = "127.0.0.1:${toString tcfg.staticListenPort}";

        # Terminated routers use the ACME resolver, or Traefik's default
        # certificate (supply one through
        # ingress.traefik.dynamicConfigOptions.tls when acme.enable = false).
        routerTls = if acmeEnabled then { certResolver = "letsencrypt"; } else { };

        # gRPC needs an h2c (cleartext HTTP/2) upstream; the rest are plain http.
        # The static dashboard route is proxied to the loopback nginx.
        upstreamUrl =
          route:
          let
            b = route.backend;
          in
          if b ? grpc then
            "h2c://${b.grpc.upstream}"
          else if b ? proxy then
            "http://${b.proxy.upstream}"
          else if b ? websocket then
            "http://${b.websocket.upstream}"
          else if b ? static then
            "http://${staticUpstream}"
          else
            throw "netbird ingressRoutes: no backend selected for route '${route.path}'";

        # One http router + service per L7 route. Mirrors NetBird's router rules:
        # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L826-L871
        httpRouters = mapAttrs' (
          name: route:
          nameValuePair "netbird-${name}" {
            # The dashboard is the Host-only catch-all (NetBird: priority 1); the
            # path-specific routes must outrank it.
            rule =
              if route.backend ? static then
                "Host(`${cfg.domain}`)"
              else
                "Host(`${cfg.domain}`) && PathPrefix(`${route.path}`)";
            service = "netbird-${name}";
            entryPoints = [ "websecure" ];
            tls = routerTls;
            priority = if route.backend ? static then 1 else 100;
          }
        ) cfg.ingressRoutes;

        httpServices = mapAttrs' (
          name: route:
          nameValuePair "netbird-${name}" {
            loadBalancer.servers = [ { url = upstreamUrl route; } ];
          }
        ) cfg.ingressRoutes;

        hasPassthrough = cfg.ingressPassthrough != { };

        # L4 SNI passthrough: raw TLS forwarded on any unmatched SNI (the mgmt
        # domain is L7-terminated above). Mirrors NetBird's proxy-passthrough:
        # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L719-L727
        tcpRouters = mapAttrs' (
          name: p:
          nameValuePair "netbird-${name}" {
            rule = "HostSNI(`${p.sni}`)";
            entryPoints = [ "websecure" ];
            tls.passthrough = true;
            # Lowest priority: lose to the specific-SNI (mgmt domain) routers.
            priority = 1;
            service = "netbird-${name}";
          }
        ) cfg.ingressPassthrough;

        tcpServices = mapAttrs' (
          name: p:
          nameValuePair "netbird-${name}" {
            loadBalancer = {
              servers = [ { address = p.upstream; } ];
            }
            // optionalAttrs p.proxyProtocol { serversTransport = "pp-v2"; };
          }
        ) cfg.ingressPassthrough;

        traefikDynamic = recursiveUpdate (
          {
            http = {
              routers = httpRouters;
              services = httpServices;
            };
          }
          # PROXY-protocol v2 preserves client IPs across the L4 hop. Mirrors
          # NetBird's render_traefik_dynamic:
          # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L962-L971
          // optionalAttrs hasPassthrough {
            tcp = {
              routers = tcpRouters;
              services = tcpServices;
              serversTransports.pp-v2.proxyProtocol.version = 2;
            };
          }
        ) tcfg.dynamicConfigOptions;

        # Entry points + ACME, mirroring NetBird's built-in-Traefik command flags:
        # https://github.com/netbirdio/netbird/blob/v0.74.6/infrastructure_files/getting-started.sh#L785-L802
        traefikStatic = recursiveUpdate (
          {
            global = {
              checkNewVersion = false;
              sendAnonymousUsage = false;
            };
            entryPoints = {
              web = {
                address = ":80";
                http.redirections.entryPoint = {
                  to = "websecure";
                  scheme = "https";
                };
              };
              websecure = {
                address = ":443";
                asDefault = true;
                # Let the proxy's *.<domain> ACME TLS-ALPN-01 challenges reach the
                # HostSNI(*) passthrough instead of Traefik's own resolver.
                allowACMEByPass = true;
                # Zero timeouts keep long-lived gRPC streams from being closed.
                transport.respondingTimeouts = {
                  readTimeout = 0;
                  writeTimeout = 0;
                  idleTimeout = 0;
                };
              };
            };
          }
          // optionalAttrs acmeEnabled {
            certificatesResolvers.letsencrypt.acme = {
              email = tcfg.acme.email;
              storage = "${config.services.traefik.dataDir}/acme.json";
              tlsChallenge = { };
            };
          }
        ) tcfg.staticConfigOptions;
      in
      {
        enable = true;
        staticConfigOptions = traefikStatic;
        dynamicConfigOptions = traefikDynamic;
      }
    );
  };
}
