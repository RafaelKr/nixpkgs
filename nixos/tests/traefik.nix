# verifies:
#   1. file-mode and directory-mode routing config generation, including
#      per-entry routing.files merging.
#   2. proxying to an HTTP backend on another machine and to a Docker container.
{ lib, ... }:
{
  name = "traefik";
  meta = with lib.maintainers; {
    maintainers = [
      joko
      jackr
    ];
  };

  # Debugging: inspect a container's evaluated config in `nix repl` via
  # `nixosTests.traefik.containers.<name>` (under `legacyPackages.<system>`).

  # Both nodes and containers are declared, which would auto-enable devnet; force it off since
  # that feature is not available on nixpkgs infrastructure.
  requiredFeatures.devnet = lib.mkForce false;

  # Shared install configuration for every Traefik node.
  defaults = {
    services.traefik.install.settings = {
      global = {
        checkNewVersion = false;
        sendAnonymousUsage = false;
      };

      entryPoints."web".address = ":80";
    };

    networking.firewall.allowedTCPPorts = [ 80 ];
  };

  containers = {
    # Emulates a request arriving over the network rather than through localhost.
    client =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl ];
      };

    # Reusable HTTP backend the routing nodes proxy to.
    simplehttp =
      { pkgs, ... }:
      {
        systemd.services.simplehttp = {
          script = "${pkgs.python3}/bin/python -m http.server 80";
          serviceConfig.Type = "simple";
          wantedBy = [ "multi-user.target" ];
        };
      };

    # File mode (content-sensing default): routing.settings and every routing.files entry are
    # merged into the single generated file linked at /etc/traefik/routing.yml.
    declare = {
      services.traefik = {
        enable = true;
        routing = {
          settings = {
            http.routers."declarativehttp" = {
              rule = "Host(`declarativehttp.declare`)";
              entryPoints = [ "web" ];
              service = "declarativehttp";
            };

            http.services."declarativehttp".loadBalancer.servers = [
              { url = "http://simplehttp"; }
            ];
          };

          files."extradeclare".settings = {
            http.routers."extradeclarehttp" = {
              rule = "Host(`extradeclarehttp.declare`)";
              entryPoints = [ "web" ];
              service = "extradeclarehttp";
            };

            http.services."extradeclarehttp".loadBalancer.servers = [
              { url = "http://simplehttp"; }
            ];
          };
        };
      };
    };

    # Directory mode: routing.settings lands as _nixos-settings.yml and each routing.files entry
    # as its own _nixos-extra-<name>.yml, loaded without overwriting each other.
    extra = {
      services.traefik = {
        enable = true;

        routing = {
          settings.http = {
            routers."settingshttp" = {
              rule = "Host(`settingshttp.extra`)";
              entryPoints = [ "web" ];
              service = "settingshttp";
            };
            services."settingshttp".loadBalancer.servers = [
              { url = "http://simplehttp"; }
            ];
          };

          provider.directory.path = "/etc/traefik/routing";

          files."extrahttp1".settings = {
            http.routers."extrahttp1" = {
              rule = "Host(`extrahttp1.extra`)";
              entryPoints = [ "web" ];
              service = "extrahttp1";
            };

            http.services."extrahttp1".loadBalancer.servers = [
              { url = "http://simplehttp"; }
            ];
          };

          files."extrahttp2".settings = {
            http.routers."extrahttp2" = {
              rule = "Host(`extrahttp2.extra`)";
              entryPoints = [ "web" ];
              service = "extrahttp2";
            };

            http.services."extrahttp2".loadBalancer.servers = [
              { url = "http://simplehttp"; }
            ];
          };
        };
      };
    };
  };

  # Docker provider: a full VM (not an nspawn container) because it runs the Docker daemon.
  # Container labels are parsed by Traefik and networking to the daemon works.
  nodes.docker =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.curl ];

      services.traefik = {
        enable = true;
        supplementaryGroups = [ "docker" ];
        # Do not auto-create routers from image EXPOSE directives.
        install.settings.providers.docker.exposedByDefault = false;
      };

      virtualisation.oci-containers = {
        backend = "docker";
        containers.nginx = {
          labels = {
            "traefik.enable" = "true";
            "traefik.http.routers.nginx.entrypoints" = "web";
            "traefik.http.routers.nginx.rule" = "Host(`nginx.docker`)";
          };
          image = "nginx-container";
          imageStream = pkgs.dockerTools.examples.nginxStream;
        };
      };
    };

  testScript = ''
    def assert_routed(host, node):
        # traefik.service is Type=notify: the unit turns active when the daemon
        # sends READY=1, which happens before the file provider has loaded the
        # routes in its background goroutine. timeout=60 absorbs load variance.
        body = client.wait_until_succeeds(f"curl -sSf -H Host:{host} http://{node.name}/", timeout=60)
        assert "Directory listing for " in body, body

    start_all()

    client.wait_for_unit("multi-user.target")
    simplehttp.wait_for_unit("simplehttp.service")
    simplehttp.wait_for_open_port(80)

    declare.wait_for_unit("traefik.service")
    declare.wait_for_open_port(80)

    extra.wait_for_unit("traefik.service")
    extra.wait_for_open_port(80)

    docker.wait_for_unit("traefik.service")
    docker.wait_for_open_port(80)
    docker.wait_for_unit("docker-nginx.service")
    docker.wait_until_succeeds("docker ps | grep nginx-container")

    with subtest("Serve routing.settings from the single generated file"):
        assert_routed("declarativehttp.declare", declare)

    with subtest("Merge a routing.files entry into the single generated file and serve it"):
        assert_routed("extradeclarehttp.declare", declare)

    with subtest("Serve the first directory-mode routing.files entry"):
        assert_routed("extrahttp1.extra", extra)

    with subtest("Serve the second directory-mode routing.files entry (no overwrite)"):
        assert_routed("extrahttp2.extra", extra)

    with subtest("Serve routing.settings written into the directory"):
        assert_routed("settingshttp.extra", extra)

    with subtest("Reach a Docker container via Traefik"):
        # The docker provider discovers container labels asynchronously after
        # READY; timeout=60 absorbs that.
        assert "Hello from NGINX" in docker.wait_until_succeeds(
            "curl -sSf -H Host:nginx.docker http://127.0.0.1/",
            timeout=60,
        )
  '';
}
