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
    # Master-tracking. This was rev-pinned to feat/per-client-token-store while
    # TokenManager::forIdentity / isolateIdentity — which LogosAPI needs to be
    # constructible on its own token store — lived only on that branch, with
    # protocol master at LOGOS_PROTOCOL_VERSION_MINOR 2. A master-tracking pin
    # then both failed to compile logos_api.cpp AND silently dropped the grant,
    # since the cdylib glue's forwarding is guarded on MINOR >= 3. That branch
    # has merged (logos-protocol#59): master is 0.4.0, so the guard opens.
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
      # There is no cmake/ directory any more either. It briefly came back to
      # hold the four LogosView*.in view-plugin templates, which had the
      # mirror-image problem: a byte-identical second copy of them lived here
      # with nothing comparing the two. Both copies are now ONE copy, in
      # logos-view-module — the repo that owns the ui_qml authoring flavour
      # (LogosViewModule.cmake, the view glue generator, the templates) end to
      # end. logos-module-builder inputs that repo and hands the directory to
      # every plugin build as LOGOS_VIEW_TEMPLATE_DIR, so this backend never
      # names it. What is left here is exclusively what makes a cdylib module
      # loadable by logos-module-loader-qt.
      #
      # `packages` is the ONLY output keyed by forAllTargets, so a Windows
      # consumer — logos-liblogos, and through it logos-basecamp — can name
      # `logos-plugin-qt.packages.x86_64-windows.logos-qt-host` the same way it
      # names every other system. Until it could, the whole Windows leg of
      # logos-liblogos failed at EVALUATION with `attribute 'x86_64-windows'
      # missing`: this repo took ownership of the Qt host runtime from
      # logos-qt-sdk, which HAD a Windows target, and did not bring one with it.
      packages = forAllTargets ({ pkgs, system, ... }: {
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

        # WHICH consumer surface buildPlugin picks, and that `--binding origin`
        # cannot be reached from a Qt PLUGIN's metadata. That flag turns off the
        # LpBridge token mirror; correct in a cdylib image, a silent
        # authentication failure in a plugin one.
        consumer-api-style-gate = import ./tests/test-consumer-api-style-gate.nix {
          inherit pkgs;
          inherit (rawLib) generate;
        };

        # The Qt host runtime compiles and installs a usable CMake package.
        qt-host = self.packages.${system}.logos-qt-host;

        # logos_qt_host_shared must OWN LogosAPI and BORROW everything
        # logos-protocol owns. The consumer-side symbol gate cannot see this:
        # a shared qt-host that linked the STATIC protocol archive would embed
        # its own TokenManager, and the gate would treat that library as a
        # provider and pass, with the duplicate one layer below anything it
        # inspects. One wrong word in target_link_libraries, and it builds,
        # links, installs and loads.
        shared-runtime-layering = import ./tests/test-shared-runtime-layering.nix {
          inherit pkgs;
          qtHost = self.packages.${system}.logos-qt-host;
        };

        # Drive the glue generator over a real contract and assert on the
        # emitted C++.
        qt-host-generator = import ./tests/test-qt-host-generator.nix {
          inherit pkgs;
          generator = self.packages.${system}.logos-qt-host-generator;
        };

        # The two halves of the teardown hook -- the glue that EMITS
        # aboutToUnload/unloadFinished and the host helper that REACHES them by
        # name -- both live here, and nothing in either build ties them
        # together. This does.
        unload-contract = import ./tests/test-unload-contract.nix {
          inherit pkgs;
          generator = self.packages.${system}.logos-qt-host-generator;
          src = ./.;
        };

        # WHO IS CALLING, the same shape one layer over: LogosAPI declares the
        # invokable, logos_provider_object.cpp reaches it BY STRING through the
        # meta-object, and the glue this repo emits pushes the answer across the
        # module-impl C ABI. Rename the invokable and nothing fails to compile,
        # nothing fails to load, and every handler is told "unknown" -- which is
        # also the correct answer in several real cases, so there is no anomaly
        # to notice.
        caller-contract = import ./tests/test-caller-contract.nix {
          inherit pkgs;
          generator = self.packages.${system}.logos-qt-host-generator;
          src = ./.;
        };

        # The host half of the caller, RUN rather than grepped: a real LogosAPI,
        # a real CallerScope, reached the way the glue reaches it. Also the only
        # oracle in this repo for the rule the multi emission is built around --
        # a scope open on one thread is invisible on another.
        caller-invokable = import ./tests/test-caller-invokable.nix {
          inherit pkgs;
          qtHost = self.packages.${system}.logos-qt-host;
        };

        # Every other check greps the emitted glue as TEXT. This one COMPILES
        # it, against the headers this repo installs, with the module-impl C ABI
        # stubbed. The blind spot it closes is on the record: a multi capture
        # list that omitted a local its body named was invisible to every grep
        # here and surfaced as a build failure downstream.
        glue-compiles = import ./tests/test-glue-compiles.nix {
          inherit pkgs;
          generator = self.packages.${system}.logos-qt-host-generator;
          qtHost = self.packages.${system}.logos-qt-host;
          # The protocol SOURCE, not the built library: logos_async_dispatch.h
          # is not in logos-protocol's installed header set, and every
          # concurrency:"multi" glue includes it. logos-module-builder resolves
          # it the same way (LogosModule.cmake, ${LOGOS_PROTOCOL_ROOT}/cpp).
          protocolSrc = logos-protocol;
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
