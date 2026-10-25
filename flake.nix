{
  description = "Nokizaru web reconnaissance scanner";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      version = builtins.head (
        builtins.match ".*\nversion: ([^\n]+)\n.*" (builtins.readFile ./shard.yml)
      );
      amebaRev = builtins.head (
        builtins.match ".*git.commit.([0-9a-f]+).*" (builtins.readFile ./shard.lock)
      );
      sourceFor =
        pkgs:
        pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./src
            ./spec
            ./data
            ./shard.yml
            ./shard.lock
            ./justfile
            ./.ameba.yml
            ./LICENSE
          ];
        };
      amebaFor =
        pkgs:
        pkgs.crystal.buildCrystalPackage {
          pname = "ameba";
          version = "1.7.0-${builtins.substring 0 7 amebaRev}";
          src = pkgs.fetchFromGitHub {
            owner = "crystal-ameba";
            repo = "ameba";
            rev = amebaRev;
            hash = "sha256-P2XirYKxq3Y6cjK5O013fPzag9uWR9jdetlLxX70ji4=";
          };
          format = "crystal";
          crystalBinaries.ameba.src = "src/cli.cr";
          nativeBuildInputs = [ pkgs.shards ];
          doCheck = false;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        rec {
          nokizaru = pkgs.crystal.buildCrystalPackage {
            pname = "nokizaru";
            inherit version;
            src = sourceFor pkgs;
            format = "crystal";
            crystalBinaries.nokizaru.src = "src/nokizaru.cr";
            doCheck = false;
            meta = {
              description = "Fast modular web reconnaissance CLI";
              homepage = "https://github.com/hakkuri01/nokizaru";
              license = pkgs.lib.licenses.mit;
              mainProgram = "nokizaru";
              platforms = systems;
            };
          };
          default = nokizaru;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ameba = amebaFor pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.crystal
              pkgs.shards
              pkgs.just
              pkgs.openssl
              ameba
            ];
            shellHook = ''
              mkdir -p bin
              install -m755 ${ameba}/bin/ameba bin/ameba
            '';
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          package = self.packages.${system}.nokizaru;
          ameba = amebaFor pkgs;
        in
        {
          quality = pkgs.stdenv.mkDerivation {
            pname = "nokizaru-quality";
            inherit version;
            src = sourceFor pkgs;
            nativeBuildInputs = [
              pkgs.crystal
              pkgs.just
              pkgs.openssl
            ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR/home"
              export CRYSTAL_CACHE_DIR="$TMPDIR/crystal-cache"
              export CRYSTAL_WORKERS="$NIX_BUILD_CORES"
              mkdir -p "$HOME" bin
              install -m755 ${ameba}/bin/ameba bin/ameba
              just verify
              runHook postBuild
            '';
            installPhase = "touch $out";
          };
          release = package;
          smoke = pkgs.runCommand "nokizaru-smoke" { } ''
            export HOME="$TMPDIR/home"
            export XDG_CONFIG_HOME="$TMPDIR/config"
            export XDG_DATA_HOME="$TMPDIR/data"
            mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
            ${package}/bin/nokizaru --version > version 2> version.err
            grep -Fx 'nokizaru ${version}' version
            test ! -s version.err
            ${package}/bin/nokizaru --help | grep -F 'Nokizaru - Recon Refined'
            set +e
            ${package}/bin/nokizaru -nb > initialize.log 2>&1
            status=$?
            set -e
            test "$status" -eq 1
            grep -F 'No Modules Specified!' initialize.log
            printf 'nix-smoke-test\n' | ${package}/bin/nokizaru -k shodan > key.log
            if grep -qF 'nix-smoke-test' key.log; then exit 1; fi
            test -f "$XDG_CONFIG_HOME/nokizaru/config.json"
            test -f "$XDG_DATA_HOME/nokizaru/keys.json"
            grep -qF 'nix-smoke-test' "$XDG_DATA_HOME/nokizaru/keys.json"
            test "$(stat -c %a "$XDG_DATA_HOME/nokizaru/keys.json")" = 600
            touch "$out"
          '';
        }
      );
    };
}
