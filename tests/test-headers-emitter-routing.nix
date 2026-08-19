# Regression test for lib/buildHeaders.nix's EMITTER SELECTION.
#
# buildHeaders emits a module's consumer wrapper from one of three places, and
# the choice is made at eval time from three inputs (api style, whether the
# module publishes a LIDL contract, whether the caller supplied
# logos-qt-generator). The failure mode being pinned here is not a crash — it
# is SILENCE: if the contract-driven branch ever stops being selected, every
# build stays green and the wrapper quietly comes from the legacy Qt emitter
# again. That is precisely how stale glue survived a whole phase elsewhere in
# this repo.
#
# So this test asserts on the selection itself, by driving the REAL
# `rawLib.buildHeaders` and reading the buildPhase it produced. No module is
# compiled and no generator runs; the point is which command the build WOULD
# run, and that the banner naming it agrees with the command.
{ pkgs, buildHeaders }:

let
  stub = name: pkgs.runCommand "stub-${name}" { } "mkdir -p $out";

  contract = builtins.toFile "demo_module.lidl" ''
    module demo_module {
      method ping() -> string
    }
  '';

  mkCase = { apiStyle, contractLidl, qtGenerator }:
    (buildHeaders {
      inherit pkgs apiStyle contractLidl qtGenerator;
      src = ./.;
      config = {
        name = "demo_module";
        version = "1.0.0";
        description = "routing fixture";
      };
      pluginLib = stub "plugin";
      logosSdk = stub "sdk";
    }).buildPhase;

  cases = {
    # The migration target: qt + a contract + the generator.
    qt-with-contract = mkCase {
      apiStyle = "qt";
      contractLidl = "${contract}";
      qtGenerator = stub "qtgen";
    };
    # The legitimate residue: a handcrafted Qt module describes itself nowhere
    # but in its compiled plugin, so introspection is the only source there is.
    qt-no-contract = mkCase {
      apiStyle = "qt";
      contractLidl = null;
      qtGenerator = stub "qtgen";
    };
    # Out of scope: logos-qt-generator has no lp backend, so the lp wrapper
    # keeps coming from logos-cpp-generator's (non-legacy-Qt) lp emitter.
    lp-with-contract = mkCase {
      apiStyle = "lp";
      contractLidl = "${contract}";
      qtGenerator = stub "qtgen";
    };
    # The defect case: the contract is right there and we are not using it,
    # because the caller is a logos-module-builder that predates the plumbing.
    qt-contract-but-no-generator = mkCase {
      apiStyle = "qt";
      contractLidl = "${contract}";
      qtGenerator = null;
    };
  };

  caseFile = name: pkgs.writeText "buildphase-${name}" cases.${name};
in
pkgs.runCommand "logos-plugin-qt-headers-emitter-routing-test" { } ''
  set -uo pipefail
  set +e
  failures=0

  # want <case> <file> <present-regex...> -- <absent-regex...>
  #
  # Absent-patterns are anchored to the start of a line on purpose: both
  # generators are NAMED in the other branch's banner and in the comments that
  # explain the split, so "does the text mention logos-cpp-generator" answers a
  # different question than "does this build RUN logos-cpp-generator".
  check() {
    local case="$1" file="$2"; shift 2
    local mode=present
    for pat in "$@"; do
      if [ "$pat" = "--" ]; then mode=absent; continue; fi
      if [ "$mode" = present ]; then
        if ! grep -qE -- "$pat" "$file"; then
          echo "FAIL [$case]: expected to find /$pat/ in the emitted buildPhase" >&2
          failures=$((failures + 1))
        fi
      else
        if grep -qE -- "$pat" "$file"; then
          echo "FAIL [$case]: expected NOT to find /$pat/ in the emitted buildPhase" >&2
          failures=$((failures + 1))
        fi
      fi
    done
  }

  # 1. Contract-driven qt: the qt-generator consumer backend, and NOT
  #    logos-cpp-generator or plugin introspection.
  check qt-with-contract ${caseFile "qt-with-contract"} \
    'emitter=qt-consumer' \
    'logos-qt-generator --lidl ' \
    '--backend consumer --module demo_module' \
    '--bind static' \
    'logos::qt::LpBridge' \
    -- \
    '^[[:space:]]*logos-cpp-generator ' \
    'generate-module-headers.sh' \
    '--module-only'

  # 2. No contract: introspection survives, and says why.
  check qt-no-contract ${caseFile "qt-no-contract"} \
    'emitter=legacy-qt' \
    'publishes NO LIDL contract' \
    'generate-module-headers.sh' \
    -- \
    '^[[:space:]]*logos-qt-generator '

  # 3. lp is untouched by this migration.
  check lp-with-contract ${caseFile "lp-with-contract"} \
    'emitter=lp' \
    'generate-module-headers.sh' \
    -- \
    '^[[:space:]]*logos-qt-generator '

  # 4. A contract that is not used must be LOUD. This is the branch that would
  #    otherwise let the migration silently stop happening.
  check qt-contract-but-no-generator ${caseFile "qt-contract-but-no-generator"} \
    'emitter=legacy-qt' \
    'REGRESSION' \
    'WARNING: buildHeaders is falling back to the legacy Qt consumer emitter' \
    'logos-module-builder is stale' \
    -- \
    '^[[:space:]]*logos-qt-generator '

  # Every case must announce an emitter — an unlabelled build is the state this
  # whole test exists to prevent.
  for f in ${caseFile "qt-with-contract"} ${caseFile "qt-no-contract"} \
           ${caseFile "lp-with-contract"} ${caseFile "qt-contract-but-no-generator"}; do
    if ! grep -q 'buildHeaders: emitter=' "$f"; then
      echo "FAIL: a buildPhase carries no emitter banner: $f" >&2
      failures=$((failures + 1))
    fi
  done

  if [ "$failures" -ne 0 ]; then
    echo "$failures emitter-routing assertion(s) failed" >&2
    exit 1
  fi
  echo "buildHeaders emitter routing: all cases OK"
  mkdir -p $out
''
