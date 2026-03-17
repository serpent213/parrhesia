{
  description = "Parrhesia Nostr relay";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];

    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    formatter = forAllSystems (system: (import nixpkgs {inherit system;}).alejandra);

    packages = forAllSystems (
      system: let
        pkgs = import nixpkgs {inherit system;};
        lib = pkgs.lib;
        parrhesia = pkgs.callPackage ./default.nix {};
      in
        {
          default = parrhesia;
          inherit parrhesia;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          dockerImage = pkgs.dockerTools.buildLayeredImage {
            name = "parrhesia";
            tag = "latest";

            contents = [
              parrhesia
              pkgs.bash
              pkgs.cacert
              pkgs.coreutils
              pkgs.fakeNss
            ];

            extraCommands = ''
              mkdir -p tmp
              chmod 1777 tmp
            '';

            config = {
              Entrypoint = ["${parrhesia}/bin/parrhesia"];
              Cmd = ["start"];
              ExposedPorts = {
                "4413/tcp" = {};
              };
              WorkingDir = "/";
              User = "65534:65534";
              Env = [
                "HOME=/tmp"
                "LANG=C.UTF-8"
                "LC_ALL=C.UTF-8"
                "MIX_ENV=prod"
                "PORT=4413"
                "RELEASE_DISTRIBUTION=none"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              ];
            };
          };
        }
    );
  };
}
