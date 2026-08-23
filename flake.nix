{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      version =
        let
          line = nixpkgs.lib.findFirst (nixpkgs.lib.hasPrefix "pub const version = ") null
            (nixpkgs.lib.splitString "\n" (builtins.readFile ./src/main.zig));
        in
        nixpkgs.lib.removeSuffix "\";" (nixpkgs.lib.removePrefix "pub const version = \"" line);
    in
    {
      packages = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            common = {
              inherit version;
              src = ./.;
              nativeBuildInputs = [ pkgs.zig ];
            };
          in
          {
            default = pkgs.stdenv.mkDerivation (common // {
              pname = "omfx";
              nativeBuildInputs = common.nativeBuildInputs ++ [ pkgs.makeBinaryWrapper ];
              postInstall = ''
                rm -f "$out/bin/fx"
                install -Dm444 LICENSE "$out/share/licenses/omfx/LICENSE"
                install -Dm444 THIRD_PARTY_NOTICES.md "$out/share/licenses/omfx/THIRD_PARTY_NOTICES.md"
              '';
              postFixup = "wrapProgram $out/bin/omfx --set-default FX_AUTO_UPGRADE 0";
              meta = {
                description = "Tiny, open, embeddable, native coding agent (oh-my-fx fork)";
                homepage = "https://fx.sh";
                license = pkgs.lib.licenses.asl20;
                mainProgram = "omfx";
                platforms = systems;
              };
            });

            benchmark = pkgs.stdenv.mkDerivation (common // {
              pname = "fx-mux-benchmark";
              buildPhase = ''
                runHook preBuild
                zig build bench-mux -Doptimize=ReleaseSafe --prefix "$out"
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                install -Dm444 LICENSE "$out/share/licenses/fx-mux-benchmark/LICENSE"
                install -Dm444 THIRD_PARTY_NOTICES.md "$out/share/licenses/fx-mux-benchmark/THIRD_PARTY_NOTICES.md"
                runHook postInstall
              '';
              meta = {
                description = "Deterministic fx mux performance benchmark";
                license = pkgs.lib.licenses.asl20;
                mainProgram = "mux-bench";
                platforms = systems;
              };
            });
          });

      apps = forAllSystems (system: {
        benchmark = {
          type = "app";
          program = "${self.packages.${system}.benchmark}/bin/mux-bench";
        };
      });
    };
}
