# Builder for the module library (Qt plugin .so/.dylib)
# This is the Qt-specific implementation of the plugin build step.
{ lib, common }:

let
  # Shared generation logic for `build` and `generate`.
  #
  # Produces the shell snippet that runs every code generator that is part of a
  # module's build — the consumer surface (`logos-cpp-generator --general-only`
  # for the umbrella and the lp wrappers, `logos-qt-generator --backend
  # consumer` for the Qt-typed ones; see `generatorCalls`) and the
  # module-builder-level `${preConfigure}` (LIDL, Qt glue, C-ABI dispatch, UI
  # plugin glue) — leaving a fully-populated `generated_code/` in the (source)
  # working directory. `build` runs it from `preConfigure` and then compiles;
  # `generate` runs the very same snippet and snapshots the tree instead of
  # compiling, so the emitted source is guaranteed identical to what a real
  # build generates.
  #
  # Both generators are put on PATH by the caller (logos-module-builder's
  # extraNativeBuildInputs), which is also where the SDK comes from — this
  # backend deliberately knows about neither.
  mkGeneration = {
    pkgs,
    src,
    config,
    moduleDeps ? {},
    interfaceDeps ? [],
    staticDeps ? [],
    externalLibs ? {},
    preConfigure ? "",
  }:
  let
    pluginFilename = common.getPluginFilename pkgs config.name;
    libExt = common.getLibExtension pkgs;
    staticDepNames = builtins.map (e: e.name) staticDeps;

    # Pick the API style up-front from this module's `interface` (and, since
    # the consumer axis became declarable, from `codegen.consumer_api_style`
    # when it is set — see `apiStyle` below). Each
    # dep already ships pre-built header variants (`.headers-qt` and
    # `.headers-lp` — see mkLogosModule.nix's `buildHeaders` calls),
    # so we just copy from the right one. No codegen at consume time.
    # cdylib AND core universal modules get the Qt-free outbound surface: the
    # generated LogosModules umbrella + dep wrappers call the logos-protocol C
    # ABI (lp_*) directly, so the module's own TUs never include Qt (universal
    # is now a header-first cdylib — see modulePreConfigure.universalCodegen).
    # UI universal backends (type: ui_qml) are NOT modules — they derive a Qt
    # SimpleSource whose .rep slots are Qt-typed, so they get the Qt surface
    # too: their LogosUiPluginContext.modules() dep wrappers come out Qt-typed,
    # matching the view, with no std<->Qt conversions at the boundary.
    # Everything else (legacy / handcrafted Qt) is Qt-typed as well.
    #
    # ── Where the wrappers LAND, which is the fact everything below turns on ──
    #
    # `packagedAsCdylib` is true for exactly the shapes whose generated consumer
    # wrappers are compiled into an image that ALSO exports the module-impl C
    # ABI (`logos_module_impl.h`) — the cdylib provider surface. It is the same
    # expression logos-module-builder's modulePreConfigure.autoCodegen branches
    # on when it decides to emit that surface, and it is repeated here rather
    # than only read off `config` so this backend still classifies a module
    # correctly for a caller that predates the metadata key.
    #
    # What it decides is where the image's auth TOKENS come from:
    #
    #   cdylib     — `logos_module_accept_token` -> `lp_token_save`, into the
    #                very TokenManager this image's outbound lp client reads.
    #   Qt plugin  — the host writes tokens to the TokenManager in ITS image;
    #                a plugin links its own copy of the protocol library, so
    #                they must be MIRRORED across by
    #                logos::qt::LpBridge::syncTokens, which is installed only
    #                by `forTarget(api, ...)` — i.e. only where a LogosAPI is
    #                held.
    packagedAsCdylib =
      config.interface == "cdylib"
      || (config.interface == "universal" && (config.type or "core") != "ui_qml");

    # `codegen.consumer_api_style` (validated in logos-module-builder's
    # parseMetadata.nix, surfaced as `config.consumer_api_style`) may override
    # the derived surface. Absent — an older builder, or a direct caller — the
    # derived value is character-for-character what this file computed before
    # the key existed.
    apiStyle =
      let declared = config.consumer_api_style or null;
      in if declared != null then declared
         else if packagedAsCdylib then "lp" else "qt";
    isQt = apiStyle == "qt";

    # ── The gate, second copy ────────────────────────────────────────────────
    #
    # parseMetadata.nix refuses this combination for every module it parses;
    # this is the backend's own refusal, for a caller that hands `config` in by
    # some other route. Same rule, same reason: the lp wrappers hold no
    # LogosAPI, so in a Qt plugin image nothing populates the TokenManager they
    # read and every outbound call goes out unauthenticated — silently.
    #
    # The `qt` direction needs no refusal, and that asymmetry is the design:
    # `qt` is the DEFAULT for a Qt plugin, and `--binding origin` — the part
    # that is unsafe there — is not selectable at all. It is derived below as
    # `qt AND packagedAsCdylib`, so no metadata can reach it from the wrong
    # side.
    assertConsumerApiStyle =
      if apiStyle != "lp" || packagedAsCdylib then null
      else throw ''
        logos-plugin-qt: module '${config.name}' asks for the lp (Qt-free) consumer surface,
        but its dependency wrappers compile into a Qt PLUGIN object.

        interface = "${config.interface}", type = "${config.type or "core"}" — that image holds a
        LogosAPI and exports no `logos_module_accept_token`, so nothing would ever populate the
        TokenManager the lp wrappers read. Every outbound call would present an empty auth token
        and come back as a default value with no error surfaced.

        Fix the `codegen.consumer_api_style` key in that module's metadata.json (drop it to get
        this module's default, "qt"), or make the module a cdylib provider
        (`interface: "universal"` / `interface: "cdylib"`).
      '';

    # ── `--binding origin` ───────────────────────────────────────────────────
    #
    # Qt-typed wrappers that hold NO LogosAPI and state this module's own name
    # as the call origin (logos::qt::LpBridge::forOrigin). Reachable ONLY as the
    # conjunction below, never from metadata directly:
    #
    #   isQt              — there is a Qt-typed wrapper to bind at all; the lp
    #                       wrappers have their own origin baking and no bridge.
    #   packagedAsCdylib  — the image gets its tokens over the C ABI, so the
    #                       NULL sync hook `forOrigin` installs costs nothing.
    #                       In a Qt plugin the same null hook IS the bug
    #                       `syncTokens` was written to fix.
    #
    # Emitted as a suffix on an existing flag rather than as its own line so the
    # generated shell snippet is byte-identical when it is empty — every module
    # that is not origin-bound must hash exactly as it did before.
    originBound = isQt && packagedAsCdylib;
    bindingFlag = lib.optionalString originBound " --binding origin";

    # The TRANSITIONAL header-copy fallback is GONE.
    #
    # It copied a dependency's PRE-BUILT `headers-${apiStyle}` output into
    # generated_code/ for any dep that published no LIDL contract — which also
    # forced that dep's whole plugin to be compiled just to obtain headers.
    # Every dep now arrives as `--dep <name>=<name>.lidl` (see `staticDeps` /
    # `depArgs`) and its wrapper is generated from the contract, so no dep
    # plugin is built at consume time.
    #
    # `moduleDeps` is still ACCEPTED, and asserted empty, on purpose. The caller
    # (logos-module-builder's mkLogosModule) fills it from
    # `legacyHeaderDepNames` = the deps for which `depIsLidl` is false, and a
    # caller that predates this change will keep passing them. Dropping them on
    # the floor would leave the module with neither a `--dep` wrapper nor a
    # copied header — the build would then die inside a generated translation
    # unit on a missing `<dep>_api.h`, pointing at the generator rather than at
    # the dependency that is actually stale. So refuse, by name, here.
    legacyHeaderDepNames =
      builtins.filter (name: !(builtins.elem name staticDepNames))
        (builtins.attrNames moduleDeps);

    assertNoLegacyHeaderDeps =
      if legacyHeaderDepNames == [] then null
      else throw ''
        logos-plugin-qt: module '${config.name}' has dependencies that publish no LIDL contract:
          ${lib.concatStringsSep ", " legacyHeaderDepNames}

        The header-copy fallback that used to serve them was removed. A consumer
        wrapper is now generated from the dependency's published `lidl` output
        (`--dep <name>=<name>.lidl`), which needs no dependency plugin build and
        works under cross-compilation.

        Fix: rebuild / re-pin each dependency above against a current
        logos-module-builder. Any module built by one publishes a `lidl`
        contract; `interface: "universal"` derives it from the impl header
        automatically.
      '';

    # --interface flags for logos-cpp-generator, one per interface
    # dependency. Paths were resolved by mkLogosModule (local files from
    # `src`, remote files from a flake input), so the generator never has to
    # know about flake inputs — it just parses each definition file and emits
    # a runtime-bound wrapper. `impl_class` is appended only for .h files.
    # Each composed spec is passed through escapeShellArg so a name/path/class
    # containing spaces or shell metacharacters can't break arg parsing.
    interfaceArgs = lib.concatMapStringsSep " " (e:
      lib.escapeShellArg ("--interface=" + e.name + "=" + e.path
        + (lib.optionalString (e.impl_class != null) ("=" + e.impl_class)))
    ) interfaceDeps;

    # --dep flags: concrete dependencies generated from their published LIDL
    # (BindMode::Static, name-baked `modules().<dep>`). No dep plugin is built;
    # the path is the dep's `lidl` output (or an override). Same escaping as
    # interfaceArgs.
    depArgs = lib.concatMapStringsSep " " (e:
      lib.escapeShellArg ("--dep=" + e.name + "=" + e.path
        + (lib.optionalString ((e.impl_class or null) != null) ("=" + e.impl_class)))
    ) staticDeps;

    # ── Who emits the qt-style per-dependency wrapper ──────────────────────
    #
    # Every dependency and interface that gets a generated consumer wrapper,
    # with the flavour the wrapper needs. `static` bakes the target module name
    # into the class (a concrete `dependencies` entry, reached as
    # `modules().<dep>`); `bound` takes it as a ctor argument (an
    # `interface_dependencies` entry, reached as `modules().bind_<name>(...)`).
    # The two lists are disjoint by construction — mkLogosModule refuses a name
    # that is both — and logos-cpp-generator drops a `--dep` colliding with an
    # `--interface` for the same reason.
    consumerSpecs =
      (map (e: { inherit (e) name path; impl_class = e.impl_class or null; bind = "static"; }) staticDeps)
      ++ (map (e: { inherit (e) name path; impl_class = e.impl_class or null; bind = "bound"; }) interfaceDeps);

    # One `logos-qt-generator --backend consumer` invocation per spec, emitting
    # `<name>_api.{h,cpp}` straight into ./generated_code — the same file names,
    # class names and public signatures logos-cpp-generator's `--api-style qt`
    # emitter produced, so no call site and no umbrella reference moves.
    #
    # `--class` is deliberately NOT passed: the backend defaults it to
    # lidlToPascalCase(--module), which is character-for-character the
    # toPascalCase the umbrella uses to spell the member's TYPE (both are the
    # same routine in logos-cpp-sdk's shared share/lidl-frontend). Passing it
    # would mean re-implementing that casing in nix and having a second place
    # for the two spellings to drift apart.
    #
    # The generator takes its contract either as LIDL or as the C++ impl header
    # it was derived from, and the file extension picks which — the same
    # dispatch logos-cpp-generator's parseInterfaceFile does. A header also
    # needs a metadata.json, and it must be a SYNTHETIC one carrying only the
    # name: the parser would otherwise read this CONSUMER's `events` out of its
    # metadata and hang them on the dependency's wrapper. (logos-cpp-generator
    # writes the same one-key stub for the same reason.)
    qtConsumerCalls = lib.concatMapStringsSep "\n" (e:
      let
        nameArg = lib.escapeShellArg e.name;
        pathArg = lib.escapeShellArg e.path;
        isHeader = lib.hasSuffix ".h" e.path || lib.hasSuffix ".hpp" e.path;
        # Written only on the header path — the LIDL path needs no metadata.
        synthMeta = lib.optionalString (isHeader && e.impl_class != null) ''
          printf '{"name":"%s"}' ${nameArg} > "$_qtgen_scratch/meta.json"
        '';
        inputArgs =
          if lib.hasSuffix ".lidl" e.path then "--lidl ${pathArg}"
          else if isHeader && e.impl_class != null then
            ''--from-header ${pathArg} --impl-class ${lib.escapeShellArg e.impl_class} --metadata "$_qtgen_scratch/meta.json"''
          else throw ''
            logos-plugin-qt: cannot generate the Qt consumer wrapper for '${e.name}' from ${e.path}.

            A dependency/interface contract is either a `.lidl` file or the C++
            impl header it is derived from (`.h`/`.hpp`, which additionally
            needs `impl_class`). Fix the metadata.json entry that names it
            (`interface_dependencies` or `dependency_overrides`).
          '';
      in synthMeta + ''
        logos-qt-generator ${inputArgs} \
          --backend consumer --module ${nameArg} --bind ${e.bind}${bindingFlag} \
          --output-dir ./generated_code
        if [ ! -s "./generated_code/${e.name}_api.h" ] || [ ! -s "./generated_code/${e.name}_api.cpp" ]; then
          echo "Error: logos-qt-generator emitted no consumer wrapper for '${e.name}' (${e.path})" >&2
          exit 1
        fi
      '') consumerSpecs;

    # The generator invocations, as a shell snippet. Two shapes, and which one
    # a module gets is decided HERE, at eval time, so the lp script is emitted
    # verbatim as it always was.
    #
    #   lp  — one logos-cpp-generator call, unchanged: it emits both the
    #         Qt-free per-dep wrappers and the umbrella.
    #
    #   qt  — the per-dep wrappers come from logos-qt-generator's consumer
    #         backend, which is a VENEER over the same logos-protocol C ABI the
    #         lp wrappers use (one transport, one codec, one Qt type mapper
    #         under both surfaces) rather than a second, parallel Qt
    #         implementation. logos-cpp-generator is still what emits the
    #         UMBRELLA — `logos_sdk.{h,cpp}`, the flat `LogosModules` struct —
    #         because the consumer backend has no notion of an aggregate, and
    #         re-implementing one here would put two emitters back in the
    #         picture for the one artifact they currently agree on.
    #
    # The umbrella run therefore writes to a SCRATCH directory and only
    # logos_sdk.{h,cpp} is taken from it: its per-interface wrappers are the
    # legacy Qt emitter's output, which is exactly what this replaces, and
    # copying them out — or letting them land in generated_code to be
    # overwritten — would leave the shipped wrapper's authorship ambiguous.
    #
    # Two things about that umbrella call are load-bearing:
    #
    #   * `--dep` is dropped. Those flags ONLY drive wrapper emission; the
    #     umbrella's members come from metadata.json's `dependencies` array
    #     (main.cpp reads `deps` from the metadata and hands THAT to
    #     writeUmbrellaHeaderFromDeps), so dropping them costs nothing.
    #
    #   * `--interface` is kept. The umbrella's `bind_<name>(...)` factories
    #     come from the interface NAMES, and a cross-repo interface (an entry
    #     with an `input`) can only reach the generator through a flag — it
    #     self-resolves local entries from metadata.json but skips those. Drop
    #     the flags and such a module silently loses its bind factory.
    #
    # The Qt umbrella's shape is what makes this split work: for `--api-style
    # qt` it emits `LogosModules(LogosAPI* api)` with each member built as
    # `<dep>(api)` and each factory as `<Iface>(api, moduleName)` — precisely
    # the two constructors lidlMakeQtConsumerSource emits for Static and Bound.
    # (It is NOT style-agnostic in general: the lp branch emits a
    # default-constructible struct with std::string binds. It is agnostic to
    # WHICH generator produced the wrappers for a given style, which is the
    # property relied on here.)
    generatorCalls = if !isQt then ''
      logos-cpp-generator --metadata metadata.json --general-only \
        --api-style ${apiStyle} \
        --output-dir ./generated_code ${interfaceArgs} ${depArgs}
    '' else ''
      _umbrella_dir="$(mktemp -d)"
      logos-cpp-generator --metadata metadata.json --general-only \
        --api-style qt${bindingFlag} \
        --output-dir "$_umbrella_dir" ${interfaceArgs}
      for _u in logos_sdk.h logos_sdk.cpp; do
        if [ ! -s "$_umbrella_dir/$_u" ]; then
          echo "Error: logos-cpp-generator emitted no $_u for '${config.name}'" >&2
          ls -la "$_umbrella_dir" >&2
          exit 1
        fi
        cp "$_umbrella_dir/$_u" "./generated_code/$_u"
      done
      rm -rf "$_umbrella_dir"

      echo "Running logos-qt-generator --backend consumer for the Qt-typed dependency wrappers..."
      _qtgen_scratch="$(mktemp -d)"
      ${qtConsumerCalls}
      rm -rf "$_qtgen_scratch"
    '';

    # Copy external libraries to lib/
    externalLibCopies = lib.concatMapStringsSep "\n" (extLib:
      let
        libInfo = externalLibs.${extLib.name} or null;
      in if libInfo != null then ''
        echo "Copying flake-input library ${extLib.name}..."
        mkdir -p lib
        if [ -d "${libInfo}/lib" ]; then
          cp -r "${libInfo}/lib"/* lib/ 2>/dev/null || true
        fi
        # A library that follows the WINDOWS convention ships its runtime half
        # in bin/ -- that is CMake's RUNTIME destination, and what openssl,
        # postgres and every autotools port in nixpkgs do. Without this the
        # staged lib/ holds the import library or the static archive but no
        # .dll, and LogosModule.cmake then hard-fails with "found no companion
        # DLL in .../lib" (or links the static archive by accident).
        #
        # Only THIS library's own files are taken, never all of bin/: the
        # dependency DLLs that nixpkgs' win-dll-link hook stages there must stay
        # symlinks, created by the postFixup pass below. Copying them as real
        # files would make $out/lib look complete while leaving the Nix closure
        # empty again -- a PE embeds no store paths, so those symlinks are the
        # only thing the reference scanner can see.
        # Matching only *.dll keeps this inherently Windows-only -- no native
        # package ships one in bin/ -- so no platform flag has to be threaded
        # in, and a native build provably cannot pick up a stray executable.
        if [ -d "${libInfo}/bin" ]; then
          for f in "${libInfo}"/bin/lib${extLib.name}.dll "${libInfo}"/bin/${extLib.name}.dll; do
            [ -f "$f" ] && cp -fL "$f" lib/ 2>/dev/null || true
          done
        fi
        if [ -f "${libInfo}" ]; then
          cp "${libInfo}" lib/ 2>/dev/null || true
        fi
        if [ -d "${libInfo}/include" ]; then
          echo "Copying headers from ${extLib.name}..."
          cp -r "${libInfo}/include"/* lib/ 2>/dev/null || true
        fi
      '' else if extLib ? vendor_path then ''
        echo "Staging vendor library ${extLib.name} from ${extLib.vendor_path}..."
        mkdir -p lib
        for f in "${src}/${extLib.vendor_path}"/lib*; do
          [ -f "$f" ] && cp "$f" lib/ || true
        done
      '' else ""
    ) config.external_libraries;

    # The full generation snippet. Runs in the (source) working directory and
    # writes generated_code/ + stages external libs into lib/. Shared verbatim
    # by `build` (compiles afterwards) and `generate` (snapshots afterwards).
    # `builtins.seq` on the assertion, not string interpolation: the check has
    # no output to contribute, and interpolating a `throw` into a shell snippet
    # is only reached when that snippet is forced, which is later and further
    # from the cause.
    generationScript = builtins.seq assertConsumerApiStyle (builtins.seq assertNoLegacyHeaderDeps ''
      # Remember source dir — cmake's out-of-tree build will cd into build/
      export LOGOS_MODULE_SOURCE_DIR="$(pwd)"

      # Create generated_code directory for generated files
      mkdir -p ./generated_code

      # Copy external libraries
      ${externalLibCopies}

      # Emit the consumer surface: one `<dep>_api.{h,cpp}` per dependency /
      # interface, plus the umbrella LogosModules struct that aggregates them.
      # `--api-style` picks the type surface: lp (Qt-free, the logos-protocol
      # C ABI) for core universal + cdylib modules, qt (QString / QVariantList
      # / LogosResult) for ui_qml backends and handcrafted Qt modules. Which
      # generator emits what is `generatorCalls` above.
      echo "Running logos-cpp-generator (api-style=${apiStyle}${lib.optionalString originBound ", binding=origin"})..."
      ${lib.optionalString (interfaceDeps != [])
        ("echo " + lib.escapeShellArg ("Binding interfaces: "
          + lib.concatMapStringsSep ", " (e: e.name) interfaceDeps))}
      ${lib.optionalString (staticDeps != [])
        ("echo " + lib.escapeShellArg ("Generating deps from LIDL: "
          + lib.concatMapStringsSep ", " (e: e.name) staticDeps))}
      ${generatorCalls}

      # Check what the generators produced
      echo "Checking generated files in generated_code:"
      ls -la ./generated_code/ 2>/dev/null || echo "No generated files"

      # Create include directory and organize generated files
      if [ -f "./generated_code/core_manager_api.h" ] || [ -f "./generated_code/logos_sdk.h" ]; then
        echo "Creating include directory and moving generated files..."
        mkdir -p ./generated_code/include
        # Move generated header files to include directory
        for file in ./generated_code/*.h; do
          if [ -f "$file" ]; then
            mv "$file" ./generated_code/include/
          fi
        done
        # Also copy generated .cpp files to include directory
        for file in ./generated_code/*.cpp; do
          if [ -f "$file" ]; then
            cp "$file" ./generated_code/include/
          fi
        done
        echo "Generated include directory:"
        ls -la ./generated_code/include/ 2>/dev/null || echo "No include files"
      fi

      # Run any custom preConfigure hook
      ${preConfigure}
    '');
  in {
    inherit generationScript libExt pluginFilename apiStyle originBound;
  };

in {
  build = {
    pkgs,
    src,
    config,
    commonArgs,
    logosSdk,
    moduleDeps ? {},
    interfaceDeps ? [],
    staticDeps ? [],
    externalLibs ? {},
    preConfigure ? "",
    postInstall ? "",
  }:
  let
    gen = mkGeneration {
      inherit pkgs src config moduleDeps interfaceDeps staticDeps externalLibs preConfigure;
    };
    libExt = gen.libExt;

    externalLibDrvs = builtins.filter lib.isDerivation (builtins.attrValues externalLibs);

    # The external libraries' full runtime CLOSURES, for the Windows DLL walk.
    # Adding them to buildInputs is NOT enough: that contributes each library's
    # own lib/ and bin/, but its dependencies live in THEIR store paths --
    # libpackage_downloader_lib.dll imports libcurl-4.dll from curl's output,
    # which no amount of looking inside the package_downloader path will find.
    # A PE records no store references either, so Nix cannot infer this for us.
    externalLibClosure = pkgs.pkgsBuildBuild.closureInfo { rootPaths = externalLibDrvs; };

  in pkgs.stdenv.mkDerivation (commonArgs // {
    # Required wherever the Qt wrapper hooks are absent (Windows -- see
    # common.nix): qtbase's setup hook hard-errors in qtPreHook with
    # "depends on qtbase, but no wrapping behavior was specified" unless one of
    # the two is present. Harmless elsewhere: these are plugins, not
    # applications, so there is nothing to wrap.
    dontWrapQtApps = true;

    pname = "${commonArgs.pname}-lib";

    inherit src;

    # Qt embeds plugin metadata in a special section (.note.qt.metadata on ELF,
    # __TEXT,__qt_pluginmeta on Mach-O). Stripping can remove it on macOS.
    dontStrip = true;

    preConfigure = ''
      runHook prePreConfigure

      ${gen.generationScript}

      runHook postPreConfigure
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib

      # Find and copy the built plugin library.
      #
      # This chain used to list only .dylib and .so, so a perfectly good mingw
      # build of ${config.name}_plugin.dll fell through to the error branch.
      #
      # An explicit test loop rather than a glob array: every candidate below is
      # a fully interpolated LITERAL path with no wildcard in it, and `nullglob`
      # only removes patterns that CONTAIN a wildcard and fail to match -- a
      # literal survives verbatim, so a nullglob array would still hand `cp` the
      # .dylib name on a Windows build. Same shape as the _replica_factory loop
      # directly below, which had it right already.
      plugin=""
      for _cand in \
          modules/${config.name}_plugin.dylib \
          modules/${config.name}_plugin.so \
          modules/${config.name}_plugin.dll \
          ${config.name}_plugin.dylib \
          ${config.name}_plugin.so \
          ${config.name}_plugin.dll; do
        if [ -f "$_cand" ]; then plugin="$_cand"; break; fi
      done
      if [ -z "$plugin" ]; then
        echo "Error: No plugin library file found"
        echo "Searching for any plugin files..."
        find . -name "*_plugin.*" -type f 2>/dev/null || true
        exit 1
      fi
      cp "$plugin" $out/lib/

      # Optional: typed replica factory plugin (generated by logos_module REP_FILE)
      for _rf in \
          modules/${config.name}_replica_factory.dylib \
          modules/${config.name}_replica_factory.so \
          modules/${config.name}_replica_factory.dll \
          ${config.name}_replica_factory.dylib \
          ${config.name}_replica_factory.so \
          ${config.name}_replica_factory.dll; do
        if [ -f "$_rf" ]; then
          echo "Copying replica factory plugin: $(basename $_rf)"
          cp "$_rf" $out/lib/
          break
        fi
      done

      # Copy external libraries staged by externalLibCopies during preConfigure.
      # CMake's out-of-tree build (cd build/) means CWD != source dir, so use
      # the path saved earlier.
      _ext_lib_dir="''${LOGOS_MODULE_SOURCE_DIR:-$(pwd)}/lib"
      if [ -d "$_ext_lib_dir" ]; then
        echo "Checking $_ext_lib_dir for external libraries..."
        for libfile in "$_ext_lib_dir"/*; do
          if [ -f "$libfile" ] && [[ "$libfile" == *.${libExt} ]]; then
            echo "Copying external library: $(basename $libfile)"
            cp "$libfile" $out/lib/
          fi
        done
      fi

      # Copy external libraries from source lib/ directory (platform-specific only)
      if [ -d "${src}/lib" ]; then
        echo "Checking source lib/ directory..."
        for libfile in "${src}"/lib/*; do
          if [ -f "$libfile" ] && [[ "$libfile" == *.${libExt} ]]; then
            basename_file=$(basename "$libfile")
            echo "Copying source library: $basename_file"
            cp "$libfile" $out/lib/
          fi
        done
      fi

      # Fix library paths on macOS
      ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
        # Fix install name for the plugin (must succeed — a broken id causes runtime load failures)
        if [ -f "$out/lib/${config.name}_plugin.dylib" ]; then
          ${pkgs.darwin.cctools}/bin/install_name_tool -id "@rpath/${config.name}_plugin.dylib" "$out/lib/${config.name}_plugin.dylib"
        fi
        if [ -f "$out/lib/${config.name}_replica_factory.dylib" ]; then
          ${pkgs.darwin.cctools}/bin/install_name_tool -id "@rpath/${config.name}_replica_factory.dylib" "$out/lib/${config.name}_replica_factory.dylib"
        fi

        # Fix install_name for all external libraries
        for dylib in $out/lib/*.dylib; do
          if [ -f "$dylib" ]; then
            libname=$(basename "$dylib")
            ${pkgs.darwin.cctools}/bin/install_name_tool -id "@rpath/$libname" "$dylib" 2>/dev/null || true
          fi
        done

        # Fix references to external libraries in the plugin.
        # Libraries may be referenced by bare name (e.g. "libcalc.dylib") or
        # by absolute build/nix-store paths. Rewrite any reference whose
        # basename matches a library shipped in $out/lib/ to @rpath/<name>.
        for plugin in $out/lib/*_plugin.dylib; do
          if [ -f "$plugin" ]; then
            PLUGIN_NAME=$(basename "$plugin")
            for libfile in $out/lib/*.dylib; do
              LIBNAME=$(basename "$libfile")
              [ "$LIBNAME" = "$PLUGIN_NAME" ] && continue
              # Fix bare-name reference (e.g. "libcalc.dylib" -> "@rpath/libcalc.dylib")
              ${pkgs.darwin.cctools}/bin/install_name_tool -change "$LIBNAME" "@rpath/$LIBNAME" "$plugin" 2>/dev/null || true
              # Fix any absolute-path reference ending with this library name
              ${pkgs.darwin.cctools}/bin/otool -L "$plugin" | awk "{print \$1}" | { grep "/$LIBNAME" || true; } | while read OLD_REF; do
                echo "Fixing reference: $OLD_REF -> @rpath/$LIBNAME"
                ${pkgs.darwin.cctools}/bin/install_name_tool -change "$OLD_REF" "@rpath/$LIBNAME" "$plugin" 2>/dev/null || true
              done
            done
          fi
        done
      ''}

      # Install generated include files
      if [ -d "./generated_code/include" ]; then
        mkdir -p $out/include
        cp -r ./generated_code/include/* $out/include/
        echo "Installed generated include files:"
        ls -la $out/include/ 2>/dev/null || echo "No files"
      fi

      # Ship the LIDL events sidecar (emitted by `--from-header` codegen
      # for universal modules that declare any `logos_events:` block).
      # The sidecar is read by buildHeaders.nix to generate typed
      # `on<EventName>(callback)` accessors on the consumer wrapper.
      _LIDL_SIDECAR="$LOGOS_MODULE_SOURCE_DIR/generated_code/${config.name}.lidl"
      if [ -f "$_LIDL_SIDECAR" ]; then
        mkdir -p $out/share/logos
        cp "$_LIDL_SIDECAR" "$out/share/logos/${config.name}.lidl"
        echo "Installed LIDL events sidecar: $out/share/logos/${config.name}.lidl"
      fi

      # Run any custom postInstall hook
      ${postInstall}

      runHook postInstall
    '';
  } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isWindows {
    # Windows: stage the plugin's transitive DLL closure beside it in $out/lib.
    #
    # nixpkgs' win-dll-link.sh hook does exactly this, but its entry point
    # `_linkDLLs` only ever processes `$prefix/bin` -- a module plugin lives in
    # $out/lib and is therefore skipped, so it ships as a bare .dll with none of
    # its dependencies. `linkDLLsInfolder` is that same hook's reusable worker,
    # so this points the upstream mechanism at the right directory rather than
    # reimplementing it.
    #
    # Two things this fixes at once:
    #   1. The module directory becomes self-sufficient, which is what makes an
    #      .lgx payload ($SRC_DRV/lib) complete. Combined with logos-module's
    #      LOAD_WITH_ALTERED_SEARCH_PATH pre-load, Windows then resolves these
    #      from the module's own directory at load time.
    #   2. The Nix closure. A PE embeds no store paths, so the reference scanner
    #      finds none -- `nix-store -qR` on a cross-built module output returned
    #      literally 1, itself. These symlinks are what make the real
    #      dependencies appear, so a cache-substituted module arrives with the
    #      DLLs it needs instead of silently without them.
    #
    # postFixup rather than installPhase so it runs after stripping, and so the
    # symlinks are the last thing written into $out/lib.
    buildInputs = (commonArgs.buildInputs or [ ]) ++ externalLibDrvs;

    postFixup = (commonArgs.postFixup or "") + ''
      if [ -d "$out/lib" ]; then
        # Extend the hook's search path with every store path in the external
        # libraries' closure. Without this the transitive walk stops at the
        # first dependency it cannot locate and the plugin ships incomplete --
        # failing at LOAD time with "The specified module could not be found",
        # which names the plugin rather than the DLL that is actually absent.
        while read -r _p; do
          [ -d "$_p/bin" ] && LINK_DLL_FOLDERS="$LINK_DLL_FOLDERS:$_p/bin"
          [ -d "$_p/lib" ] && LINK_DLL_FOLDERS="$LINK_DLL_FOLDERS:$_p/lib"
        done < ${externalLibClosure}/store-paths
        export LINK_DLL_FOLDERS
        linkDLLsInfolder "$out/lib"
      fi
    '';
  });

  # Generate-only build: run the exact same code generators as `build` (via the
  # shared generationScript) but snapshot the resulting source tree instead of
  # compiling it. The output ($out) is a ready-to-build codebase — the module
  # source plus a fully-populated generated_code/ (and any staged lib/) — which
  # cmake compiles without re-running any generator (installed-layout path in
  # LogosModule.cmake). Build it from the module's `nix develop` shell, which
  # exports LOGOS_*_ROOT.
  generate = {
    pkgs,
    src,
    config,
    commonArgs,
    logosSdk,
    moduleDeps ? {},
    interfaceDeps ? [],
    staticDeps ? [],
    externalLibs ? {},
    preConfigure ? "",
    postInstall ? "",
  }:
  let
    gen = mkGeneration {
      inherit pkgs src config moduleDeps interfaceDeps staticDeps externalLibs preConfigure;
    };

  in pkgs.stdenv.mkDerivation (commonArgs // {
    # Required wherever the Qt wrapper hooks are absent (Windows -- see
    # common.nix): qtbase's setup hook hard-errors in qtPreHook with
    # "depends on qtbase, but no wrapping behavior was specified" unless one of
    # the two is present. Harmless elsewhere: these are plugins, not
    # applications, so there is nothing to wrap.
    dontWrapQtApps = true;

    pname = "${commonArgs.pname}-generated";

    inherit src;

    # No cmake configure, no compile, no ELF/dylib fixup — we only run the
    # generators and snapshot the tree.
    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      ${gen.generationScript}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      # Snapshot the post-generation source tree: module sources + the just
      # generated generated_code/ + any external libs staged into lib/.
      mkdir -p "$out"
      cp -a . "$out/"

      ${postInstall}

      runHook postInstall
    '';
  });
}
