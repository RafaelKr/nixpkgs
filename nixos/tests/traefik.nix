# verifies:
#   1. routing.settings routes are rendered into the generated routing file and
#      served by the file provider.
#   2. proxying to a local web service and a Docker container.
{ lib, ... }:
{
  name = "traefik";
  meta = with lib.maintainers; {
    maintainers = [
      joko
      jackr
    ];
  };

  nodes = {
    client =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl ];
      };
    traefik =
      { pkgs, ... }:
      {
        virtualisation.oci-containers = {
          backend = "docker";
          containers.nginx = {
            labels = {
              "traefik.enable" = "true";
              "traefik.http.routers.nginx.entrypoints" = "web";
              "traefik.http.routers.nginx.rule" = "Host(`nginx.traefik.test`)";
            };
            image = "nginx-container";
            imageStream = pkgs.dockerTools.examples.nginxStream;
          };
        };

        networking.firewall.allowedTCPPorts = [ 80 ];

        services.traefik = {
          enable = true;
          supplementaryGroups = [ "docker" ];

          routing.settings = {
            http.routers.simplehttp = {
              rule = "Host(`simplehttp.traefik.test`)";
              entryPoints = [ "web" ];
              service = "simplehttp";
            };

            http.services.simplehttp = {
              loadBalancer.servers = [
                {
                  url = "http://127.0.0.1:8000";
                }
              ];
            };
          };

          routing.provider.file.path = "/etc/traefik/routing.yml";

          install.settings = {
            global = {
              checkNewVersion = false;
              sendAnonymousUsage = false;
            };

            entryPoints.web.address = ":80";

            providers.docker.exposedByDefault = false;
          };
        };

        systemd.services.simplehttp = {
          script = "${pkgs.python3}/bin/python -m http.server 8000";
          serviceConfig.Type = "simple";
          wantedBy = [ "multi-user.target" ];
        };
      };
  };

  testScript = ''
    start_all()

    traefik.wait_for_unit("docker-nginx.service")
    traefik.wait_until_succeeds("docker ps | grep nginx-container")
    traefik.wait_for_unit("simplehttp.service")
    traefik.wait_for_unit("traefik.service")
    traefik.wait_for_open_port(80)
    traefik.wait_for_unit("multi-user.target")

    client.wait_for_unit("multi-user.target")

    client.wait_until_succeeds("curl -sSf -H Host:nginx.traefik.test http://traefik/")

    with subtest("Check that a container can be reached via Traefik"):
        assert "Hello from NGINX" in client.succeed(
            "curl -sSf -H Host:nginx.traefik.test http://traefik/"
        )

    with subtest("Check that routing configuration works"):
        # READY does not mean routes are loaded: the file provider loads them
        # in a background goroutine. timeout=60 absorbs load variance.
        assert "Directory listing for " in client.wait_until_succeeds(
            "curl -sSf -H Host:simplehttp.traefik.test http://traefik/", timeout=60
        )
  '';
}
