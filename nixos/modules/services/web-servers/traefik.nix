{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib.types)
    attrTag
    attrsOf
    listOf
    nullOr
    path
    str
    submodule
    package
    ;
  inherit (lib)
    attrByPath
    attrNames
    attrValues
    concatMapStringsSep
    converge
    filter
    filterAttrsRecursive
    getExe
    head
    listToAttrs
    literalExpression
    mapAttrs'
    mkDefault
    mkIf
    mkMerge
    mkOption
    mkRenamedOptionModule
    mkRemovedOptionModule
    nameValuePair
    optional
    optionalAttrs
    recursiveUpdate
    ;

  cfg = config.services.traefik;
  json = pkgs.formats.json { };
  # Traefik accepts JSON as a valid YAML subset
  # Strip empty markers (`null`/`{}`/`[]`) before generating config. `converge` repeats until a
  # fixpoint so attrsets that become empty only after their children are removed are dropped too.
  filterEmpty = converge (filterAttrsRecursive (_: v: v != null && v != { } && v != [ ]));

  # Freeform `providers.file` configuration shared by the routing providers (watch, ...).
  providerSettings = mkOption {
    type = json.type;
    default = { };
    example = {
      watch = false;
    };
    description = ''
      Additional `providers.file` configuration merged verbatim into Traefik's generated
      `providers.file` block for this provider — for example `watch` (which defaults to `true`
      in Traefik). The `path` (and, for a directory, `extraFiles`) is configured separately.
    '';
  };

  # Convert the selected routing provider to a providers.file block, keyed by its tag: its
  # freeform `settings` plus the `path` translated to `filename`/`directory`.
  providerToFile = {
    file = c: c.settings // { filename = toString c.path; };
    externalFile = c: c.settings // { filename = toString c.path; };
    directory = c: c.settings // { directory = toString c.path; };
  };

  # providers.file block injected into the generated install config (empty for no provider).
  resolvedProviderFile = optionalAttrs (cfg.routing.provider != null) (
    providerToFile.${head (attrNames cfg.routing.provider)} (head (attrValues cfg.routing.provider))
  );

  # Passed to the daemon as `--configfile`: the external file verbatim, or generated from
  # `install.settings` with the file provider and local plugins merged in.
  staticConfigFile =
    if cfg.install ? file then
      toString cfg.install.file
    else
      json.generate "install_config.json" (
        filterEmpty (
          recursiveUpdate cfg.install.settings (
            {
              providers.file = resolvedProviderFile;
            }
            // optionalAttrs (cfg.localPluginPackages != [ ]) {
              experimental.localPlugins = listToAttrs (
                map (plugin: nameValuePair plugin.plugin { inherit (plugin) moduleName; }) cfg.localPluginPackages
              );
            }
          )
        )
      );

  routingFile = json.generate "routing_config.json" (filterEmpty cfg.routing.settings);

  managedDir = cfg.routing.provider ? directory;
in
{
  imports = [
    (mkRemovedOptionModule
      [
        "services"
        "traefik"
        "useEnvSubst"
      ]
      # TODO link docs
      "Use `services.traefik.environmentFiles` instead, see DOCSLINK"
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "staticConfigFile"
      ]
      [
        "services"
        "traefik"
        "install"
        "file"
      ]
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "staticConfigOptions"
      ]
      [
        "services"
        "traefik"
        "install"
        "settings"
      ]
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "dynamicConfigFile"
      ]
      [
        "services"
        "traefik"
        "routing"
        "provider"
        "externalFile"
        "path"
      ]
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "dynamicConfigOptions"
      ]
      [
        "services"
        "traefik"
        "routing"
        "settings"
      ]
    )
  ];
  options.services.traefik = {
    enable = lib.mkEnableOption "Traefik web server";
    package = lib.mkPackageOption pkgs "traefik" { };

    install = mkOption {
      default = {
        settings = { };
      };
      description = ''
        Source of Traefik's install (static) configuration.

        ::: {.note}
        Set exactly one of `file` or `settings`; they are mutually exclusive.
        :::
      '';
      type = attrTag {
        file = mkOption {
          example = literalExpression "/path/to/install_config.yml";
          type = path;
          description = ''
            Path to Traefik's install configuration file, passed to the daemon as `--configfile`

            ::: {.note}
            You cannot use this option alongside the declarative install configuration options.
            :::
          '';
        };
        settings = mkOption {
          description = ''
            Install configuration for Traefik, written in Nix.

            ::: {.warning}
            Empty values (`{}`, `[]`, and `null`) are filtered out by default, since they are used to represent
            unset values in option defaults.
            Instead of declaring empty but present attributes as `attr = {}`, declare them as `attr = true`.
            :::

            ::: {.note}
            This will be serialized to JSON (which is considered valid YAML) at build, and passed to Traefik as `--configfile`.
            :::

            ::: {.note}
            The `providers.file` block is derived from {option}`services.traefik.routing`; do
            not set `providers.file` here.
            `experimental.localPlugins` entries are generated from
            {option}`services.traefik.localPluginPackages`, but you may still add per-plugin
            `settings` (such as `envs` and `mounts`) here.
            :::
          '';
          type = json.type;
          default = { };
          example = {
            entryPoints = {
              "web" = {
                address = ":80";
                http.redirections.entryPoint = {
                  permanent = true;
                  scheme = "https";
                  to = "websecure";
                };
              };
              "websecure" = {
                address = ":443";
                asDefault = true;
              };
            };
          };
        };
      };
    };

    routing = {
      provider = mkOption {
        # No file provider when there is nothing declarative to serve; otherwise a single
        # generated file. Any explicit value overrides this.
        default = if cfg.routing.settings == { } then null else { file = { }; };
        defaultText = literalExpression "if routing.settings == { } then null else { file = { }; }";
        description = ''
          Where Traefik's file provider reads routing configuration from, or `null` for no file
          provider (for example a docker-labels-only setup).

          ::: {.note}
          `path` maps to `providers.file.filename` (for `file`/`externalFile`) or
          `providers.file.directory` (for `directory`). Any other `providers.file.*` key (such
          as `watch`, which defaults to `true` in Traefik) goes under `settings`. The modes are
          mutually exclusive.
          :::
        '';
        type = nullOr (attrTag {
          file = mkOption {
            description = ''
              NixOS-managed single file. {option}`services.traefik.routing.settings` is
              serialized to it and linked at `path`.
            '';
            type = submodule {
              options = {
                path = mkOption {
                  type = path;
                  default = "/etc/traefik/routing.yml";
                  description = "Location the generated routing file is linked to (`providers.file.filename`).";
                };
                settings = providerSettings;
              };
            };
          };
          externalFile = mkOption {
            description = ''
              User-managed single routing configuration file.

              ::: {.note}
              You cannot use this option alongside the declarative {option}`services.traefik.routing.settings` option.
              :::
            '';
            type = submodule {
              options = {
                path = mkOption {
                  type = path;
                  example = literalExpression "/path/to/routing_config.yml";
                  description = "Path to the user-managed routing file (`providers.file.filename`).";
                };
                settings = providerSettings;
              };
            };
          };
          directory = mkOption {
            description = ''
              Directory Traefik watches for routing configuration files.

              ::: {.note}
              {option}`services.traefik.routing.settings` is written to `_nixos-settings.yml` and
              each `extraFiles.<name>` to `_nixos-extra-<name>.yml`; you may add your own files too.
              :::
            '';
            type = submodule {
              options = {
                path = mkOption {
                  type = path;
                  example = literalExpression "/etc/traefik/routing";
                  description = ''
                    Path to the directory Traefik should watch for configuration files.

                    ::: {.warning}
                    Files in this directory matching the glob `_nixos-*` (reserved for Nix-managed routing configurations) will be deleted as part of
                    `systemd-tmpfiles-resetup.service`, _**regardless of their origin.**_.
                    :::

                    ::: {.note}
                    When {option}`services.traefik.user` and {option}`services.traefik.group` are
                    left at their default `traefik`, this directory is created with appropriate
                    ownership and permissions automatically. Otherwise you are responsible for
                    ensuring it exists with appropriate ownership before the Traefik service starts.
                    :::
                  '';
                };
                extraFiles = mkOption {
                  type = attrsOf (submodule {
                    options.settings = mkOption {
                      type = json.type;
                      description = ''
                        Routing configuration for Traefik, written in Nix.

                        ::: {.note}
                        This will be serialized to JSON (which Traefik accepts as a valid YAML subset) at build, and passed as part of the install file.
                        :::
                      '';
                      example = {
                        http.routers."api" = {
                          service = "api@internal";
                          rule = "Host(`localhost`)";
                        };
                      };
                    };
                  });
                  default = { };
                  example = {
                    "dashboard".settings = {
                      http.routers."api" = {
                        service = "api@internal";
                        rule = "Host(`198.51.100.1`)";
                      };
                    };
                  };
                  # TODO process `extraFiles` and validate by json schema,
                  # schema available at schemastore.org
                  # Complete as part of separate PR
                  description = ''
                    Routing configuration files to write. These are symlinked in `services.traefik.routing.provider.directory.path` upon activation,
                    allowing configuration to be updated without restarting the primary daemon.

                    ::: {.note}
                    Due to [a limitation in Traefik](https://github.com/traefik/traefik/issues/10890); a syntax error in _**any**_ routing configuration will cause the _**entire file provider**_ to be ignored.
                    This may cause interruption in service, which may include access to the Traefik dashboard, if [enabled and configured](https://doc.traefik.io/traefik/reference/install-configuration/api-dashboard/).
                    :::
                  '';
                };
                settings = providerSettings;
              };
            };
          };
        });
      };
      settings = mkOption {
        type = json.type;
        description = ''
          Routing configuration for Traefik, written in Nix.

          ::: {.note}
          Other modules can contribute to this option (for example to expose a service through
          Traefik) without knowing how the file provider is configured. A module that does so
          should document the router, service, and middleware names it adds — and whether it
          declares a router, a service, or both — so that users can override them.
          :::
        '';
        default = { };
        example = {
          http.routers."api" = {
            service = "api@internal";
            rule = "Host(`localhost`)";
          };
        };
      };
    };
    localPluginPackages = mkOption {
      default = [ ];
      type = listOf package;
      example = [
        pkgs.geoblock
        pkgs.fetchTraefikPlugin
        {
          plugin = "plugindemo";
          owner = "traefik";
          version = "0.2.2";
          hash = "sha256-6MuKVvtHUtWuibjUMZknOEklzaHQUjRYHvXdP2QqE6c=";
        }
      ];
      # TODO mention how to add packages which aren't in nixpkgs yet
      description = ''
        List of plugin packages to be added to the `localPlugins` attribute in the install configuration.

        These plugins can be packaged in Nixpkgs, or [fetched directly](#module-services-traefik-plugins-custom)
      '';
    };

    dataDir = mkOption {
      default = "/var/lib/traefik";
      type = path;
      description = ''
        Location for any persistent data Traefik creates, such as the ACME certificate store.

        ::: {.note}
        If left as the default value, this directory will automatically be created
        before the Traefik server starts, otherwise you are responsible for ensuring
        the directory exists with appropriate ownership and permissions.
        :::
      '';
    };

    user = mkOption {
      default = "traefik";
      type = str;
      description = ''
        User under which Traefik runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the Traefik service starts.
        :::
      '';
    };

    group = mkOption {
      default = "traefik";
      type = str;
      description = ''
        Primary group under which Traefik runs.
        For the Docker backend, use {option}`services.traefik.supplementaryGroups` instead of overriding this option.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the Traefik service starts.
        :::
      '';
    };

    supplementaryGroups = mkOption {
      default = [ ];
      type = listOf str;
      example = [ "docker" ];
      description = ''
        Additional groups under which Traefik runs.
        This can be used to give additional permissions, such as the group required by the `docker` provider.

        ::: {.note}
        With the `docker` routing provider, Traefik manages connection to containers via the Docker socket,
        which requires membership of the `docker` group for write access.
        :::
      '';
    };

    environmentFiles = mkOption {
      default = [ ];
      type = listOf path;
      example = [ "/run/secrets/traefik.env" ];
      # TODO make sure this covers all use cases, give instructions on how to reference
      # an environment variable from within the traefik install/routing config if applicable
      description = ''
        Files to load as an environment file just before Traefik starts.
        This can be used to pass secrets such as [DNS challenge API tokens](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/#providers) or [ENV variables](https://doc.traefik.io/traefik/reference/install-configuration/boot-environment/#environment-variables).
        ```
        DESEC_TOKEN=
        TRAEFIK_CERTIFICATESRESOLVERS_<NAME>_ACME_EAB_HMACENCODED=
        TRAEFIK_CERTIFICATESRESOLVERS_<NAME>_ACME_EAB_KID=
        ```
        ::: {.warn}
        The traefik install configuration methods (env, CLI, and file) are mutually exclusive.
        :::
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.install ? file
          -> (cfg.routing.provider == null && cfg.routing.settings == { } && cfg.localPluginPackages == [ ]);
        message = ''
          'services.traefik.install.file' is a complete external install config; NixOS cannot
          inject a file provider, routing, or plugins into it. Declare those inside the file, or
          use 'services.traefik.install.settings'.
        '';
      }
      {
        assertion = cfg.routing.provider ? externalFile -> cfg.routing.settings == { };
        message = ''
          'services.traefik.routing.provider.externalFile' is user-managed and cannot serve
          'services.traefik.routing.settings'. Use 'file' or 'directory' instead.
        '';
      }
      {
        assertion = cfg.routing.provider == null -> cfg.routing.settings == { };
        message = ''
          'services.traefik.routing.settings' is set but 'services.traefik.routing.provider' is
          null, so there is no file provider to serve it. Set 'provider' to 'file' or 'directory'.
        '';
      }
      {
        assertion =
          cfg.install ? settings -> attrByPath [ "providers" "file" ] null cfg.install.settings == null;
        message = ''
          Configure Traefik's file provider through 'services.traefik.routing.provider' rather
          than setting 'providers.file' in 'services.traefik.install.settings'.
        '';
      }
      {
        assertion = cfg.group != "docker";
        message = ''
          Setting the primary group to 'docker' will cause files, such as those generated
          by 'services.traefik.routing.provider.directory.extraFiles', to be owned by the group 'docker', which
          may be a security risk. Use 'services.traefik.supplementaryGroups' instead.
        '';
      }
    ];

    warnings =
      optional (!(builtins.elem "docker" cfg.supplementaryGroups -> config.virtualisation.docker.enable))
        # TODO wording of "is this intentional"
        "'services.traefik.supplementaryGroups' contains the 'docker' group, but 'virtualisation.docker.enable' is not enabled. If this is intentional, please open an issue notifying the traefik maintainers"
      # TODO check for functionality as intended
      # TODO does/can this show where the definition location is (i.e. what file of the user's config)?
      ++ optional (!(builtins.all (plugin: plugin._isTraefikPlugin or false) cfg.localPluginPackages)) ''
        Some of the Traefik local plugins in 'services.traefik.localPluginPackages' may be misconfigured.
        The following paths are built from derivations that do not have the '_isTraefikPlugin' attribute set to 'true':
        - ${
          concatMapStringsSep "\n- " (badPlugin: badPlugin.outPath) (
            filter (plugin: !plugin._isTraefikPlugin or false) cfg.localPluginPackages
          )
        }
      '';

    # https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
    boot.kernel.sysctl = {
      "net.core.rmem_max" = mkDefault 7500000;
      "net.core.wmem_max" = mkDefault 7500000;
    };

    systemd.services.traefik = {
      description = "Traefik reverse proxy";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      startLimitIntervalSec = 86400;
      startLimitBurst = 5;
      unitConfig.Documentation = "https://doc.traefik.io/traefik/";
      serviceConfig = {
        EnvironmentFile = cfg.environmentFiles;
        ExecStart = "${getExe cfg.package} --configfile=${staticConfigFile}";
        Type = "notify";
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = mkIf (cfg.supplementaryGroups != [ ]) cfg.supplementaryGroups;
        Restart = "always";
        AmbientCapabilities = "cap_net_bind_service";
        CapabilityBoundingSet = "cap_net_bind_service";
        NoNewPrivileges = true;
        TasksMax = 64;
        LimitNOFILE = 1048576;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ cfg.dataDir ];
        ReadOnlyPaths =
          optional managedDir (toString cfg.routing.provider.directory.path)
          ++ optional (cfg.routing.provider ? file) (toString cfg.routing.provider.file.path)
          ++ optional (cfg.routing.provider ? externalFile) (toString cfg.routing.provider.externalFile.path);
        RuntimeDirectoryMode = "0700";
        RuntimeDirectory = "traefik";
        WorkingDirectory = cfg.dataDir;
        WatchdogSec = "1s";
      };
    };

    systemd.tmpfiles.settings."10-traefik" = mkMerge [
      (mkIf (cfg.user == "traefik" || cfg.group == "traefik") {
        ${cfg.dataDir}.d = {
          user = mkIf (cfg.user == "traefik") cfg.user;
          group = mkIf (cfg.group == "traefik") cfg.group;
          mode = "0770";
        };
      })
      (mkIf (cfg.routing.provider ? file) {
        ${toString cfg.routing.provider.file.path}."L+".argument = toString routingFile;
      })
      (mkIf (managedDir && (cfg.user == "traefik" || cfg.group == "traefik")) {
        ${toString cfg.routing.provider.directory.path}.d = {
          user = mkIf (cfg.user == "traefik") cfg.user;
          group = mkIf (cfg.group == "traefik") cfg.group;
          # Traefik doesn't need write perms on this, only read/execute. Global read isn't a security risk
          # because the files that are linked within are already in /nix/store
          mode = "0555";
        };
      })
      (mkIf managedDir (
        let
          dir = toString cfg.routing.provider.directory.path;
        in
        {
          # Remove previous declarative routing configuration files
          "${dir}/_nixos-*".r = { };
        }
        // optionalAttrs (cfg.routing.settings != { }) {
          "${dir}/_nixos-settings.yml"."L+".argument = toString routingFile;
        }
        // (mapAttrs' (
          name: value:
          nameValuePair "${dir}/_nixos-extra-${name}.yml" {
            "L+".argument = toString (json.generate name value.settings);
          }
        ) cfg.routing.provider.directory.extraFiles)
      ))
      # Symlink package directories (in the nix store) to the `plugins-local` folder
      # This path is hard coded, and should be placed in the working directory of the process running the Traefik binary.
      # TODO What happens to old symlinks? it appears they would just pile up indefinitely.
      (mkIf (cfg.localPluginPackages != [ ]) {
        "${cfg.dataDir}/plugins-local"."L+" = {
          argument = toString (
            pkgs.symlinkJoin {
              name = "traefik-plugins";
              paths = cfg.localPluginPackages;
            }
          );
        };
      })
    ];

    users = {
      users = mkIf (cfg.user == "traefik") {
        traefik = {
          inherit (cfg) group;
          isSystemUser = true;
        };
      };
      groups = mkIf (cfg.group == "traefik") { traefik = { }; };
    };
  };

  meta = {
    maintainers = with lib.maintainers; [
      jackr
      therealgramdalf
    ];
    doc = ./traefik.md;
  };
}
