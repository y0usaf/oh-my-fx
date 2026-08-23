{
  description = "fx — AI coding agent for the terminal";

  # Pinned to the machine's nixpkgs registry rev (carries zig 0.16.0, the
  # minimum in build.zig.zon). Bump with `nix flake update`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/391b592eb44808b3bd0cb80bb71b63a5a118b8bb";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      version = builtins.head (
        builtins.match ".*pub const version = \"([^\"]+)\".*" (builtins.readFile ./src/main.zig)
      );

      # build.zig shells out to `git rev-parse` for the embedded commit; the
      # Nix sandbox has no .git, so answer it directly from the flake source.
      commit = self.rev or self.dirtyShortRev or "unknown";
      gitShim =
        pkgs:
        pkgs.writeShellScriptBin "git" ''
          if [ "$1" = rev-parse ]; then
            printf '%s\n' "${commit}"
          else
            echo "git: only 'rev-parse' is supported in the Nix build" >&2
            exit 1
          fi
        '';

      fx =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "fx";
          inherit version;

          src = self;

          nativeBuildInputs = [
            pkgs.zig.hook
            pkgs.patchelf
            (gitShim pkgs)
          ];

          # zig embeds the host loader path (/lib64/ld-linux-...), which does
          postFixup = ''
            patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" $out/bin/fx
            patchelf --set-rpath "${pkgs.stdenv.cc.libc}/lib" $out/bin/fx
          '';

          meta = with nixpkgs.lib; {
            description = "AI coding agent for the terminal";
            homepage = "https://github.com/vercel-labs/fx";
            license = licenses.asl20;
            mainProgram = "fx";
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (system: {
        default = fx nixpkgs.legacyPackages.${system};
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/fx";
        };
      });

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              zig
              bun
              tmux
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
