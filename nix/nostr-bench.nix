{
  lib,
  fetchFromGitHub,
  rustPlatform,
}:
rustPlatform.buildRustPackage rec {
  pname = "nostr-bench";
  version = "0.4.0";

  src = fetchFromGitHub {
    owner = "rnostr";
    repo = pname;
    rev = "d3ab701512b7c871707b209ef3f934936e407963";
    hash = "sha256-F2qg1veO1iNlVUKf1b/MV+vexiy4Tt+w2aikDDbp7tU=";
  };

  cargoHash = "sha256-mh9UdYhZl6JVJEeDFnY5BjfcK+PrWBBEn1Qh7/ZX17k=";

  doCheck = false;

  meta = with lib; {
    description = "Nostr relay benchmarking tool";
    homepage = "https://github.com/rnostr/nostr-bench";
    license = licenses.mit;
    mainProgram = "nostr-bench";
    platforms = platforms.unix;
  };
}
