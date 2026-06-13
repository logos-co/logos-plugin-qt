# Builder for the module library (Qt plugin .so/.dylib)
# This is the Qt-specific implementation of the plugin build step.
{ lib, common }:

{
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
    pluginFilename = common.getPluginFilename pkgs config.name;
    libExt = common.getLibExtension pkgs;
    staticDepNames = builtins.map (e: e.name) staticDeps;

    # Pick the API style up-front from this module's `interface`. Each
    # dep already ships pre-built header variants (`.headers-qt` and
    # `.headers-std` — see mkLogosModule.nix's `buildHeaders` calls),
    # so we just copy from the right one. No codegen at consume time.
    # cdylib modules get the Qt-free outbound surface: the generated
    # LogosModules umbrella + dep wrappers call the logos-protocol C ABI
    # (lp_*) directly, so the module's own TUs never include Qt. universal
    # modules keep the std surface (Qt bridged inside the generated .cpp);
    # everything else stays Qt-typed.
    apiStyle = if config.interface == "cdylib" then "lp"
               else if config.interface == "universal" then "std"
               else "qt";

    # TRANSITIONAL: header-copy fallback for dependencies that don't publish a
    # LIDL contract yet (mkLogosModule only puts such deps in `moduleDeps`).
    # Copying a dep's prebuilt headers forces that dep's plugin to be built.
    # Deps that DO publish LIDL come via `staticDeps`/`--dep` instead and are
    # skipped here. Remove this block once every module exposes a `lidl` output.
    moduleDepIncludes = lib.concatMapStringsSep "\n" (name:
      let
        dep = moduleDeps.${name} or null;
        depHeaders =
          if builtins.elem name staticDepNames then null  # generated from LIDL
          else if dep == null then null
          else if dep ? "headers-${apiStyle}" then dep."headers-${apiStyle}"
          else dep;
      in if depHeaders != null then ''
        if [ -d "${depHeaders}/include" ]; then
          echo "Copying ${apiStyle}-typed include files from ${name} (legacy header-copy)..."
          cp -r "${depHeaders}/include"/* ./generated_code/ 2>/dev/null || true
        fi
      '' else ""
    ) config.dependencies;

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

  in pkgs.stdenv.mkDerivation (commonArgs // {
    pname = "${commonArgs.pname}-lib";

    inherit src;

    # Qt embeds plugin metadata in a special section (.note.qt.metadata on ELF,
    # __TEXT,__qt_pluginmeta on Mach-O). Stripping can remove it on macOS.
    dontStrip = true;

    preConfigure = ''
      runHook prePreConfigure

      # Remember source dir — cmake's out-of-tree build will cd into build/
      export LOGOS_MODULE_SOURCE_DIR="$(pwd)"

      # Create generated_code directory for generated files
      mkdir -p ./generated_code

      # Copy include files from module dependencies
      ${moduleDepIncludes}

      # Copy external libraries
      ${externalLibCopies}

      # Run logos-cpp-generator with metadata.json and --general-only.
      # `--api-style` picks the type surface of the generated <Module>
      # client wrappers + the umbrella LogosModules struct: std for
      # universal modules (pure-C++ impl + Qt glue, no Qt at the call
      # site), qt for legacy / handcrafted Qt modules (the historical
      # default — backward-compatible with every existing consumer).
      echo "Running logos-cpp-generator (api-style=${apiStyle})..."
      ${lib.optionalString (interfaceDeps != [])
        ("echo " + lib.escapeShellArg ("Binding interfaces: "
          + lib.concatMapStringsSep ", " (e: e.name) interfaceDeps))}
      ${lib.optionalString (staticDeps != [])
        ("echo " + lib.escapeShellArg ("Generating deps from LIDL: "
          + lib.concatMapStringsSep ", " (e: e.name) staticDeps))}
      logos-cpp-generator --metadata metadata.json --general-only \
        --api-style ${apiStyle} \
        --output-dir ./generated_code ${interfaceArgs} ${depArgs}

      # Check what was generated by logos-cpp-generator
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

      runHook postPreConfigure
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib

      # Find and copy the built plugin library
      if [ -f modules/${config.name}_plugin.dylib ]; then
        cp modules/${config.name}_plugin.dylib $out/lib/
      elif [ -f modules/${config.name}_plugin.so ]; then
        cp modules/${config.name}_plugin.so $out/lib/
      elif [ -f ${config.name}_plugin.dylib ]; then
        cp ${config.name}_plugin.dylib $out/lib/
      elif [ -f ${config.name}_plugin.so ]; then
        cp ${config.name}_plugin.so $out/lib/
      else
        echo "Error: No plugin library file found"
        echo "Searching for any plugin files..."
        find . -name "*_plugin.*" -type f 2>/dev/null || true
        exit 1
      fi

      # Optional: typed replica factory plugin (generated by logos_module REP_FILE)
      for _rf in \
          modules/${config.name}_replica_factory.dylib \
          modules/${config.name}_replica_factory.so \
          ${config.name}_replica_factory.dylib \
          ${config.name}_replica_factory.so; do
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
  });
}
