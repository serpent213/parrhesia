{
  pkgs,
  lib,
  inputs,
  ...
}: let
  mcpServers = [
    {
      name = "sqldb";
      command = "npx";
      args = [
        "-y"
        "@modelcontextprotocol/server-postgres"
        "\"postgresql:///$1?host=$PGHOST\""
      ];
    }
  ];
  renderMcpCommands = {
    tool,
    envPrefix,
  }:
    lib.strings.concatMapStringsSep "\n" (server: let
      args = lib.strings.concatStringsSep " " (
        if server ? args
        then server.args
        else []
      );
      usesDbArg =
        if server ? url
        then lib.strings.hasInfix "$1" server.url
        else lib.strings.hasInfix "$1" args;
      scope =
        if tool == "claude"
        then " --scope project"
        else "";
      remove =
        if tool == "claude"
        then "${envPrefix}${tool} mcp remove${scope} ${server.name} >/dev/null 2>&1 || true\n"
        else "";
      stdioCmd = "${remove}${envPrefix}${tool} mcp add${scope} ${server.name} -- ${server.command} ${args}";
      httpCmd =
        if tool == "claude"
        then "${remove}${envPrefix}${tool} mcp add${scope} --transport http ${server.name} ${server.url}"
        else "${remove}${envPrefix}${tool} mcp add${scope} ${server.name} --url ${server.url}";
      cmd =
        if server ? command
        then stdioCmd
        else if server ? url
        then httpCmd
        else throw "MCP server '${server.name}' must define either 'command' or 'url'";
    in
      if usesDbArg
      then ''
        if [ -n "$1" ]; then
          ${cmd}
        fi
      ''
      else cmd)
    mcpServers;
in {
  # https://devenv.sh/basics/
  # the pre-compiled VIPS library does not support HEIC format
  env.VIX_COMPILATION_MODE = "PLATFORM_PROVIDED_LIBVIPS";
  # disable warnings as long as mozjpeg-linked VIPS is not available everywhere
  env.VIPS_WARNING = "false";
  # Parallel deps compilation
  env.MIX_OS_DEPS_COMPILE_PARTITION_COUNT = 8;

  # https://devenv.sh/packages/
  packages = let
    # WIP Add mozjpeg additionally (does not build on x86 otherwise)
    vips-mozjpeg = with pkgs;
      vips.overrideAttrs (oldAttrs: {
        buildInputs = oldAttrs.buildInputs ++ [mozjpeg];
      });
    nostr-bench = pkgs.callPackage ./nix/nostr-bench.nix {
      nostrBenchSrc = inputs.nostr-bench-src;
    };
  in
    with pkgs;
      [
        just
        # Mix NIFs
        gcc
        git
        gnumake
        autoconf
        automake
        libtool
        pkg-config
        # for tests
        openssl
        # Nix code formatter
        alejandra
        # i18n
        icu
        # PostgreSQL client utilities
        postgresql
        # image processing library
        vips-mozjpeg
        # Mermaid diagram generator
        mermaid-cli
        # Nostr CLI client
        nak
        websocat
        # Nostr relay benchmark client
        nostr-bench
        # Nostr reference servers
        nostr-rs-relay
        # Benchmark graph
        gnuplot
        # Cloud benchmarks
        hcloud
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
        # Nostr reference servers
        strfry
      ];

  # https://devenv.sh/languages/
  languages = {
    elixir = {
      enable = true;
      package = pkgs.elixir_1_19;
    };

    # for Pi agent
    javascript = {
      enable = true;
      npm.enable = true;
    };
  };

  # https://devenv.sh/services/
  services.postgres = {
    enable = true;
    package = pkgs.postgresql_18;

    # Some tuning for the benchmark - doesn't seem to do much
    settings = {
      max_connections = 300;
      shared_buffers = "1GB";
      effective_cache_size = "3GB";
      work_mem = "16MB";
      maintenance_work_mem = "256MB";
      wal_compression = "on";
      checkpoint_timeout = "15min";
      checkpoint_completion_target = 0.9;
      min_wal_size = "1GB";
      max_wal_size = "4GB";
      random_page_cost = 1.1;
      effective_io_concurrency = 200;
    };

    initialDatabases = [{name = "parrhesia_dev";} {name = "parrhesia_test";}];
    initialScript = ''
      CREATE ROLE dev WITH LOGIN PASSWORD 'dev' SUPERUSER;

      -- Make sure we get the right collation
      ALTER database template1 is_template=false;

      DROP database template1;

      CREATE DATABASE template1
        ENCODING = 'UTF8'
        TABLESPACE = pg_default
        LC_COLLATE = 'de_DE.UTF-8'
        LC_CTYPE = 'de_DE.UTF-8'
        CONNECTION LIMIT = -1
        TEMPLATE template0;

      ALTER database template1 is_template=true;
    '';
  };

  dotenv.enable = true;
  devenv.warnOnNewVersion = false;

  # https://devenv.sh/pre-commit-hooks/
  git-hooks.hooks = {
    alejandra.enable = true;
    check-added-large-files = {
      enable = true;
      args = ["--maxkb=16384"];
    };
    mix-format.enable = true;
    mix-format.files = "\\.(ex|exs)$";
  };

  # https://devenv.sh/scripts/
  enterShell = ''
    echo
    elixir --version
    echo
  '';

  scripts = {
    parsrv.exec = "iex --sname dev -S mix parrhesia.server";
    parrun.exec = "elixir --sname console --rpc-eval dev \"$@\"";
    set-claude-mcp.exec = renderMcpCommands {
      tool = "claude";
      envPrefix = ''CLAUDE_CONFIG_DIR=~/.claude''${2:+-''${2}} '';
    };
    set-codex-mcp.exec = renderMcpCommands {
      tool = "codex";
      envPrefix = ''CODEX_HOME=$HOME/.codex''${2:+-''${2}} '';
    };
  };

  # See full reference at https://devenv.sh/reference/options/
}
