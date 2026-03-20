{
  lib,
  rustPlatform,
  pkgsCross,
  runCommand,
  staticX86_64Musl ? false,
  nostrBenchSrc ? ./nostr-bench,
}: let
  selectedRustPlatform =
    if staticX86_64Musl
    then pkgsCross.musl64.rustPlatform
    else rustPlatform;

  # Keep the submodule path as-is so devenv can evaluate it correctly.
  # `lib.cleanSource` treats submodule contents as untracked in this context.
  srcBase = nostrBenchSrc;

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
      version = "0.5.0-parrhesia";

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
      cargoHash = "sha256-098BUjDLiezoFXs7fF+w7NQM+DPPfHMo1HGx3nV2UZM=";
      CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
      RUSTFLAGS = "-C target-feature=+crt-static";
    }
    // lib.optionalAttrs (!staticX86_64Musl) {
      cargoHash = "sha256-x2pnxJL2nwni4cpSaUerDOfhdcTKJTyABYjPm96dAC0=";
    }
  )
