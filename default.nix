{
  lib,
  beam,
  fetchFromGitHub,
  runCommand,
  autoconf,
  automake,
  libtool,
  pkg-config,
  vips,
}: let
  pname = "parrhesia";
  version = "0.6.0";

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
        "marmot-ts"
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
        hash = "sha256-D69wuFnIChQzm1PmpIW+X/1sPpsIcDHe4V5fKmFeJ3k=";
      }
    else null;

  # lib_secp256k1 is a :make dep and may not be present in fetchMixDeps output.
  # Inject the Hex package explicitly, then vendor upstream bitcoin-core/secp256k1
  # sources to avoid build-time network access.
  libSecp256k1Hex = beamPackages.fetchHex {
    pkg = "lib_secp256k1";
    version = "0.7.1";
    sha256 = "sha256-eL3TZhoXRIr/Wu7FynTI3bwJsB8Oz6O6Gro+iuR6srM=";
  };

  elixirMakeHex = beamPackages.fetchHex {
    pkg = "elixir_make";
    version = "0.9.0";
    sha256 = "sha256-2yPU/Yt1dGKtAviqc0MaQm/mZxyAsgDZcQyvPR3Q/9s=";
  };

  secp256k1Src = fetchFromGitHub {
    owner = "bitcoin-core";
    repo = "secp256k1";
    rev = "v0.7.1";
    hash = "sha256-DnBgetf+98n7B1JGtyTdxyc+yQ51A3+ueTIPPSWCm4E=";
  };

  patchedMixFodDeps =
    if mixFodDeps == null
    then null
    else
      runCommand mixFodDeps.name {} ''
        mkdir -p $out
        cp -r --no-preserve=mode ${mixFodDeps}/. $out
        chmod -R u+w $out

        rm -rf $out/lib_secp256k1
        cp -r ${libSecp256k1Hex} $out/lib_secp256k1
        chmod -R u+w $out/lib_secp256k1

        rm -rf $out/elixir_make
        cp -r ${elixirMakeHex} $out/elixir_make

        rm -rf $out/lib_secp256k1/c_src/secp256k1
        mkdir -p $out/lib_secp256k1/c_src/secp256k1
        cp -r ${secp256k1Src}/. $out/lib_secp256k1/c_src/secp256k1/
        chmod -R u+w $out/lib_secp256k1/c_src/secp256k1

        # mixRelease may copy deps without preserving +x bits, so avoid relying
        # on executable mode for autogen.sh.
        substituteInPlace $out/lib_secp256k1/Makefile \
          --replace-fail "./autogen.sh" "sh ./autogen.sh"

        touch $out/lib_secp256k1/c_src/secp256k1/.fetched
      '';
in
  beamPackages.mixRelease {
    inherit pname version src;

    mixFodDeps = patchedMixFodDeps;

    mixEnv = "prod";
    removeCookie = false;
    nativeBuildInputs = [pkg-config autoconf automake libtool];
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
      description = "Parrhesia Nostr relay server";
      license = licenses.asl20;
      platforms = platforms.unix;
    };
  }
