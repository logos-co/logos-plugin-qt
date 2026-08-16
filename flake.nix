{
  description = "Logos Qt Plugin Backend — builds Logos modules as Qt 6 plugins, and the Qt host runtime they link";

  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    # Only needed for standalone dev/testing and the convenience lib wrapper.
    # When used via logos-module-builder, logosModule is injected by the builder.
    logos-module.url = "github:logos-co/logos-module";
    nixpkgs.follows = "logos-nix/nixpkgs";
    # The transport / consumer / token layer logos-qt-host is the Qt face of.
    #
    # Rev-pinned, not master-tracking: LogosAPI is now constructible on its own
    # token store, which needs TokenManager::forIdentity / isolateIdentity from
    # logos-protocol's feat/per-client-token-store branch. Those are NOT on
    # protocol master (still LOGOS_PROTOCOL_VERSION_MINOR 2), and the cdylib
    # glue's grant forwarding is guarded on MINOR >= 3, so a master-tracking pin
    # both fails to compile logos_api.cpp and silently drops the grant. Re-point
    # at master once that branch merges.
    logos-protocol = {
      url = "github:logos-co/logos-protocol/c8bab12834dbf92155b483546875e6078d17c74e";
      inputs.logos-nix.follows = "logos-nix";
    };
    # The canonical LIDL frontend logos-qt-host-generator parses contracts with.
    logos-lidl = {
      url = "github:logos-co/logos-lidl";
      inputs.logos-nix.follows = "logos-nix";
    };
  };

  outputs = { self, nixpkgs, logos-nix, logos-module, logos-protocol, logos-lidl, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; };
      });

      # forAllSystems plus the "x86_64-windows" pseudo-system — the same helper
      # logos-protocol and logos-lidl already build their Windows legs with, so
      # `pkgs` there is logos-nix's mingw-UCRT cross set (Qt 6.11.1) and the
      # derivation's `system` is still the BUILD platform, x86_64-linux.
      #
      # Only `packages` uses it, and only for the host runtime. `checks` cannot:
      # every check either RUNS what it built or loads a plugin, and a PE does
      # not run on the Linux builder. A cross devShell offers nothing either.
      forAllTargets = logos-nix.lib.forAllTargets;

      # Raw backend lib — no deps baked in.
      # Callers (logos-module-builder) inject logosModule per call.
      rawLib = import ./lib {
        inherit nixpkgs;
        inherit (nixpkgs) lib;
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
      # These are deliberately NOT reachable from `lib` / `rawLib`. A consumer
      # that only wants the Nix build functions (logos-module-builder's common
      # path) must not be made to realise a Qt + protocol build to get them,
      # and under Nix's laziness it is not — as long as nothing in those
      # attributes mentions these.
      #
      # There is no `cmake-module` output any more. This repo used to ship its
      # own cmake/LogosModule.cmake, and because logos-module-builder set
      # LOGOS_MODULE_BUILDER_ROOT only when a MODULE carried that file (none
      # does), every ui_qml plugin configured with THIS copy while every core
      # module configured with the builder's. Both compiled; the divergence was
      # invisible until something depended on it. The CMake module is the
      # builder's build-system contract — it reads LOGOS_API_STYLE,
      # LOGOS_MODULE_GO_STATIC_LIBS, generated_code/ — so it lives there, once.
      #
      # cmake/ came back for a narrower reason: the four LogosView*.in
      # templates. Those had the mirror-image problem — they sat next to
      # LogosModule.cmake in the builder, but this repo's rep-file-plugin
      # fixture also instantiates them and cannot reach the builder, so it kept
      # a byte-identical second copy with nothing comparing the two. See
      # cmake/README.md.
      #
      # `packages` is the ONLY output keyed by forAllTargets, so a Windows
      # consumer — logos-liblogos, and through it logos-basecamp — can name
      # `logos-plugin-qt.packages.x86_64-windows.logos-qt-host` the same way it
      # names every other system. Until it could, the whole Windows leg of
      # logos-liblogos failed at EVALUATION with `attribute 'x86_64-windows'
      # missing`: this repo took ownership of the Qt host runtime from
      # logos-qt-sdk, which HAD a Windows target, and did not bring one with it.
      packages = forAllTargets ({ pkgs, system, ... }: {
        # The LogosView*.in templates, as a nameable output. `logos_module()`
        # gets the same directory through LOGOS_VIEW_TEMPLATE_DIR; this output
        # exists so a consumer (logos-module-builder's view-interface-abi
        # check) can refer to the templates without depending on the layout of
        # this repo's source tree.
        logos-view-templates = pkgs.runCommand "logos-view-templates" { } ''
          mkdir -p $out
          cp ${./cmake}/LogosView*.in $out/
        '';

        logos-qt-host = import ./nix/qt-host.nix {
          inherit pkgs;
          src = ./.;
          protocolLib = logos-protocol.packages.${system}.logos-protocol-lib;
        };

        # `default` was the CMake module (a cheap pure-Nix copy) until that
        # output went away. The host runtime is what this repo now produces
        # that a consumer can actually build, so `nix build` on it builds that.
        #
        # `system`, not `pkgs.system`: under cross the latter is the BUILD
        # platform, so packages.x86_64-windows.default would have aliased the
        # x86_64-linux host runtime — an ELF filed under the Windows key.
        default = self.packages.${system}.logos-qt-host;
      }
      # HOST TOOL, so it exists for real systems only. The generator is EXECUTED
      # during a consumer's build to emit the plugin glue, which is why every
      # caller in logos-module-builder already reaches for it as
      # `packages.${buildSystemFor system}.logos-qt-host-generator` — on the
      # Windows target that resolves to x86_64-linux. Publishing a PE under
      # `packages.x86_64-windows` would offer the Linux builder a binary it
      # cannot run, so the attribute is simply absent there instead.
      // nixpkgs.lib.optionalAttrs (system != "x86_64-windows") {
        logos-qt-host-generator = import ./nix/qt-host-generator.nix {
          inherit pkgs;
          src = ./qt-host-generator;
          logos-lidl = logos-lidl.packages.${system}.logos-lidl;
        };
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

        # WHICH emitter buildHeaders picks, and whether it says so. A silent
        # fall back to the legacy Qt emitter is green in every other check.
        headers-emitter-routing = import ./tests/test-headers-emitter-routing.nix {
          inherit pkgs;
          inherit (rawLib) buildHeaders;
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
