{
  description = "Logos Qt Plugin Backend — builds Logos modules as Qt 6 plugins, and the Qt host runtime they link";

  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    # Only needed for standalone dev/testing and the convenience lib wrapper.
    # When used via logos-module-builder, logosModule is injected by the builder.
    logos-module.url = "github:logos-co/logos-module";
    nixpkgs.follows = "logos-nix/nixpkgs";
    # The transport / consumer / token layer logos-qt-host is the Qt face of.
    logos-protocol = {
      url = "github:logos-co/logos-protocol";
      inputs.logos-nix.follows = "logos-nix";
    };
    # The canonical LIDL frontend logos-qt-host-generator parses contracts with.
    logos-lidl = {
      url = "github:logos-co/logos-lidl";
      inputs.logos-nix.follows = "logos-nix";
    };
  };

  outputs = { self, nixpkgs, logos-module, logos-protocol, logos-lidl, ... }:
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

      # The C++ half of this backend: the Qt host runtime a plugin links, and
      # the generator that emits the plugin around a cdylib module's C ABI.
      #
      # These are deliberately NOT reachable from `lib` / `rawLib` /
      # `cmake-module`. A consumer that only wants the Nix build functions or
      # the CMake module (logos-module-builder's common path) must not be made
      # to realise a Qt + protocol build to get them, and under Nix's laziness
      # it is not — as long as nothing in those attributes mentions these.
      packages = forAllSystems ({ pkgs, system, ... }: {
        cmake-module = pkgs.runCommand "logos-qt-plugin-cmake" {} ''
          mkdir -p $out/share/cmake/LogosModule
          cp ${./cmake/LogosModule.cmake} $out/share/cmake/LogosModule/LogosModule.cmake
        '';

        logos-qt-host = import ./nix/qt-host.nix {
          inherit pkgs;
          src = ./.;
          protocolLib = logos-protocol.packages.${system}.logos-protocol-lib;
        };

        logos-qt-host-generator = import ./nix/qt-host-generator.nix {
          inherit pkgs;
          src = ./qt-host-generator;
          logos-lidl = logos-lidl.packages.${system}.logos-lidl;
        };

        # Unchanged: `default` is still the CMake module, so `nix build` on
        # this repo stays the cheap pure-Nix output it has always been.
        default = self.packages.${pkgs.system}.cmake-module;
      });

      # Tests
      checks = forAllSystems ({ pkgs, system, ... }: {
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
        # A failing logos-cpp-generator must fail the headers build; a module
        # with no public API must not.
        header-generator-guard = import ./tests/test-header-generator-guard.nix {
          inherit pkgs;
        };

        # The Qt host runtime compiles and installs a usable CMake package.
        qt-host = self.packages.${system}.logos-qt-host;

        # Drive the glue generator over a real contract and assert on the
        # emitted C++.
        qt-host-generator = import ./tests/test-qt-host-generator.nix {
          inherit pkgs;
          generator = self.packages.${system}.logos-qt-host-generator;
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
