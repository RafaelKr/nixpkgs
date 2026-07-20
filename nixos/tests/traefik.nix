# verifies:
#   1. file-mode and directory-mode routing config generation, including
#      per-entry routing.files merging.
#   2. the generated --configfile content (install.settings, the injected
#      providers.file block, plugin registration).
#   3. 1:1 structural rendering of Traefik v3.7 docs examples.
#   4. proxying to an HTTP backend on another machine and to a Docker container.
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

  # PyYAML lets the docs subtests compare our generated (JSON) config files against
  # Traefik's own documentation examples (YAML) by structure, independent of key order.
  extraPythonPackages = p: [ p.pyyaml ];

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

    # File mode (content-sensing default) with an explicit non-default path: routing.settings and
    # every routing.files entry are merged into the single generated file linked at
    # /etc/traefik/custom-routes.yml, which providers.file.filename must follow.
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

          provider.file.path = "/etc/traefik/custom-routes.yml";

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

    # Install config generation: the generated --configfile must incorporate install.settings, the
    # providers.file injected from routing.provider, and experimental.localPlugins (moduleName from
    # the package plus freeform per-plugin settings). The stub plugin is only a placeholder
    # package, so nothing is loaded at runtime; the subtest reads only the generated file,
    # built at eval time.
    config =
      { pkgs, ... }:
      {
        services.traefik = {
          enable = true;
          localPlugins = [
            (pkgs.runCommandLocal "traefik-plugin-stub" {
              passthru = {
                plugin = "wasm-plugin-name";
                moduleName = "github.com/example/wasm-plugin-name";
                _isTraefikPlugin = true;
              };
            } "mkdir -p $out")
          ];
          install.settings.experimental.localPlugins."wasm-plugin-name".settings = {
            envs = [ "SECRET_ENV" ];
            mounts = [ "/path/to/mount" ];
          };
          routing.settings.http.routers."confighttp" = {
            rule = "Host(`confighttp.config`)";
            entryPoints = [ "web" ];
            service = "confighttp";
          };
        };
      };

    # The three "docs" nodes below mirror verbatim examples from Traefik's own v3.7 documentation
    # and assert that the module renders them 1:1. Each generated file is parsed and compared to the
    # upstream YAML as data, so key order is ignored while list order (meaningful in Traefik) is kept.

    # Test objective: install.settings renders 1:1 to Traefik's canonical static ("traefik.yml")
    # install configuration. No routing provider is set, so the generated --configfile is
    # install.settings verbatim -- including providers.docker: {}, a meaningful empty object that
    # must survive rendering. mkForce replaces the shared `defaults` install.settings so the
    # comparison is against the docs example alone.
    # Docs (v3.7): https://github.com/traefik/traefik/blob/v3.7/docs/content/reference/install-configuration/boot-environment.md
    docstatic = {
      services.traefik = {
        enable = true;
        install.settings = lib.mkForce {
          entryPoints.web.address = ":80";
          entryPoints.websecure.address = ":443";
          providers.docker = { };
          api.dashboard = true;
          log.level = "INFO";
        };
      };
    };

    # Test objective: routing.settings (content-sensing default file mode) renders 1:1 to Traefik's
    # canonical single-service file-provider example, including the meaningful tls: {} (which enables
    # TLS on the router). Guards the file-mode render path against regressions.
    # Docs (v3.7): https://github.com/traefik/traefik/blob/v3.7/docs/content/reference/routing-configuration/other-providers/file.md
    docfile = {
      services.traefik = {
        enable = true;
        routing.settings = {
          http.routers.app = {
            rule = "Host(`example.com`)";
            entryPoints = [ "websecure" ];
            service = "app";
            tls = { };
          };
          http.services.app.loadBalancer.servers = [
            { url = "http://127.0.0.1:8080"; }
          ];
        };
      };
    };

    # Test objective: directory mode renders each routing.files entry to its own
    # _nixos-extra-<name>.yml, each 1:1 with a file-provider example from the same docs page:
    # multiple routers/services, middlewares + TLS options, and the http.yml + tls.yml split of the
    # "loading multiple dynamic configuration files" example.
    # Docs (v3.7): https://github.com/traefik/traefik/blob/v3.7/docs/content/reference/routing-configuration/other-providers/file.md
    docdir = {
      services.traefik = {
        enable = true;
        routing = {
          provider.directory.path = "/etc/traefik/dynamic";
          files = {
            # Example: specifying more than one router and service
            "example2".settings = {
              http.routers.app = {
                rule = "Host(`example-a.com`)";
                service = "app";
              };
              http.routers.admin = {
                rule = "Host(`example-b.com`)";
                service = "admin";
              };
              http.services.app.loadBalancer.servers = [ { url = "http://127.0.0.1:8000"; } ];
              http.services.admin.loadBalancer.servers = [ { url = "http://127.0.0.1:9000"; } ];
            };
            # Example: declaring and referencing middlewares (with TLS options)
            "example3".settings = {
              http.routers.app = {
                rule = "Host(`secure.example.com`)";
                entryPoints = [ "websecure" ];
                middlewares = [ "secure-headers" ];
                service = "app";
                tls.options = "modern";
              };
              http.middlewares.secure-headers.headers = {
                stsSeconds = 31536000;
                forceSTSHeader = true;
              };
              http.services.app.loadBalancer.servers = [ { url = "http://127.0.0.1:8080"; } ];
              tls.options.modern = {
                minVersion = "VersionTLS12";
                sniStrict = true;
              };
            };
            # Example: loading multiple dynamic configuration files (http.yml + tls.yml)
            "http".settings = {
              http.routers.app = {
                rule = "Host(`example.com`)";
                service = "app";
              };
              http.services.app.loadBalancer.servers = [ { url = "http://127.0.0.1:8080"; } ];
            };
            "tls".settings = {
              tls.certificates = [
                {
                  certFile = "/certs/example.crt";
                  keyFile = "/certs/example.key";
                }
              ];
            };
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

  testScript =
    { containers, ... }:
    let
      installConfigOf = container: container.services.traefik.installConfigFile;
    in
    ''
      import json
      import yaml
      import textwrap

      # Store paths of the exact --configfile each daemon is started with, resolved at eval time.
      INSTALL_CONFIG = {
          "config": "${installConfigOf containers.config}",
          "docstatic": "${installConfigOf containers.docstatic}",
          "docdir": "${installConfigOf containers.docdir}",
          "declare": "${installConfigOf containers.declare}",
      }

      def configfile(node):
          return node.succeed(f"cat {INSTALL_CONFIG[node.name]}")

      def assert_routed(host, node):
          # traefik.service is Type=notify: the unit turns active when the daemon
          # sends READY=1, which happens before the file provider has loaded the
          # routes in its background goroutine. timeout=60 absorbs load variance.
          body = client.wait_until_succeeds(f"curl -sSf -H Host:{host} http://{node.name}/", timeout=60)
          assert "Directory listing for " in body, body

      def assert_renders_verbatim(got_json_text, docs_yaml, label, show=True):
          # Both sides parse to plain dicts/lists, so == ignores key order but preserves list order
          # (server order is meaningful in Traefik) -- exactly the 1:1 comparison we want.
          expected = yaml.safe_load(textwrap.dedent(docs_yaml))
          got = json.loads(got_json_text)
          if show:
              # Show the upstream docs example and what the module generated from it.
              print(f"### {label}")
              print("# docs example (YAML):")
              print(textwrap.dedent(docs_yaml).strip())
              print("# generated config (JSON):")
              print(json.dumps(got, indent=2))
          assert got == expected, f"{label}: got={got!r} expected={expected!r}"

      start_all()

      client.wait_for_unit("multi-user.target")
      simplehttp.wait_for_unit("simplehttp.service")
      simplehttp.wait_for_open_port(80)

      declare.wait_for_unit("traefik.service")
      declare.wait_for_open_port(80)

      extra.wait_for_unit("traefik.service")
      extra.wait_for_open_port(80)

      # This subtest reads only the generated --configfile, which exists at eval time, so wait
      # for boot only, not the unit.
      config.wait_for_unit("multi-user.target")

      # The docs nodes only check config generation. The generated files exist regardless of whether
      # the daemon fully starts (docstatic enables providers.docker with no Docker present; docfile
      # routes via a websecure entryPoint no node declares; docdir references cert files that do
      # not exist), so wait only for the machines to boot.
      docstatic.wait_for_unit("multi-user.target")
      docfile.wait_for_unit("multi-user.target")
      docdir.wait_for_unit("multi-user.target")

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

      with subtest("install.settings, injected providers.file and local plugins land in the generated config file"):
          cfg = json.loads(configfile(config))

          # install.settings (entryPoints from `defaults`) is incorporated verbatim
          assert cfg["entryPoints"]["web"]["address"] == ":80", cfg
          # providers.file is injected from routing.provider (file mode)
          assert cfg["providers"]["file"]["filename"] == "/etc/traefik/routing.yml", cfg
          # local plugins: moduleName comes from the package, settings from freeform install.settings
          plugin = cfg["experimental"]["localPlugins"]["wasm-plugin-name"]
          assert plugin["moduleName"] == "github.com/example/wasm-plugin-name", cfg
          assert plugin["settings"]["envs"] == ["SECRET_ENV"], cfg
          assert plugin["settings"]["mounts"] == ["/path/to/mount"], cfg

      with subtest("declare's install config points providers.file at its non-default path"):
          cfg = json.loads(configfile(declare))
          assert cfg["providers"]["file"]["filename"] == "/etc/traefik/custom-routes.yml", cfg

      with subtest("the 1:1 comparison has teeth (a deliberate mismatch must fail)"):
          # Negative control: guards against a vacuously-passing test. tls: {} (empty, which enables
          # TLS) must not compare equal to tls: { options: modern }. If this ever stops raising, the
          # helper is broken and every assertion below is meaningless.
          detected = False
          try:
              assert_renders_verbatim(
                  '{"tls": {}}',
                  """
                  tls:
                    options: modern
                  """,
                  "negative control",
                  show=False,
              )
          except AssertionError:
              detected = True
          assert detected, "assert_renders_verbatim did not detect a mismatch"

      with subtest("install.settings renders 1:1 to the boot-environment traefik.yml example"):
          assert_renders_verbatim(
              configfile(docstatic),
              """
              entryPoints:
                web:
                  address: ":80"
                websecure:
                  address: ":443"
              providers:
                docker: {}
              api:
                dashboard: true
              log:
                level: INFO
              """,
              "install.settings (boot-environment.md)",
          )

      with subtest("routing.settings (file mode) renders 1:1 to the single-service file-provider example"):
          assert_renders_verbatim(
              docfile.succeed("cat /etc/traefik/routing.yml"),
              """
              http:
                routers:
                  app:
                    rule: Host(`example.com`)
                    entryPoints:
                      - websecure
                    service: app
                    tls: {}
                services:
                  app:
                    loadBalancer:
                      servers:
                        - url: http://127.0.0.1:8080
              """,
              "routing example 1",
          )

      with subtest("directory mode renders each routing.files entry 1:1 to its file-provider example"):
          assert_renders_verbatim(
              docdir.succeed("cat /etc/traefik/dynamic/_nixos-extra-example2.yml"),
              """
              http:
                routers:
                  app:
                    rule: Host(`example-a.com`)
                    service: app
                  admin:
                    rule: Host(`example-b.com`)
                    service: admin
                services:
                  app:
                    loadBalancer:
                      servers:
                        - url: http://127.0.0.1:8000
                  admin:
                    loadBalancer:
                      servers:
                        - url: http://127.0.0.1:9000
              """,
              "routing example 2",
          )
          assert_renders_verbatim(
              docdir.succeed("cat /etc/traefik/dynamic/_nixos-extra-example3.yml"),
              """
              http:
                routers:
                  app:
                    rule: Host(`secure.example.com`)
                    entryPoints:
                      - websecure
                    middlewares:
                      - secure-headers
                    service: app
                    tls:
                      options: modern
                middlewares:
                  secure-headers:
                    headers:
                      stsSeconds: 31536000
                      forceSTSHeader: true
                services:
                  app:
                    loadBalancer:
                      servers:
                        - url: http://127.0.0.1:8080
              tls:
                options:
                  modern:
                    minVersion: VersionTLS12
                    sniStrict: true
              """,
              "routing example 3",
          )
          assert_renders_verbatim(
              docdir.succeed("cat /etc/traefik/dynamic/_nixos-extra-http.yml"),
              """
              http:
                routers:
                  app:
                    rule: Host(`example.com`)
                    service: app
                services:
                  app:
                    loadBalancer:
                      servers:
                        - url: http://127.0.0.1:8080
              """,
              "routing example 4 (http.yml)",
          )
          assert_renders_verbatim(
              docdir.succeed("cat /etc/traefik/dynamic/_nixos-extra-tls.yml"),
              """
              tls:
                certificates:
                  - certFile: /certs/example.crt
                    keyFile: /certs/example.key
              """,
              "routing example 4 (tls.yml)",
          )
          # provider wiring: routing.provider.directory drives the static providers.file.directory
          cfg = json.loads(configfile(docdir))
          assert cfg["providers"]["file"]["directory"] == "/etc/traefik/dynamic", cfg

      with subtest("Reach a Docker container via Traefik"):
          # The docker provider discovers container labels asynchronously after
          # READY; timeout=60 absorbs that.
          assert "Hello from NGINX" in docker.wait_until_succeeds(
              "curl -sSf -H Host:nginx.docker http://127.0.0.1/",
              timeout=60,
          )
    '';
}
