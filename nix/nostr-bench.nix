{
  lib,
  fetchFromGitHub,
  rustPlatform,
  pkgsCross,
  runCommand,
  staticX86_64Musl ? false,
}: let
  selectedRustPlatform =
    if staticX86_64Musl
    then pkgsCross.musl64.rustPlatform
    else rustPlatform;

  srcBase = fetchFromGitHub {
    owner = "rnostr";
    repo = "nostr-bench";
    rev = "d3ab701512b7c871707b209ef3f934936e407963";
    hash = "sha256-F2qg1veO1iNlVUKf1b/MV+vexiy4Tt+w2aikDDbp7tU=";
  };

  src =
    if staticX86_64Musl
    then
      runCommand "nostr-bench-static-src" {} ''
        cp -r ${srcBase} $out
        chmod -R u+w $out
        cp ${./nostr-bench-static.Cargo.lock} $out/Cargo.lock
      ''
    else srcBase;
in
  selectedRustPlatform.buildRustPackage (
    {
      pname = "nostr-bench";
      version = "0.4.0";

      inherit src;

      doCheck = false;

      meta = with lib; {
        description = "Nostr relay benchmarking tool";
        homepage = "https://github.com/rnostr/nostr-bench";
        license = licenses.mit;
        mainProgram = "nostr-bench";
        platforms = platforms.unix;
      };
    }
    // lib.optionalAttrs staticX86_64Musl {
      cargoHash = "sha256-aL8XSBJ8sHl7CGh9SkOoI+WlAHKrdij2DfvZAWIKgKY=";
      CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
      RUSTFLAGS = "-C target-feature=+crt-static";
    }
    // lib.optionalAttrs (!staticX86_64Musl) {
      cargoHash = "sha256-mh9UdYhZl6JVJEeDFnY5BjfcK+PrWBBEn1Qh7/ZX17k=";
    }
  )
