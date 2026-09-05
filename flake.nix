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
      gemset = import ./gemset.nix;

      packageFor =
        pkgs:
        let
          runtimeNames = pkgs.lib.converge (
            names:
            pkgs.lib.unique (names ++ pkgs.lib.concatMap (name: gemset.${name}.dependencies or [ ]) names)
          ) [ "nokizaru" ];
          runtimeGemset = pkgs.lib.getAttrs runtimeNames gemset;
          source = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./LICENSE
              ./README.md
              ./bin
              ./conf
              ./lib
              ./man
              ./nokizaru.gemspec
              ./wordlists
            ];
          };
          environment = pkgs.bundlerEnv {
            pname = "nokizaru";
            ruby = pkgs.ruby_4_0;
            gemdir = source;
            gemfile = ./Gemfile;
            lockfile = ./Gemfile.nix.lock;
            gemset = pkgs.lib.recursiveUpdate runtimeGemset { nokizaru.source.path = source; };
            groups = [ "default" ];
          };
        in
        pkgs.runCommand "nokizaru-${gemset.nokizaru.version}"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            meta = {
              description = "Fast modular web recon CLI for bug bounty workflows";
              homepage = "https://github.com/hakkuri01/nokizaru";
              license = pkgs.lib.licenses.mit;
              mainProgram = "nokizaru";
              platforms = systems;
            };
            passthru = { inherit environment source; };
          }
          ''
            mkdir -p $out/bin $out/share/man/man1
            makeWrapper ${environment.wrappedRuby}/bin/ruby $out/bin/nokizaru \
              --add-flags ${source}/bin/nokizaru \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.file ]} \
              --set-default LANG C.UTF-8 \
              --set-default SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            cp ${source}/man/nokizaru.1 $out/share/man/man1/
          '';

      developmentFor =
        pkgs:
        let
          source = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./bin
              ./conf
              ./lib
              ./nokizaru.gemspec
              ./test
              ./wordlists
            ];
          };
        in
        pkgs.bundlerEnv {
          pname = "nokizaru";
          ruby = pkgs.ruby_4_0;
          gemdir = source;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.nix.lock;
          gemset = pkgs.lib.recursiveUpdate gemset { nokizaru.source.path = source; };
          groups = [
            "default"
            "development"
            "test"
          ];
        };
    in
    {
      packages = forAllSystems (system: rec {
        nokizaru = packageFor (pkgsFor system);
        default = nokizaru;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          development = developmentFor pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              development.wrappedRuby
              pkgs.bundix
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          package = self.packages.${system}.nokizaru;
          development = developmentFor pkgs;
        in
        {
          quality =
            pkgs.runCommand "nokizaru-quality"
              {
                nativeBuildInputs = [ development.wrappedRuby ];
              }
              ''
                cd ${development.confFiles}
                export HOME="$TMPDIR/home"
                export LANG=C.UTF-8
                export XDG_CONFIG_HOME="$TMPDIR/config"
                export XDG_DATA_HOME="$TMPDIR/data"
                mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
                bundle exec ruby -rbundler -e '
                  normal, nix = ARGV.map do |path|
                    parser = Bundler::LockfileParser.new(Bundler.read_file(path))
                    [parser.specs.to_h { |spec| [spec.name, spec.version.to_s] }, parser.platforms.map(&:to_s)]
                  end
                  mismatches = normal[0].filter_map do |name, version|
                    "#{name}: #{version} != #{nix[0][name]}" unless nix[0][name] == version
                  end
                  abort mismatches.join("\n") unless mismatches.empty?
                  abort "Nix lock must target only ruby" unless nix[1] == ["ruby"]
                ' ${./Gemfile.lock} ${./Gemfile.nix.lock}
                bundle exec ruby test/coverage_check.rb
                bundle exec rubocop --config ${./.rubocop.yml}
                touch "$out"
              '';

          smoke =
            pkgs.runCommand "nokizaru-smoke"
              {
                nativeBuildInputs = [ package ];
              }
              ''
                export HOME="$TMPDIR/home"
                export XDG_CONFIG_HOME="$TMPDIR/config"
                export XDG_DATA_HOME="$TMPDIR/data"
                mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

                nokizaru --version > "$TMPDIR/version" 2> "$TMPDIR/version.err"
                grep -F "2.4.11" "$TMPDIR/version"
                test ! -s "$TMPDIR/version.err"
                nokizaru --help | grep -F "Nokizaru - Recon Refined"
                test -f ${package}/share/man/man1/nokizaru.1

                set +e
                nokizaru -nb > "$TMPDIR/initialize.log" 2>&1
                status=$?
                set -e
                test "$status" -eq 1
                test -f "$XDG_CONFIG_HOME/nokizaru/config.json"
                test -f "$XDG_DATA_HOME/nokizaru/keys.json"
                test "$(stat -c %a "$XDG_DATA_HOME/nokizaru/keys.json")" = 600

                test -f ${package.source}/wordlists/raft_small-dir_2k.txt
                test -f ${package.source}/wordlists/raft_med-dir_5k.txt
                test -f ${package.source}/wordlists/raft_big-dir_10k.txt
                touch "$out"
              '';
        }
      );
    };
}
