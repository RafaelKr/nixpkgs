# NetBird server {#module-services-netbird-server}

NetBird is a VPN built on top of WireGuard® making it easy to create secure private networks for your organization or home.

## Quickstart {#module-services-netbird-server-quickstart}

To fully setup NetBird as a self-hosted server, you need an identity provider (or use the embedded IDP) and either a Coturn server or the modern relay server. The list of supported SSOs and their setup are available [on NetBird's documentation](https://docs.netbird.io/selfhosted/selfhosted-guide#step-3-configure-identity-provider-idp).

### Minimal Configuration with Coturn {#module-services-netbird-server-quickstart-coturn}

This is the traditional setup using Coturn as the TURN server:

```nix
{
  services.netbird.server = {
    enable = true;

    domain = "netbird.example.selfhosted";

    ingress.nginx.enable = true;

    coturn = {
      enable = true;
      passwordFile = "/path/to/a/secret/password";
    };

    management = {
      oidcConfigEndpoint = "https://sso.example.selfhosted/oauth2/openid/netbird/.well-known/openid-configuration";

      settings = {
        TURNConfig = {
          Turns = [
            {
              Proto = "udp";
              URI = "turn:netbird.example.selfhosted:3478";
              Username = "netbird";
              Password._secret = "/path/to/a/secret/password";
            }
          ];
        };
      };
    };
  };
}
```

### Modern Setup with Relay Server {#module-services-netbird-server-quickstart-relay}

NetBird v0.28+ introduced a modern relay server that replaces Coturn with better performance and simpler configuration. The relay server includes an embedded STUN server.

```nix
{
  services.netbird.server = {
    enable = true;

    domain = "netbird.example.selfhosted";

    ingress.nginx.enable = true;

    # Use the modern relay instead of Coturn
    relay.enable = true;
    relay.authSecretFile = "/run/secrets/relay-auth";

    management = {
      oidcConfigEndpoint = "https://sso.example.selfhosted/oauth2/openid/netbird/.well-known/openid-configuration";
    };
  };
}
```

## Global settings {#module-services-netbird-server-global}

`enable` turns on the dashboard, management API and signal service; the relay and coturn are enabled separately.
`domain` names the host the server is reached at, and every component derives its own defaults from it.

```nix
{
  services.netbird.server = {
    enable = true;
    domain = "netbird.example.selfhosted";
  };
}
```

## The ingress {#module-services-netbird-server-ingress}

The ingress terminates TLS for `domain` and routes each plane — dashboard, management API and gRPC, signal, relay — to the component that serves it.
NetBird's own documentation calls this the [external reverse proxy](https://docs.netbird.io/selfhosted/external-reverse-proxy).
It is not to be confused with the [NetBird Reverse Proxy](#module-services-netbird-server-reverse-proxy) component, which publishes your own applications over the mesh.

`ingress` is a tagged union, so exactly one backend is selected.
Enable it and configure the virtual host through the backend's own `settings`:

```nix
{
  services.netbird.server.ingress.nginx = {
    enable = true;
    settings = {
      enableACME = true;
      forceSSL = true;
    };
  };
}
```

Leave `ingress` unset to run the components without a bundled front, for example when something else on the network already terminates TLS and forwards to them.

## Components {#module-services-netbird-server-components}

The sections below configure the individual NetBird components.

### Relay vs Coturn {#module-services-netbird-server-relay-vs-coturn}

| Feature | Relay Server | Coturn |
|---------|--------------|--------|
| Protocol | WebSocket/HTTP(S) | TURN (UDP/TCP) |
| Firewall | Single port (443) | Multiple ports + UDP range |
| Setup | Simple | More complex |
| Embedded STUN | Yes | No (separate config) |
| Performance | Optimized for NetBird | General-purpose |

**Recommendation:** Use the relay server for new deployments. Only use Coturn if you have specific requirements for standard TURN protocol compatibility.

### Embedded Identity Provider {#module-services-netbird-server-embedded-idp}

NetBird supports an embedded identity provider for simplified deployments that don't require an external SSO. Enable it with `idp.embedded.enable = true`, then customize via the freeform `settings` option:

```nix
{
  services.netbird.server.management = {
    enable = true;
    domain = "netbird.example.com";
    turnDomain = "netbird.example.com";

    idp.embedded.enable = true;

    settings = {
      EmbeddedIdP = {
        Owner = {
          Email = "admin@example.com";
          Username = "admin";
          # Generate with: mkpasswd -m bcrypt -R 10   (type the password when prompted)
          Hash._secret = "/run/secrets/admin-password-hash";
        };
      };
    };
  };
}
```

### Database Backends {#module-services-netbird-server-database}

By default, the management server uses SQLite. For larger deployments, set `store.engine` to `postgres` or `mysql` and point `store.dsnFile` at the connection DSN; the DSN is passed to netbird-mgmt as a systemd credential and never written to the Nix store.

#### PostgreSQL {#module-services-netbird-server-database-postgres}

```nix
{
  services.netbird.server.management = {
    store = {
      engine = "postgres";
      dsnFile = "/run/secrets/postgres-dsn";
    };
  };

  # Example DSN file content:
  # host=localhost user=netbird dbname=netbird

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "netbird" ];
    ensureUsers = [
      {
        name = "netbird";
        ensureDBOwnership = true;
      }
    ];
  };
}
```

#### MySQL {#module-services-netbird-server-database-mysql}

```nix
{
  services.netbird.server.management = {
    store = {
      engine = "mysql";
      dsnFile = "/run/secrets/mysql-dsn";
    };
  };

  # Example DSN file content:
  # netbird:password@tcp(localhost:3306)/netbird
}
```

### Relay Server Configuration {#module-services-netbird-server-relay-config}

The relay server can be configured independently. Advanced TLS settings (Let's Encrypt, custom certificates) can be passed via `extraOptions`:

```nix
{
  services.netbird.server.relay = {
    enable = true;
    exposedAddress = "rels://relay.example.com:443";
    authSecretFile = "/run/secrets/relay-auth";

    stun = {
      enable = true;
      ports = [ 3478 ];
    };

    openFirewall = true;

    # For direct TLS (without an nginx ingress):
    extraOptions = [
      "--tls-cert-file"
      "/path/to/cert.pem"
      "--tls-key-file"
      "/path/to/key.pem"
    ];
  };
}
```

### NetBird Reverse Proxy {#module-services-netbird-server-reverse-proxy}

The NetBird reverse proxy (`server.reverseProxy`) exposes NetBird network resources over the public internet. It terminates TLS on its own listener and forwards traffic to backends over the WireGuard tunnel, so resources are reached at `<subdomain>.<proxy-domain>` — the operator must create a wildcard DNS record `*.<proxy-domain>` pointing at the host.

On a single-IP host the ingress front already owns `:443`, so the proxy listens on `:8443` and is reached through the [Traefik backend](#opt-services.netbird.server.ingress.traefik.enable), which L4 SNI-passthroughs any otherwise-unmatched SNI to it (nginx cannot forward TLS, so the proxy requires the Traefik backend there). Enabling `server.reverseProxy` without an ingress leaves the proxy owning its port directly, for a dedicated host.

The proxy authenticates to management with an access token minted out-of-band (`netbird-mgmt token create` or the reverse-proxy REST API) and provided through `reverseProxy.tokenFile`.

```nix
{ config, ... }:

{
  services.netbird.server = {
    enable = true;
    domain = "netbird.example.com";

    ingress.traefik = {
      enable = true;
      acme.email = "admin@example.com";
    };

    reverseProxy = {
      enable = true;
      domain = "proxy.netbird.example.com";
      tokenFile = "/run/secrets/netbird/proxy-token";

      # Recover the real client IP across the Traefik L4 passthrough.
      proxyProtocol = true;
      trustedProxies = "127.0.0.1/32";
    };
  };

  # When the proxy runs on the same host as management, dialing the public
  # management domain hairpins out to the public IP and back; a loopback
  # override reaches the local Traefik front directly (the certificate still
  # validates because the SNI matches the domain).
  networking.hosts."127.0.0.1" = [ config.services.netbird.server.domain ];
}
```

## Complete Self-Hosted Example {#module-services-netbird-server-complete-example}

Here's a complete example using the modern relay server with an external identity provider:

```nix
{ config, ... }:

{
  services.netbird.server = {
    enable = true;
    domain = "netbird.example.com";

    ingress.nginx = {
      enable = true;
      settings = {
        enableACME = true;
        forceSSL = true;
      };
    };

    relay.enable = true;
    relay.authSecretFile = "/run/secrets/netbird/relay-auth";

    management = {
      oidcConfigEndpoint = "https://auth.example.com/.well-known/openid-configuration";

      settings = {
        DataStoreEncryptionKey._secret = "/run/secrets/netbird/encryption-key";
      };
    };

    dashboard.settings = {
      AUTH_AUTHORITY = "https://auth.example.com";
      AUTH_CLIENT_ID = "netbird-dashboard";
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };

  # Open firewall for STUN (relay handles the rest via nginx)
  networking.firewall.allowedUDPPorts = [ 3478 ];
}
```
