{
  description = "Logos Qt Plugin Backend — builds Logos modules as Qt 6 plugins";

  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    # Only needed for standalone dev/testing and the convenience lib wrapper.
    # When used via logos-module-builder, logosModule is injected by the builder.
    logos-module.url = "github:logos-co/logos-module";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, logos-module, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; };
      });

      # Raw backend lib — no deps baked in.
      # Callers (logos-module-builder) inject logosModule per call.
      rawLib = import ./lib {
        inherit nixpkgs;
        inherit (nixpkgs) lib;
        backendRoot = ./.;
      };

      # Convenience wrapper that pre-fills logosModule from this flake's inputs.
      # Used for standalone dev/testing.
      wrappedLib = rawLib // {
        buildPlugin = args: rawLib.buildPlugin (args // {
          logosModule = logos-module.packages.${args.pkgs.system}.default;
        });
        buildHeaders = args: rawLib.buildHeaders args;
        devShellInputs = pkgs: rawLib.devShellInputs pkgs {
          logosModule = logos-module.packages.${pkgs.system}.default;
        };
      };

    in {
      # Default export: wrapped with logosModule pre-filled
      lib = wrappedLib;

      # Raw export: no deps — for use by logos-module-builder
      rawLib = rawLib;

      # Provide the cmake module as a package
      packages = forAllSystems ({ pkgs, ... }: {
        cmake-module = pkgs.runCommand "logos-qt-plugin-cmake" {} ''
          mkdir -p $out/share/cmake/LogosModule
          cp ${./cmake/LogosModule.cmake} $out/share/cmake/LogosModule/LogosModule.cmake
        '';
        default = self.packages.${pkgs.system}.cmake-module;
      });

      # Tests
      checks = forAllSystems ({ pkgs, ... }: {
        # Build a vanilla Qt plugin with no Logos SDK deps
        vanilla-plugin = import ./tests/test-vanilla-plugin.nix {
          inherit pkgs;
          backendCommon = rawLib.common;
        };
        # Build a replica factory plugin from a .rep file
        rep-file-plugin = import ./tests/test-rep-file-plugin.nix {
          inherit pkgs;
          backendCommon = rawLib.common;
        };
      });

      # Dev shell for working on the backend itself
      devShells = forAllSystems ({ pkgs, ... }:
        let
          shell = wrappedLib.devShellInputs pkgs;
        in {
          default = pkgs.mkShell {
            nativeBuildInputs = shell.nativeBuildInputs;
            buildInputs = shell.buildInputs;
            shellHook = ''
              ${shell.shellHook}
              echo "Logos Qt Plugin Backend development environment"
            '';
          };
        }
      );
    };
}
