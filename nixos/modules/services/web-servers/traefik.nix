{
  options,
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
    attrByPath
    concatMapStringsSep
    concatStringsSep
    filter
    getExe
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
    splitStringBy
    ;

  cfg = config.services.traefik;
  opt = options.services.traefik;

  # check if the option has been changed
  ## isDefault :: String -> bool
  ## eg. isDefault "routing.file" == (cfg.routing.file == opt.routing.file.default)
  isDefault =
    attrPathStr:
    let
      sepPath = splitStringBy (prev: curr: builtins.elem curr [ "." ]) false attrPathStr;
    in
    attrByPath (sepPath ++ [ "default" ]) (throw "isDefault failed") opt
    == attrByPath sepPath (throw "isDefault failed") cfg;

  # JSON is considered valid YAML by Traefik.
  format = pkgs.formats.json { };

  # An external file is used verbatim; a generated file merges the derived file provider and
  # local plugin registration into the user's settings.
  installFile =
    if cfg.install ? file then
      cfg.install.file
    else
      format.generate "install_config.json" (
        recursiveUpdate cfg.install.settings (
          optionalAttrs (cfg.localPlugins != [ ]) {
            experimental.localPlugins = lib.listToAttrs (
              map (plugin: nameValuePair plugin.plugin { inherit (plugin) moduleName; }) cfg.localPlugins
            );
          }
          // optionalAttrs (cfg.routing.dir != null || cfg.routing.file != null) {
            providers.file =
              optionalAttrs (cfg.routing.dir != null) { directory = cfg.routing.dir; }
              // optionalAttrs (cfg.routing.file != null) { filename = cfg.routing.file; };
          }
        )
      );
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
        "file"
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
            {option}`services.traefik.localPlugins`, but you may still add per-plugin `settings`
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
      file = mkOption {
        default = null;
        example = literalExpression "/path/to/routing_config.toml";
        type = nullOr path;
        description = ''
          Path to Traefik's routing configuration file.

          ::: {.note}
          You cannot use this option alongside the declarative configuration options.
          :::
        '';
      };
      dir = mkOption {
        default = "/var/lib/traefik/routing";
        example = literalExpression "/etc/traefik/";
        type = nullOr path;
        description = ''
          Path to the directory Traefik should watch for configuration files.

          ::: {.warning}
          Files in this directory matching the glob `_nixos-*` (reserved for Nix-managed routing configurations) will be deleted whenever
          `systemd-tmpfiles` runs with `--remove` (at boot, and on any activation that changes the tmpfiles rules), _**regardless of their origin.**_
          :::
        '';
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
              This will be serialized to JSON (which is considered valid YAML) at build and
              written to the routing directory.
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
          Routing configuration files to write. These are symlinked in `services.traefik.routing.dir` upon activation,
          allowing configuration to be upated without restarting the primary daemon.

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
          This is serialized to JSON (which is valid YAML) at build and linked into
          {option}`services.traefik.routing.dir` for Traefik's file provider to watch.
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
    localPlugins = mkOption {
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
            cfg.routing.file == null
            && cfg.routing.files == { }
            && cfg.routing.settings == { }
            && cfg.localPlugins == [ ]
          );
        message = ''
          None of the declarative configuration options may be used if Traefik is
          being managed imperatively: 'services.traefik.install.file' is a complete
          install configuration that the module cannot merge into.
          The following options must be unset:
            - ${
              concatStringsSep "\n  - " (
                optional (cfg.routing.file != null) "'services.traefik.routing.file'"
                ++ optional (cfg.routing.files != { }) "'services.traefik.routing.files'"
                ++ optional (cfg.routing.settings != { }) "'services.traefik.routing.settings'"
                ++ optional (cfg.localPlugins != [ ]) "'services.traefik.localPlugins'"
              )
            }
        '';
      }
      {
        assertion =
          cfg.install ? settings -> !(lib.hasAttrByPath [ "providers" "file" ] cfg.install.settings);
        message = ''
          Configure Traefik's file provider through 'services.traefik.routing.file' or
          'services.traefik.routing.dir' rather than setting 'providers.file' in
          'services.traefik.install.settings'.
        '';
      }
      {
        assertion = !(isDefault "routing.file") -> cfg.routing.dir == null;
        message = ''
          The 'services.traefik.routing.file' and 'services.traefik.routing.dir' options
          are mutually exclusive for the Traefik routing config. It is recommended to use
          'services.traefik.routing.dir' with 'services.traefik.routing.files'.
        '';
      }
      {
        assertion = (cfg.routing.files != { } || cfg.routing.settings != { }) -> cfg.routing.dir != null;
        message = ''
          'services.traefik.routing.files' and 'services.traefik.routing.settings' require the
          routing file provider to be set to a directory. Please set a path for
          'services.traefik.routing.dir'.
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
      ++ optional (!builtins.all id (map (plugin: plugin._isTraefikPlugin or false) cfg.localPlugins)) ''
        Some of the Traefik local plugins in 'services.traefik.localPlugins' may be misconfigured.
        The following paths are built from derivations that do not have the '_isTraefikPlugin' attribute set to 'true':
        - ${
          concatMapStringsSep "\n- " (badPlugin: badPlugin.outPath) (
            filter (plugin: !(plugin._isTraefikPlugin or false)) cfg.localPlugins
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
        ReadOnlyPaths = optional (cfg.routing.dir != null) cfg.routing.dir;
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
      # A custom user manages their own routing dir; only create it for the default user.
      # Only Traefik reads this directory and ReadOnlyPaths already forbids writing to it,
      # so it gets the minimum: owner read and traverse.
      (mkIf (cfg.routing.dir != null && cfg.user == "traefik") {
        ${cfg.routing.dir}.d = {
          inherit (cfg) user group;
          mode = "0500";
        };
      })
      (mkIf (cfg.routing.dir != null) (
        {
          "${cfg.routing.dir}/_nixos-*".r = { };
        }
        // optionalAttrs (cfg.routing.settings != { }) {
          "${cfg.routing.dir}/_nixos-settings.yml"."L+".argument = toString (
            format.generate "routing_config.json" cfg.routing.settings
          );
        }
        # The `_nixos-extra-` prefix is a separate namespace from `_nixos-settings.yml`,
        # so a files entry named "settings" cannot collide with the settings file.
        // (mapAttrs' (
          name: value:
          nameValuePair "${cfg.routing.dir}/_nixos-extra-${name}.yml" {
            "L+".argument = toString (format.generate name value.settings);
          }
        ) cfg.routing.files)
      ))
      (mkIf (cfg.localPlugins != [ ]) {
        "${cfg.dataDir}/plugins-local"."L+" = {
          inherit (cfg) user group;
          mode = "0700";
          argument = toString (
            pkgs.symlinkJoin {
              name = "traefik-plugins";
              paths = cfg.localPlugins;
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
