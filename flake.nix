{
  description = "Logos Qt Plugin Backend — builds Logos modules as Qt 6 plugins";

  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";
    logos-module.url = "github:logos-co/logos-module";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, logos-cpp-sdk, logos-module, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; };
      });

      # Import the backend library
      backendLib = import ./lib {
        inherit nixpkgs logos-cpp-sdk logos-module;
        inherit (nixpkgs) lib;
        backendRoot = ./.;
      };
    in {
      # Export the backend library for use by logos-module-builder
      lib = backendLib;

      # Provide the cmake module as a package
      packages = forAllSystems ({ pkgs, ... }: {
        cmake-module = pkgs.runCommand "logos-qt-plugin-cmake" {} ''
          mkdir -p $out/share/cmake/LogosModule
          cp ${./cmake/LogosModule.cmake} $out/share/cmake/LogosModule/LogosModule.cmake
        '';
        default = self.packages.${pkgs.system}.cmake-module;
      });

      # Dev shell for working on the backend itself
      devShells = forAllSystems ({ pkgs, ... }:
        let
          logosSdk = logos-cpp-sdk.packages.${pkgs.system}.default;
          logosModule = logos-module.packages.${pkgs.system}.default;
        in {
          default = pkgs.mkShell {
            nativeBuildInputs = backendLib.common.commonNativeBuildInputs pkgs;
            buildInputs = backendLib.common.commonBuildInputs pkgs;
            shellHook = ''
              export LOGOS_CPP_SDK_ROOT="${logosSdk}"
              export LOGOS_MODULE_ROOT="${logosModule}"
              echo "Logos Qt Plugin Backend development environment"
            '';
          };
        }
      );
    };
}
