# Builder for module headers.
#
# Two code paths, picked by the HOST platform:
#
#   native  — introspect the compiled plugin (logos-cpp-generator <plugin.so>
#             --module-only). Unchanged, and still the default everywhere the
#             builder can actually dlopen what it just built.
#
#   cross   — generate from the module's LIDL CONTRACT instead
#             (--metadata <stub> --general-only --dep <name>=<file.lidl>).
#             A Linux builder cannot load a Windows PE, so introspection is
#             impossible under x86_64-w64-mingw32 and the probe below would
#             always fail. The contract carries the same information the
#             introspector would have recovered from the plugin's Qt
#             metaobject, so the emitted <name>_api.{h,cpp} are equivalent.
#
# The cross path deliberately does NOT fail soft. The native path ends in
# `|| { ... touch .no-api; }`, which is survivable there because the plugin was
# genuinely loadable and an empty API means the module really has none. Under
# cross the same fallback would turn "we cannot introspect a PE" into a green
# build that silently ships a module with no typed API, so every failure mode
# on the cross path is a hard `exit 1` naming the module.
{ lib, common }:

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
    # the module publishes none. Only consulted when the plugin cannot be
    # introspected (cross-compilation); ignored on native builds so they behave
    # byte-for-byte as before.
    contractLidl ? null,
  }:
  let
    pluginFilename = common.getPluginFilename pkgs config.name;
    libExt = common.getLibExtension pkgs;

    # A Linux (or Darwin) builder cannot dlopen a Windows PE, so plugin
    # introspection is structurally impossible here.
    crossNoIntrospect = pkgs.stdenv.hostPlatform.isWindows;

    # ── cross: LIDL-driven generation ──────────────────────────────────────
    # `--dep <name>=<file.lidl>` is the generator's existing contract->consumer
    # backend (BindMode::Static, the same one production consumers already use
    # via buildPlugin.nix's staticDeps). It only runs inside the `--general-only`
    # branch of the generator, hence the metadata stub: `--general-only` needs a
    # metadata.json, but the only thing it takes from it is the umbrella
    # (logos_sdk.{h,cpp}), which the native --module-only path does not emit and
    # which we therefore delete again below.
    crossBuildPhase = ''
      runHook preBuild

      mkdir -p ./generated_headers

    '' + (if contractLidl == null then ''
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

  in pkgs.stdenv.mkDerivation {
    pname = "${commonArgs.pname}-headers-${apiStyle}";
    version = commonArgs.version;

    inherit src;
    inherit (commonArgs) meta;

    # We need the generator and the built plugin. logosSdk's
    # `propagatedBuildInputs` only ships OpenSSL / Boost /
    # nlohmann_json — Qt is intentionally excluded (see
    # logos-cpp-sdk/nix/default.nix) so qtbase isn't dragged into our
    # closure here, qtPreHook doesn't fire, and we don't need
    # `wrapQtAppsNoGuiHook` either: the generator binary at
    # `${logosSdk}/bin/logos-cpp-generator` was already wrapped at
    # SDK build time. `dontWrapQtApps = true` is kept as a belt-and-
    # suspenders no-op in case a future change re-introduces qtbase.
    nativeBuildInputs = [ logosSdk ];

    dontWrapQtApps = true;

    # No configure phase needed
    dontConfigure = true;

    buildPhase = if crossNoIntrospect then crossBuildPhase else ''
      runHook preBuild

      # Create output directory for generated headers
      mkdir -p ./generated_headers

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
      # fine, we skip the flag in that case.
      EVENTS_FROM_FLAG=""
      if [ -f "${lib}/share/logos/${config.name}.lidl" ]; then
        EVENTS_FROM_FLAG="--events-from ${lib}/share/logos/${config.name}.lidl"
        echo "Using events sidecar: ${lib}/share/logos/${config.name}.lidl"
      fi

      logos-cpp-generator "$PLUGIN_FILE" --output-dir ./generated_headers \
        --module-only --api-style ${apiStyle} $EVENTS_FROM_FLAG || {
        echo "Warning: logos-cpp-generator failed, this may be expected if the module has no public API"
        # Create a marker file to indicate attempt was made
        touch ./generated_headers/.no-api
      }

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      # Install generated headers
      mkdir -p $out/include

      # Copy all generated files (.h and .cpp) to include/ if they exist.
      # Both are needed: downstream modules #include the _api.cpp files from
      # the umbrella logos_sdk.cpp generated by --general-only.
      gen_count=$(find ./generated_headers -maxdepth 1 \( -name '*.h' -o -name '*.cpp' \) 2>/dev/null | wc -l)
      if [ "$gen_count" -gt 0 ]; then
        echo "Copying generated headers and API files..."
        ls -la ./generated_headers
        find ./generated_headers -maxdepth 1 \( -name '*.h' -o -name '*.cpp' \) -exec cp {} $out/include/ \;
      else
        echo "Warning: No generated headers found, creating empty include directory"
        echo "# No headers generated by logos-cpp-generator" > $out/include/.generated
      fi

      runHook postInstall
    '';
  };
}
