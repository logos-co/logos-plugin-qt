# Regression test for buildPlugin.nix's CONSUMER SURFACE selection, and for the
# one thing that must never be reachable from metadata: `--binding origin` in a
# Qt PLUGIN image.
#
# Why this is a test and not a comment. A generated consumer wrapper that holds
# no LogosAPI — the lp wrappers, and the Qt wrappers emitted under
# `--binding origin` — can only authenticate an outbound call if something else
# populates the TokenManager its lp client reads. A cdylib provider image gets
# that for free over the module-impl C ABI (`logos_module_accept_token` ->
# `lp_token_save`). A Qt plugin does NOT: the host writes tokens to the
# TokenManager in its OWN image, and the only thing that mirrors them across is
# logos::qt::LpBridge::syncTokens, which `forOrigin` deliberately leaves null.
#
# So the same flag is correct in one image and a silent authentication failure
# in the other — calls come back as default values with no error raised. Nothing
# about that shows up in a compile, which is why the SELECTION is asserted here,
# the same way the emitter-routing test asserts on buildHeaders' choice.
#
# No module is compiled and no generator runs: the subject is the generator
# command line the build WOULD run, read off the `generate` derivation's
# buildPhase (it and `build` share one `mkGeneration`, so they cannot diverge).
{ pkgs, generate }:

let
  stub = name: pkgs.runCommand "stub-${name}" { } "mkdir -p $out";

  depLidl = builtins.toFile "demo_dep.lidl" ''
    module demo_dep {
      method ping() -> string
    }
  '';

  baseConfig = {
    name = "demo_module";
    version = "1.0.0";
    description = "consumer-surface fixture";
    external_libraries = [ ];
  };

  mkCase = extra:
    (generate {
      inherit pkgs;
      src = ./.;
      config = baseConfig // extra;
      logosModule = stub "logos-module";
      staticDeps = [ { name = "demo_dep"; path = "${depLidl}"; impl_class = null; } ];
    }).buildPhase;

  # ── Cases that must evaluate ─────────────────────────────────────────────
  cases = {
    # Defaults, unchanged by the new key.
    # A handcrafted Qt plugin: Qt-typed wrappers, LogosAPI-bound.
    legacy-default    = mkCase { interface = "legacy";    type = "core"; };
    # A view backend is a Qt object holding a LogosAPI too, despite "universal".
    uiqml-default     = mkCase { interface = "universal"; type = "ui_qml"; };
    # Header-first cdylibs: the Qt-free surface.
    universal-default = mkCase { interface = "universal"; type = "core"; };
    cdylib-default    = mkCase { interface = "cdylib";    type = "core"; };

    # The one override the key exists for: a cdylib provider consuming its
    # dependencies through Qt-typed, origin-bound wrappers.
    cdylib-qt    = mkCase { interface = "cdylib";    type = "core"; consumer_api_style = "qt"; };
    universal-qt = mkCase { interface = "universal"; type = "core"; consumer_api_style = "qt"; };
  };

  # ── THE GATE ─────────────────────────────────────────────────────────────
  # Asking a Qt plugin for the LogosAPI-free consumer surface must be refused at
  # EVAL. Asserted here rather than left to the compiler: with the ui_qml glue
  # the two umbrella shapes happen to disagree and it IS a compile error, but a
  # handcrafted module that only calls `modules().<dep>` with matching types
  # would build green and then fail to authenticate a single call.
  refusals = {
    legacy-lp = builtins.tryEval
      (mkCase { interface = "legacy"; type = "core"; consumer_api_style = "lp"; });
    uiqml-lp = builtins.tryEval
      (mkCase { interface = "universal"; type = "ui_qml"; consumer_api_style = "lp"; });
  };

  accepted = builtins.filter (n: (refusals.${n}).success) (builtins.attrNames refusals);

  gateHeld =
    if accepted == [ ] then true
    else throw ''
      logos-plugin-qt: the consumer-surface GATE did not fire.

      These configurations were accepted and must not be: ${builtins.concatStringsSep ", " accepted}

      A Qt plugin image holds a LogosAPI and exports no `logos_module_accept_token`,
      so a LogosAPI-free consumer wrapper there has no way to obtain an auth token.
      buildPlugin.nix's `assertConsumerApiStyle` is what refuses this; if it was
      removed or weakened, restore it.
    '';

  caseFile = name: pkgs.writeText "genscript-${name}" cases.${name};

in
builtins.seq gateHeld (pkgs.runCommand "logos-plugin-qt-consumer-api-style-gate-test" { } ''
  set -uo pipefail
  set +e
  failures=0

  # want <case> <file> <present-regex...> -- <absent-regex...>
  want() {
    local case="$1"; shift
    local file="$1"; shift
    local mode=present
    for pat in "$@"; do
      if [ "$pat" = "--" ]; then mode=absent; continue; fi
      if [ "$mode" = present ]; then
        if ! grep -qE -- "$pat" "$file"; then
          echo "FAIL [$case]: expected to find /$pat/"
          failures=$((failures+1))
        fi
      else
        if grep -qE -- "$pat" "$file"; then
          echo "FAIL [$case]: expected NOT to find /$pat/"
          echo "  offending line(s):"
          grep -nE -- "$pat" "$file" | sed 's/^/    /'
          failures=$((failures+1))
        fi
      fi
    done
  }

  # ── Defaults ────────────────────────────────────────────────────────────
  # Qt plugins: Qt-typed wrappers, and NO --binding anywhere. This absence is
  # the whole point of the file.
  want legacy-default ${caseFile "legacy-default"} \
    -- '--binding'
  want uiqml-default ${caseFile "uiqml-default"} \
    -- '--binding'

  # Header-first cdylibs, default: the Qt-free surface, one logos-cpp-generator
  # call, no qt consumer run, and still no --binding (the lp umbrella bakes its
  # origin as a plain string).
  want universal-default ${caseFile "universal-default"} \
    -- '--binding' '^\s*logos-qt-generator '
  want cdylib-default ${caseFile "cdylib-default"} \
    -- '--binding' '^\s*logos-qt-generator '

  # ── The override ────────────────────────────────────────────────────────
  # Both generator runs must carry it: the umbrella (logos-cpp-generator) and
  # every per-dependency wrapper (logos-qt-generator). One without the other
  # emits an umbrella whose members it cannot construct.
  want cdylib-qt ${caseFile "cdylib-qt"} \
    '--api-style qt --binding origin' \
    '--bind static --binding origin'
  want universal-qt ${caseFile "universal-qt"} \
    '--api-style qt --binding origin' \
    '--bind static --binding origin'

  if [ "$failures" -ne 0 ]; then
    echo "$failures assertion(s) failed."
    exit 1
  fi
  echo "consumer-api-style selection + gate OK"
  mkdir -p $out
  echo ok > $out/result
'')
