{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }: {
    packages = nixpkgs.lib.genAttrs
      [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ]
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = pkgs.zig_0_17;
          version =
            let
              line = pkgs.lib.findFirst (pkgs.lib.hasPrefix "pub const version = ") null
                (pkgs.lib.splitString "\n" (builtins.readFile ./src/main.zig));
            in
            pkgs.lib.removeSuffix "\";" (pkgs.lib.removePrefix "pub const version = \"" line);
          src = pkgs.lib.cleanSource ./.;
          deps = zig.fetchDeps {
            pname = "omfx";
            inherit version src;
            hash = "sha256-/TRj0ikzzg7O+NU5hivOOM7tHT9QMDexjM5e2nrt7Uc=";
          };
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "omfx";
            inherit version src;
            nativeBuildInputs = [ pkgs.makeBinaryWrapper zig.hook ];
            postConfigure = ''
              ln -s ${deps} "$ZIG_GLOBAL_CACHE_DIR/p"
            '';
            postInstall = ''
              mv "$out/bin/fx" "$out/bin/omfx"
              install -Dm444 LICENSE "$out/share/licenses/fx/LICENSE"
              install -Dm444 THIRD_PARTY_NOTICES.md "$out/share/licenses/fx/THIRD_PARTY_NOTICES.md"
            '';
            postFixup = "wrapProgram $out/bin/omfx --set-default FX_AUTO_UPGRADE 0";
            meta = {
              description = "Tiny, open, embeddable, native coding agent";
              homepage = "https://fx.sh";
              license = pkgs.lib.licenses.asl20;
              mainProgram = "omfx";
              platforms = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
            };
          };
        });
  };
}
