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
    bool
    listOf
    nullOr
    path
    str
    submodule
    package
    ;
  inherit (lib)
    attrNames
    attrValues
    concatMapStringsSep
    concatStringsSep
    filter
    foldl'
    getExe
    head
    id
    literalExpression
    maintainers
    mapAttrs'
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    mkRenamedOptionModule
    nameValuePair
    optional
    optionalAttrs
    recursiveUpdate
    ;

  cfg = config.services.traefik;

  # JSON is considered valid YAML by Traefik.
  format = pkgs.formats.json { };

  # Translate the selected routing provider to a `providers.file` block, keyed by its tag: its
  # freeform `settings` plus `path` rendered as `filename` or `directory`.
  providerToFile = {
    file = c: c.settings // { filename = toString c.path; };
    externalFile = c: c.settings // { filename = toString c.path; };
    directory = c: c.settings // { directory = toString c.path; };
  };

  # `providers.file` block injected into the generated install config (empty for no provider).
  # The routing.provider attrTag holds exactly one member, so `head` always has one to take.
  resolvedProviderFile = optionalAttrs (cfg.routing.provider != null) (
    providerToFile.${head (attrNames cfg.routing.provider)} (head (attrValues cfg.routing.provider))
  );

  # An external file is used verbatim; a generated file merges the derived file provider and
  # local plugin registration into the user's settings.
  installFile =
    if cfg.install ? file then
      cfg.install.file
    else
      format.generate "install_config.json" (
        recursiveUpdate cfg.install.settings (
          optionalAttrs (cfg.localPluginPackages != [ ]) {
            experimental.localPlugins = lib.listToAttrs (
              map (plugin: nameValuePair plugin.plugin { inherit (plugin) moduleName; }) cfg.localPluginPackages
            );
          }
          // optionalAttrs (resolvedProviderFile != { }) {
            providers.file = resolvedProviderFile;
          }
        )
      );

  isManagedDir = cfg.routing.provider ? directory;

  # A directory gives every `files` entry its own file; a single file has nowhere else to put
  # them, so they are merged into it.
  routingSettings =
    if isManagedDir then
      cfg.routing.settings
    else
      foldl' recursiveUpdate cfg.routing.settings (
        map (entry: entry.settings) (attrValues cfg.routing.files)
      );

  # JSON is considered valid YAML by Traefik, so this generated JSON is linked under a `.yml`
  # name for the file provider (see the tmpfiles rules below). Rendered verbatim so meaningful
  # empty objects (like `tls: {}`, which enables TLS on a router) survive.
  routingFile = format.generate "routing_config.json" routingSettings;
in
{
  imports = [
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
    enable = mkEnableOption "Traefik web server";
    package = mkPackageOption pkgs "traefik" { };

    # ExecStart is built from this, so it is exactly the file the daemon reads.
    # Read-only view of the exact file the daemon runs; also used by the NixOS tests.
    installConfigFile = mkOption {
      type = path;
      readOnly = true;
      description = ''
        The effective install configuration file the daemon is started with, passed as
        `--configfile`: either {option}`services.traefik.install.file` verbatim, or the file
        generated from {option}`services.traefik.install.settings`.
      '';
    };

    install = mkOption {
      default = {
        settings = { };
      };
      example = {
        settings = {
          entryPoints.web.address = ":80";
          entryPoints.websecure.address = ":443";
        };
      };
      description = ''
        Source of Traefik's [install configuration](https://doc.traefik.io/traefik/reference/install-configuration/boot-environment/).

        ::: {.note}
        Set exactly one of `file` or `settings`; they are mutually exclusive.
        :::
      '';
      type = attrTag {
        file = mkOption {
          example = literalExpression "/path/to/install_config.toml";
          type = path;
          description = ''
            Path to Traefik's install configuration file.

            ::: {.note}
            This is a complete install configuration that the module cannot merge
            into: it cannot be combined with the module's declarative routing or
            local-plugin options.
            Use {option}`services.traefik.install.settings` for a configuration
            the module generates and can merge into.
            :::
          '';
        };
        settings = mkOption {
          description = ''
            Install configuration for Traefik, written in Nix. Write Traefik's static
            configuration directly here — `entryPoints`, `api`, `tls`, and so on map 1:1
            to a Traefik config file.

            ::: {.note}
            This will be serialized to JSON (which is considered valid YAML) at build, and passed to Traefik as `--configfile`.
            :::

            ::: {.note}
            The `providers.file` block is derived from {option}`services.traefik.routing`; do not
            set `providers.file` here. `experimental.localPlugins` entries are generated from
            {option}`services.traefik.localPluginPackages`, but you may still add per-plugin `settings`
            (such as `envs` and `mounts`) here.
            :::
          '';
          type = format.type;
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
      provider =
        let
          # Shared by all three modes: the per-provider `providers.file` freeform block.
          providerSettings = mkOption {
            type = format.type;
            default = { };
            example = {
              watch = false;
            };
            description = ''
              Additional [`providers.file`](https://doc.traefik.io/traefik/reference/install-configuration/providers/others/file/)
              configuration for this provider, merged verbatim into Traefik's generated
              `providers.file` block. The `path` is configured separately.
            '';
          };
        in
        mkOption {
          default = if cfg.routing.settings == { } && cfg.routing.files == { } then null else { file = { }; };
          defaultText = literalExpression "if routing.settings == { } && routing.files == { } then null else { file = { }; }";
          example = {
            file.path = "/etc/traefik/routing.yml";
          };
          description = ''
            How Traefik's [file provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/others/file/)
            gets its routing configuration: pick exactly one of `file`, `externalFile`, or
            `directory`, or set to `null` to disable it (for example a docker-labels-only setup).
          '';
          type = nullOr (attrTag {
            file = mkOption {
              description = ''
                NixOS-managed single file. {option}`services.traefik.routing.settings` and every
                {option}`services.traefik.routing.files` entry are merged into it and linked at `path`.
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
                You cannot use this option alongside the declarative routing configuration options.
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
                each {option}`services.traefik.routing.files` entry to `_nixos-extra-<name>.yml`;
                you may add your own files too.
                :::
              '';
              type = submodule {
                options = {
                  path = mkOption {
                    type = path;
                    default = "/var/lib/traefik/routing";
                    description = ''
                      Path to the directory Traefik should watch for configuration files (`providers.file.directory`).

                      ::: {.warning}
                      Files in this directory matching the glob `_nixos-*` (reserved for Nix-managed routing configurations) will be deleted whenever
                      `systemd-tmpfiles` runs with `--remove` (at boot, and on any activation that changes the tmpfiles rules), _**regardless of their origin.**_
                      :::

                      ::: {.note}
                      When {option}`services.traefik.user` is left at its default `traefik`, this
                      directory is created with appropriate ownership and permissions automatically.
                      Otherwise you are responsible for ensuring it exists with appropriate
                      ownership before the Traefik service starts.
                      :::
                    '';
                  };
                  settings = providerSettings;
                };
              };
            };
          });
        };
      files = mkOption {
        type = attrsOf (submodule {
          options.settings = mkOption {
            type = attrsOf format.type;
            # Empty entries are deliberate: a contribution like `settings = mkIf cond { ... }`
            # must degrade to an empty attrset to keep it mergeable without errors. It still
            # renders `{}` to Traefik, which is handled as a no-op.
            default = { };
            description = ''
              Routing configuration for Traefik, written in Nix.

              ::: {.note}
              This lands in the routing configuration: depending on
              {option}`services.traefik.routing.provider`, it is merged into the single generated
              routing file (`file` mode) or written as its own `_nixos-extra-<name>.yml`
              (`directory` mode).
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
        description = ''
          Named routing configuration, kept apart from {option}`services.traefik.routing.settings`
          so that each entry can be identified and replaced on its own. This is where other NixOS
          modules should contribute routing configuration, without needing to know how the file
          provider is configured. {option}`services.traefik.routing.provider` governs how the
          entries are served: in `directory` mode each becomes its own `_nixos-extra-<name>.yml`,
          in `file` mode they are merged into the single generated file. Either way the file
          provider reloads them without restarting the primary daemon.

          ::: {.note}
          Due to [a limitation in Traefik](https://github.com/traefik/traefik/issues/10890); any syntax error in a routing configuration will cause the _**entire file provider**_ to be ignored.
          This may cause interruption in service, which may include access to the Traefik dashboard, if [enabled and configured](https://doc.traefik.io/traefik/reference/install-configuration/api-dashboard/).
          :::
        '';
      };
      settings = mkOption {
        type = attrsOf format.type;
        description = ''
          Routing configuration for Traefik, written in Nix. This is where this
          machine's own routing configuration belongs; other NixOS modules should
          contribute through {option}`services.traefik.routing.files` instead,
          so each contribution stays identifiable and can be overridden on its own.

          ::: {.note}
          This is serialized to JSON (which is valid YAML) at build and served through the file
          provider selected by {option}`services.traefik.routing.provider`.
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
      example = literalExpression "[ pkgs.fosrl-badger pkgs.geoblock ]";
      description = ''
        List of local plugins to be added to `experimental.localPlugins` in the install configuration. These plugins are usually packaged in Nixpkgs, and are managed by Nix.
      '';
    };

    dataDir = mkOption {
      default = "/var/lib/traefik";
      type = path;
      description = ''
        Location for any persistent data Traefik creates, such as the ACME certificate store.

        ::: {.note}
        When {option}`services.traefik.user` or {option}`services.traefik.group` is left at
        its default `traefik`, this directory is created automatically before the Traefik
        server starts. Otherwise you are responsible for ensuring it exists with appropriate
        ownership and permissions.
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
        With the `docker` provider, Traefik manages connection to containers via the Docker socket,
        which requires membership of the `docker` group for write access.
        :::
      '';
    };

    environmentFiles = mkOption {
      default = [ ];
      type = listOf path;
      example = [ "/run/secrets/traefik.env" ];
      description = ''
        Files to load as an environment file just before Traefik starts.
        This can be used to pass secrets such as [DNS challenge API tokens](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/#providers) or [ENV variables](https://doc.traefik.io/traefik/reference/install-configuration/boot-environment/#environment-variables).
        ```
        DESEC_TOKEN=
        TRAEFIK_CERTIFICATESRESOLVERS_<NAME>_ACME_EAB_HMACENCODED=
        TRAEFIK_CERTIFICATESRESOLVERS_<NAME>_ACME_EAB_KID=
        ```
        ::: {.warning}
        The traefik install configuration methods (env, CLI, and file) are mutually exclusive.
        It's crucial to choose one method and stick to it, as mixing different configuration
        options is not supported and can lead to unexpected behavior.
        :::
      '';
    };
  };

  config = mkIf cfg.enable {
    services.traefik.installConfigFile = installFile;

    assertions = [
      {
        assertion =
          cfg.install ? file
          -> (
            cfg.routing.provider == null
            && cfg.routing.settings == { }
            && cfg.routing.files == { }
            && cfg.localPluginPackages == [ ]
          );
        message = ''
          None of the declarative configuration options may be used if Traefik is
          being managed imperatively: 'services.traefik.install.file' is a complete
          install configuration that the module cannot merge into.
          The following options must be unset:
            - ${
              concatStringsSep "\n  - " (
                optional (cfg.routing.provider != null) "'services.traefik.routing.provider'"
                ++ optional (cfg.routing.settings != { }) "'services.traefik.routing.settings'"
                ++ optional (cfg.routing.files != { }) "'services.traefik.routing.files'"
                ++ optional (cfg.localPluginPackages != [ ]) "'services.traefik.localPluginPackages'"
              )
            }
        '';
      }
      {
        assertion =
          cfg.install ? settings -> !(lib.hasAttrByPath [ "providers" "file" ] cfg.install.settings);
        message = ''
          Configure Traefik's file provider through 'services.traefik.routing.provider' rather
          than setting 'providers.file' in 'services.traefik.install.settings'.
        '';
      }
      {
        assertion =
          cfg.routing.provider ? externalFile -> (cfg.routing.settings == { } && cfg.routing.files == { });
        message = ''
          'services.traefik.routing.provider.externalFile' is managed imperatively and
          cannot serve 'services.traefik.routing.settings' or
          'services.traefik.routing.files'. Use 'file' or 'directory' instead.
        '';
      }
      {
        # The content-sensing default is never null while routing configuration exists, so this
        # only fires when a provider is set to null explicitly.
        assertion =
          cfg.routing.provider == null -> (cfg.routing.settings == { } && cfg.routing.files == { });
        message = ''
          'services.traefik.routing.settings' or 'services.traefik.routing.files' is set but
          'services.traefik.routing.provider' is null, so there is no file provider to serve it.
          Set 'provider' to 'file' or 'directory'.
        '';
      }
      {
        assertion = cfg.group != "docker";
        message = ''
          Setting the primary group to 'docker' will cause files Traefik creates at
          runtime, such as the ACME certificate store in 'services.traefik.dataDir',
          to be owned by the group 'docker', which may be a security risk.
          Use 'services.traefik.supplementaryGroups' instead.
        '';
      }
    ];

    warnings =
      optional (!(builtins.elem "docker" cfg.supplementaryGroups -> config.virtualisation.docker.enable))
        "'services.traefik.supplementaryGroups' contains the 'docker' group, but 'virtualisation.docker.enable' is not enabled."
      ++
        optional (!builtins.all id (map (plugin: plugin._isTraefikPlugin or false) cfg.localPluginPackages))
          ''
            Some of the Traefik local plugins in 'services.traefik.localPluginPackages' may be misconfigured.
            The following paths are built from derivations that do not have the '_isTraefikPlugin' attribute set to 'true':
            - ${
              concatMapStringsSep "\n- " (badPlugin: badPlugin.outPath) (
                filter (plugin: !(plugin._isTraefikPlugin or false)) cfg.localPluginPackages
              )
            }
          '';

    # https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
    boot.kernel.sysctl = {
      "net.core.rmem_max" = 2500000;
      "net.core.wmem_max" = 2500000;
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
        ExecStart = "${getExe cfg.package} --configfile=${cfg.installConfigFile}";
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
          optional isManagedDir "-${toString cfg.routing.provider.directory.path}"
          ++ optional (cfg.routing.provider ? file) (toString cfg.routing.provider.file.path)
          ++ optional (
            cfg.routing.provider ? externalFile
          ) "-${toString cfg.routing.provider.externalFile.path}";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectory = "traefik";
        WorkingDirectory = cfg.dataDir;
        WatchdogSec = "1s";
      };
    };

    systemd.tmpfiles.settings."10-traefik" = mkMerge [
      (mkIf (cfg.user == "traefik" || cfg.group == "traefik") {
        ${cfg.dataDir}.d = {
          # Claim ownership only for the halves left at the module default; an omitted
          # half falls back to root rather than the custom identity — chowning to a
          # shared uid like `nobody` would open the directory to every process running
          # as it. With a custom user the default traefik group is the daemon's access
          # path (0770); with the default user the owner bits suffice (0700).
          user = mkIf (cfg.user == "traefik") cfg.user;
          group = mkIf (cfg.group == "traefik") cfg.group;
          mode = if cfg.user == "traefik" then "0700" else "0770";
        };
      })
      (mkIf (cfg.routing.provider ? file) {
        ${toString cfg.routing.provider.file.path}."L+".argument = toString routingFile;
      })
      # A custom user manages their own routing dir; only create it for the default user.
      # Only Traefik reads this directory and ReadOnlyPaths already forbids writing to it,
      # so it gets the minimum: owner read and traverse.
      (mkIf (isManagedDir && cfg.user == "traefik") {
        ${toString cfg.routing.provider.directory.path}.d = {
          inherit (cfg) user group;
          mode = "0500";
        };
      })
      (mkIf isManagedDir (
        let
          dir = toString cfg.routing.provider.directory.path;
        in
        {
          "${dir}/_nixos-*".r = { };
        }
        // optionalAttrs (cfg.routing.settings != { }) {
          "${dir}/_nixos-settings.yml"."L+".argument = toString routingFile;
        }
        # The `_nixos-extra-` prefix is a separate namespace from `_nixos-settings.yml`,
        # so a files entry named "settings" cannot collide with the settings file.
        // (mapAttrs' (
          name: value:
          nameValuePair "${dir}/_nixos-extra-${name}.yml" {
            "L+".argument = toString (format.generate name value.settings);
          }
        ) cfg.routing.files)
      ))
      (mkIf (cfg.localPluginPackages != [ ]) {
        "${cfg.dataDir}/plugins-local"."L+" = {
          inherit (cfg) user group;
          mode = "0700";
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
      users = optionalAttrs (cfg.user == "traefik") {
        traefik = {
          inherit (cfg) group;
          isSystemUser = true;
        };
      };
      groups = optionalAttrs (cfg.group == "traefik") { traefik = { }; };
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
