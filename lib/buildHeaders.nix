# Builder for module headers — the Qt-typed / lp-typed CLIENT WRAPPER a
# consumer of this module includes (`<name>_api.{h,cpp}`).
#
# Three code paths. Which one runs is decided at EVAL time and echoed at the
# top of the build log (`buildHeaders: emitter=…`), because the failure mode
# this file is built to avoid is a SILENT fallback: everything stays green
# while the wrapper is still coming from the emitter we are migrating off.
#
#   qt-consumer — `logos-qt-generator --backend consumer`, driven by the
#                 module's LIDL CONTRACT. A veneer over the same logos-protocol
#                 C ABI the lp wrappers use, so there is one transport, one
#                 codec and one Qt type mapper under both consumer surfaces.
#                 Needs no plugin, so it works natively AND under cross.
#
#   legacy-qt   — logos-cpp-generator's `--api-style qt` emitter. Reached ONLY
#                 by a module that publishes no contract (a handcrafted Qt
#                 plugin), where the compiled plugin's QMetaObject is the only
#                 description of its API that exists. Native introspection
#                 (`<plugin.so> --module-only`); a hard error under cross,
#                 which cannot dlopen the binary it just produced.
#
#   lp          — logos-cpp-generator's `--api-style lp` emitter, verbatim as
#                 before. This is NOT the legacy Qt consumer emitter and
#                 logos-qt-generator has no lp backend, so it is out of scope
#                 for this migration.
#
# The cross paths deliberately do NOT fail soft. The native legacy path ends in
# `|| { ... touch .no-api; }`, which is survivable there because the plugin was
# genuinely loadable and an empty API means the module really has none. Under
# cross the same fallback would turn "we cannot introspect a PE" into a green
# build that silently ships a module with no typed API, so every failure mode
# on a cross path is a hard `exit 1` naming the module.
{ lib, common }:

let
  # `build`'s own `lib` argument is the built PLUGIN derivation, which shadows
  # nixpkgs' lib inside its body. Keep a handle on the real one out here.
  nixLib = lib;
in
{
  build = {
    pkgs,
    src,
    config,
    commonArgs,
    logosSdk,
    lib,  # The built module library (plugin derivation)
    # API style for the generated `<Module>` client wrapper:
    #   "qt" — QString / QStringList / QVariantList / QVariantMap / int / LogosResult
    #   "lp" — std-typed and Qt-FREE: the wrapper talks the logos-protocol C ABI
    #          (lp_*) directly, so a core universal / cdylib consumer can include
    #          it from a translation unit that never sees Qt.
    # Each module is built once per style so consumers can pick the variant
    # matching their own --api-style without re-running the codegen at consume
    # time — the variants are independent derivations and Nix only realises the
    # ones a downstream actually depends on.
    apiStyle ? "qt",
    # Absolute path (store path) of this module's LIDL contract, or null when
    # the module publishes none. This is the PRIMARY input for the qt surface:
    # a module that ships a contract never gets introspected. Only a module
    # with no contract falls back to reading its compiled plugin.
    contractLidl ? null,
    # logos-qt-generator, build-platform typed. Supplied by the caller
    # (logos-module-builder) exactly like logosSdk — this backend knows about
    # neither SDK. Null means the caller predates contract-driven qt wrappers;
    # see `emitter` below, which then names that as the reason it fell back.
    qtGenerator ? null,
  }:
  let
    pluginFilename = common.getPluginFilename pkgs config.name;
    libExt = common.getLibExtension pkgs;

    # A Linux (or Darwin) builder cannot dlopen a Windows PE, so plugin
    # introspection is structurally impossible here.
    crossNoIntrospect = pkgs.stdenv.hostPlatform.isWindows;

    # ── Emitter selection ──────────────────────────────────────────────────
    # Contract-first: a module that describes itself in LIDL is generated from
    # that description, on every platform. Introspection is what is left over
    # when no description exists.
    #
    # `contractLidl` is only ever a `.lidl` path today (mkLogosModule derives it
    # from the module's published `lidl` output or a committed src/<name>.lidl),
    # but the suffix is checked rather than assumed: --backend consumer also
    # accepts `--from-header`, and silently handing it a header as if it were
    # LIDL would fail deep inside the generator instead of here.
    contractIsLidl = contractLidl != null && nixLib.hasSuffix ".lidl" contractLidl;
    isQt = apiStyle == "qt";

    useQtConsumer = isQt && contractIsLidl && qtGenerator != null;

    # A single string, echoed into the build log and used nowhere else. Every
    # branch that does NOT reach the qt-generator says why, by name, so a
    # migration that quietly stops taking effect is visible in the log of the
    # very build that regressed rather than only in a store-path diff.
    emitter =
      if useQtConsumer then
        "qt-consumer  (logos-qt-generator --backend consumer; '${config.name}' publishes a LIDL contract)"
      else if !isQt then
        "lp           (logos-cpp-generator --api-style lp; not the legacy Qt emitter, and logos-qt-generator has no lp backend)"
      else if !contractIsLidl then
        "legacy-qt    (logos-cpp-generator --api-style qt; '${config.name}' publishes NO LIDL contract, so its compiled plugin is the only description of its API)"
      else
        "legacy-qt    (logos-cpp-generator --api-style qt; REGRESSION: '${config.name}' HAS a contract but the caller passed no qtGenerator — logos-module-builder is stale)";

    # Loud, and on stderr, for the one branch that is a defect rather than a
    # design: the contract is right there and we are not using it.
    staleCallerWarning = nixLib.optionalString (isQt && contractIsLidl && qtGenerator == null) ''
      echo "WARNING: buildHeaders is falling back to the legacy Qt consumer emitter for '${config.name}'" >&2
      echo "         even though it publishes a LIDL contract (${contractLidl})." >&2
      echo "         Cause: the caller passed no \`qtGenerator\` to the qt backend's buildHeaders." >&2
      echo "         Fix: update logos-module-builder — mkLogosModule must pass" >&2
      echo "         \`qtGenerator = logosQtGenerator;\` alongside \`contractLidl\`." >&2
    '';

    # Announce the choice before doing anything, so the log names the emitter
    # even when the run that follows fails.
    emitterBanner = ''
      echo "buildHeaders: emitter=${emitter}"
      echo "buildHeaders:   module=${config.name} api-style=${apiStyle} host=${pkgs.stdenv.hostPlatform.config}"
      echo "buildHeaders:   contract=${if contractLidl == null then "<none>" else contractLidl}"
      ${staleCallerWarning}
    '';

    # ── qt-consumer: contract-driven, no plugin ────────────────────────────
    # `--bind static` bakes the target module name into the class, which is what
    # a concrete `dependencies` entry (`modules().<dep>`) needs and is exactly
    # the shape the legacy emitter produced from introspection — the ctor is
    # `explicit <Class>(LogosAPI*)` in both.
    #
    # `--class` is deliberately NOT passed: the backend defaults it to
    # lidlToPascalCase(--module), character-for-character the toPascalCase the
    # umbrella uses to spell the member's TYPE (both are the same routine in
    # logos-cpp-sdk's shared share/lidl-frontend). Spelling it here would create
    # a second place for the two to drift apart. Same reasoning, same call
    # shape, as buildPlugin.nix's consume-time wrappers.
    #
    # No `--events-from`: the contract already carries the `logos_events:`
    # blocks, so the typed `on<Event>(callback)` accessors come out of the same
    # single input as the methods. (The legacy native path needed the sidecar
    # because a QMetaObject does not describe events.)
    qtConsumerBuildPhase = ''
      runHook preBuild

      mkdir -p ./generated_headers
      ${emitterBanner}

      logos-qt-generator --lidl ${nixLib.escapeShellArg contractLidl} \
        --backend consumer --module ${nixLib.escapeShellArg config.name} \
        --bind static \
        --output-dir ./generated_headers

      if [ ! -s "./generated_headers/${config.name}_api.h" ] || \
         [ ! -s "./generated_headers/${config.name}_api.cpp" ]; then
        echo "Error: logos-qt-generator emitted no consumer wrapper for '${config.name}'." >&2
        echo "  contract: ${toString contractLidl}" >&2
        ls -la ./generated_headers >&2 || true
        exit 1
      fi

      # Positive control. A store-path change proves nothing about WHICH
      # emitter ran, and the two wrappers agree on their whole public surface —
      # the only textual tell is the private transport member. `LpBridge` is
      # emitted by lidlMakeQtConsumerHeader and by nothing in the legacy
      # emitter, so this assertion fails the build if a future refactor ever
      # routes this path back through logos-cpp-generator without saying so.
      if ! grep -q 'logos::qt::LpBridge' "./generated_headers/${config.name}_api.h"; then
        echo "Error: the wrapper emitted for '${config.name}' does not name logos::qt::LpBridge." >&2
        echo "  This derivation claims emitter=qt-consumer, but the output looks like" >&2
        echo "  the legacy logos-cpp-generator Qt emitter. Refusing to ship it under" >&2
        echo "  the wrong provenance." >&2
        exit 1
      fi

      runHook postBuild
    '';

    # ── cross + legacy: LIDL-driven generation through logos-cpp-generator ──
    # Only reachable now for `--api-style lp` (the qt surface goes to the
    # consumer backend above, contract or not — and with no contract it cannot
    # be built under cross at all). `--dep <name>=<file.lidl>` is the
    # generator's contract->consumer backend, and it only runs inside the
    # `--general-only` branch, hence the metadata stub: `--general-only` needs a
    # metadata.json, but the only thing it takes from it is the umbrella
    # (logos_sdk.{h,cpp}), which the native --module-only path does not emit and
    # which we therefore delete again below.
    crossBuildPhase = ''
      runHook preBuild

      mkdir -p ./generated_headers
      ${emitterBanner}

    '' + (if !contractIsLidl then ''
      echo "Error: cannot generate typed headers for module '${config.name}' when cross-compiling to ${pkgs.stdenv.hostPlatform.config}." >&2
      echo "" >&2
      echo "  Native builds recover a module's typed API by loading the compiled" >&2
      echo "  plugin and reading its Qt metaobject. This builder cannot load a" >&2
      echo "  ${pkgs.stdenv.hostPlatform.config} binary, so the API must come from the module's" >&2
      echo "  LIDL contract instead — and '${config.name}' publishes none." >&2
      echo "" >&2
      echo "  Fix one of:" >&2
      echo "    * migrate '${config.name}' to interface: \"universal\" (its contract is" >&2
      echo "      then derived from the impl header automatically), or" >&2
      echo "    * commit a contract at src/${config.name}.lidl in the module repo." >&2
      echo "" >&2
      echo "  Refusing to emit an empty API: a module with no typed surface would" >&2
      echo "  build green and then be un-callable from every consumer." >&2
      exit 1
    '' else ''
      cat > ./cross_headers_metadata.json <<'EOF'
      { "name": "${config.name}", "version": "${config.version}", "dependencies": [] }
      EOF

      echo "Cross build (${pkgs.stdenv.hostPlatform.config}): generating ${apiStyle}-typed headers for '${config.name}' from LIDL contract"
      echo "  contract: ${contractLidl}"

      # No `|| touch .no-api` here — see the header comment. A generator failure
      # is fatal.
      logos-cpp-generator --metadata ./cross_headers_metadata.json \
        --output-dir ./generated_headers \
        --general-only --api-style ${apiStyle} \
        --dep ${config.name}=${contractLidl}

      # The umbrella is a --general-only artifact; the native --module-only path
      # never emits it and installPhase copies every .h/.cpp, so drop it to keep
      # the two outputs shaped the same.
      rm -f ./generated_headers/logos_sdk.h ./generated_headers/logos_sdk.cpp

      # `--dep` is a silent no-op if the generator ever stops honouring it (it is
      # only read inside the --general-only branch). Assert the wrapper actually
      # exists rather than letting an empty include/ ship.
      if [ ! -f "./generated_headers/${config.name}_api.h" ]; then
        echo "Error: LIDL-driven generation produced no ${config.name}_api.h for module '${config.name}'." >&2
        echo "Contents of ./generated_headers:" >&2
        ls -la ./generated_headers >&2
        exit 1
      fi
    '') + ''

      runHook postBuild
    '';

    # ── native + legacy: introspect the compiled plugin ────────────────────
    nativeLegacyBuildPhase = ''
      runHook preBuild

      # Create output directory for generated headers
      mkdir -p ./generated_headers
      ${emitterBanner}

      # Determine platform-specific library extension and find plugin
      PLUGIN_FILE=""
      if [ -f "${lib}/lib/${config.name}_plugin.dylib" ]; then
        PLUGIN_FILE="${lib}/lib/${config.name}_plugin.dylib"
      elif [ -f "${lib}/lib/${config.name}_plugin.so" ]; then
        PLUGIN_FILE="${lib}/lib/${config.name}_plugin.so"
      else
        echo "Error: No ${config.name}_plugin library file found in ${lib}/lib/"
        echo "Contents of ${lib}/lib/:"
        ls -la "${lib}/lib/" 2>/dev/null || echo "Directory does not exist"
        exit 1
      fi

      # Set library path so the plugin can find dependencies when loaded
      ${if pkgs.stdenv.hostPlatform.isDarwin then ''
        export DYLD_LIBRARY_PATH="${lib}/lib:''${DYLD_LIBRARY_PATH:-}"
      '' else ''
        export LD_LIBRARY_PATH="${lib}/lib:''${LD_LIBRARY_PATH:-}"
      ''}

      # Run logos-cpp-generator on the built plugin with --module-only flag
      echo "Running logos-cpp-generator on $PLUGIN_FILE"
      echo "Library path: ${lib}/lib"
      ls -la "${lib}/lib" 2>/dev/null || echo "No lib directory"

      # --events-from: typed `on<EventName>(callback)` accessors on the
      # generated wrapper come from the dep's LIDL sidecar (emitted by
      # buildPlugin.nix's installPhase from `logos_events:` blocks in
      # the impl header). Absent for handcrafted Qt modules — that's
      # fine, we skip the flag in that case. (A module that ships this
      # sidecar publishes a contract and therefore does not reach this
      # path for the qt surface at all; it still does for lp.)
      EVENTS_SIDECAR=""
      if [ -f "${lib}/share/logos/${config.name}.lidl" ]; then
        EVENTS_SIDECAR="${lib}/share/logos/${config.name}.lidl"
        echo "Using events sidecar: $EVENTS_SIDECAR"
      fi

      # The generator's exit status is FATAL — see the header comment of
      # generate-module-headers.sh for why "the module has no public API" is
      # not a reason to swallow it (that case exits 0 and generates a wrapper
      # with zero methods). The script also refuses a zero exit that produced
      # no wrapper, so this derivation can never install an empty include/.
      bash ${./generate-module-headers.sh} \
        "$PLUGIN_FILE" ./generated_headers "${apiStyle}" "$EVENTS_SIDECAR"

      runHook postBuild
    '';

  in pkgs.stdenv.mkDerivation {
    pname = "${commonArgs.pname}-headers-${apiStyle}";
    version = commonArgs.version;

    inherit src;
    inherit (commonArgs) meta;

    # Exactly the tool the selected emitter needs, and nothing else.
    #
    # qt-consumer needs logos-qt-generator and NOT the SDK — it also never
    # touches `${lib}`, so a contract-first module's headers no longer force a
    # plugin compile.
    #
    # The legacy/lp paths keep `logosSdk` alone and run the same generator
    # invocation as before, so a module that still takes them installs a
    # byte-identical include/. (The derivation hash does move — every path now
    # echoes its emitter — so compare the OUTPUT, not the store path.)
    #
    # logosSdk's `propagatedBuildInputs` only ships OpenSSL / Boost /
    # nlohmann_json — Qt is intentionally excluded (see
    # logos-cpp-sdk/nix/default.nix) so qtbase isn't dragged into our
    # closure here, qtPreHook doesn't fire, and we don't need
    # `wrapQtAppsNoGuiHook` either: the generator binary at
    # `${logosSdk}/bin/logos-cpp-generator` was already wrapped at
    # SDK build time. `dontWrapQtApps = true` is kept as a belt-and-
    # suspenders no-op in case a future change re-introduces qtbase.
    nativeBuildInputs = if useQtConsumer then [ qtGenerator ] else [ logosSdk ];

    dontWrapQtApps = true;

    # No configure phase needed
    dontConfigure = true;

    buildPhase =
      if useQtConsumer then qtConsumerBuildPhase
      else if crossNoIntrospect then crossBuildPhase
      else nativeLegacyBuildPhase;

    installPhase = ''
      runHook preInstall

      # Install generated headers
      mkdir -p $out/include

      # Copy all generated files (.h and .cpp) to include/ if they exist.
      # Both are needed: downstream modules #include the _api.cpp files from
      # the umbrella logos_sdk.cpp generated by --general-only.
      # buildPhase already guarantees the wrapper pair exists; this is the last
      # line of defence, and it is an ERROR rather than an empty include/ —
      # publishing "no headers" is what made an SDK-pin mismatch look like a
      # successful build and blow up later in a downstream link.
      gen_count=$(find ./generated_headers -maxdepth 1 \( -name '*.h' -o -name '*.cpp' \) 2>/dev/null | wc -l)
      if [ "$gen_count" -eq 0 ]; then
        echo "Error: no generated headers to install from ./generated_headers" >&2
        ls -la ./generated_headers >&2 || true
        exit 1
      fi
      echo "Copying generated headers and API files..."
      ls -la ./generated_headers
      find ./generated_headers -maxdepth 1 \( -name '*.h' -o -name '*.cpp' \) -exec cp {} $out/include/ \;

      runHook postInstall
    '';
  };
}
