{
  lib,
  beam,
  pkg-config,
  vips,
}: let
  pname = "parrhesia";
  version = "0.1.0";

  beamPackages = beam.packages.erlang_28.extend (
    final: _prev: {
      elixir = final.elixir_1_19;
    }
  );

  projectRoot = ./.;

  src = lib.cleanSourceWith {
    src = projectRoot;
    filter = path: type: let
      pathStr = toString path;
      rootStr = toString projectRoot;
      relPath =
        if pathStr == rootStr
        then "."
        else lib.removePrefix "${rootStr}/" pathStr;
      excluded = [
        ".git"
        ".devenv"
        "_build"
        "deps"
        "node_modules"
        "complement"
      ];
    in
      lib.cleanSourceFilter path type
      && !(lib.any (prefix: relPath == prefix || lib.hasPrefix "${prefix}/" relPath) excluded);
  };

  mixFodDeps =
    if builtins.pathExists ./mix.lock
    then
      beamPackages.fetchMixDeps {
        pname = "${pname}-mix-deps";
        inherit version src;
        hash = "sha256-eAk6FVjVPGcJl3adBSoQvPIva7w4xz4GuZ+DZaz6SYY=";
      }
    else null;
in
  beamPackages.mixRelease {
    inherit pname version src mixFodDeps;

    mixEnv = "prod";
    removeCookie = false;
    nativeBuildInputs = [pkg-config];
    buildInputs = [vips];

    preConfigure = ''
      rm -rf deps _build
      export HOME="$TMPDIR"
      export XDG_CACHE_HOME="$TMPDIR/.cache"
      mkdir -p "$XDG_CACHE_HOME"
      export VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS
      export VIPS_WARNING=false
    '';

    meta = with lib; {
      description = "Parrhesia Matrix homeserver";
      license = licenses.asl20;
      platforms = platforms.unix;
    };
  }
