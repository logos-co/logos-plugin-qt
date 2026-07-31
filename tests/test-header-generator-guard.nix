# Regression test for lib/generate-module-headers.sh — the guard that decides
# whether a logos-cpp-generator run is a build failure or a legitimate
# "module has no public API" build.
#
# It drives the SAME script lib/buildHeaders.nix runs, so the guard under test
# cannot drift from the guard the build uses. logos-cpp-generator itself is
# stubbed: the stubs reproduce the statuses the real generator was measured to
# produce in plugin-introspection mode (see the script's header comment), which
# is exactly the contract this guard depends on.
#
# The bug this pins down: the generator's status used to be swallowed, so an
# SDK-pin mismatch produced an empty header set and exit 0, and the failure
# only surfaced later as a missing symbol in a downstream link.
{ pkgs }:

let
  script = ../lib/generate-module-headers.sh;
in
pkgs.runCommand "logos-plugin-qt-header-generator-guard-test" {
  nativeBuildInputs = [ pkgs.bash ];
} ''
  set -uo pipefail
  # Failing runs are the point of this test — collect them, don't abort on them.
  set +e

  work="$PWD/work"
  mkdir -p "$work"
  failures=0

  # Writes a stub `logos-cpp-generator` into its own bin dir and echoes the dir.
  #   $1 = stub name, $2 = body
  make_stub() {
    local dir="$work/bin-$1"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$dir/logos-cpp-generator"
    chmod +x "$dir/logos-cpp-generator"
    echo "$dir"
  }

  # run <case> <stub-dir|""> <out-dir> [extra script args...]
  # Records exit status in $status and combined output in $output.
  run() {
    local case="$1"; local bindir="$2"; local outdir="$3"; shift 3
    rm -rf "$outdir"; mkdir -p "$outdir"
    local path="$PATH"
    [ -n "$bindir" ] && path="$bindir:$PATH"
    output=$(PATH="$path" bash ${script} "$work/plugin.so" "$outdir" "$@" 2>&1)
    status=$?
    echo "--- case $case: exit $status"
    echo "$output" | sed 's/^/    /'
  }

  check() {
    if [ "$1" = "ok" ]; then
      echo "  PASS: $2"
    else
      echo "  FAIL: $2"
      failures=$((failures + 1))
    fi
  }

  expect_status() {  # <expected> <actual> <what>
    if [ "$2" = "$1" ]; then check ok "$3 (exit $2)"; else check no "$3: expected exit $1, got $2"; fi
  }

  expect_output() {  # <needle> <what>
    case "$output" in
      *"$1"*) check ok "$2" ;;
      *)      check no "$2: output does not mention '$1'" ;;
    esac
  }

  touch "$work/plugin.so"

  ##########################################################################
  # 1. A module with NO public API: the generator exits 0 and still writes a
  #    wrapper (with zero methods). This must remain a successful build —
  #    it is the case the historical `|| true` existed for.
  ##########################################################################
  noapi=$(make_stub noapi '
    outdir=""
    while [ $# -gt 0 ]; do case "$1" in --output-dir) outdir="$2"; shift 2;; *) shift;; esac; done
    printf "class NoApi {};\n" > "$outdir/no_api_module_api.h"
    printf "// no methods\n"   > "$outdir/no_api_module_api.cpp"
    echo "Generated: $outdir/no_api_module_api.h and $outdir/no_api_module_api.cpp"
    exit 0
  ')
  run "no-public-api" "$noapi" "$work/out1" qt
  expect_status 0 "$status" "a module with no public API still builds"
  if [ -f "$work/out1/no_api_module_api.h" ] && [ -f "$work/out1/no_api_module_api.cpp" ]; then
    check ok "the wrapper pair is left in place for installPhase"
  else
    check no "the wrapper pair is left in place for installPhase"
  fi

  ##########################################################################
  # 2. The generator genuinely fails (exit 3 = plugin could not be dlopen'd,
  #    i.e. the mismatched-SDK-pin case). This must FAIL the build, loudly.
  ##########################################################################
  loadfail=$(make_stub loadfail '
    echo "Failed to load plugin at /nix/store/xxx/lib/foo_plugin.so: undefined symbol" >&2
    exit 3
  ')
  run "generator-failed" "$loadfail" "$work/out2" qt
  expect_status 3 "$status" "an unloadable plugin fails the build"
  expect_output "logos-cpp-generator failed" "the failure names the generator"
  expect_output "pinned to incompatible commits" "the failure points at the likely cause"

  ##########################################################################
  # 3. The generator rejects the api style (exit 1 — e.g. a retired style
  #    against a newer SDK). Must fail rather than yield empty headers.
  ##########################################################################
  badstyle=$(make_stub badstyle '
    echo "Unknown --api-style value" >&2
    exit 1
  ')
  run "bad-api-style" "$badstyle" "$work/out3" std
  expect_status 1 "$status" "a rejected --api-style fails the build"
  expect_output "api-style: std" "the failure reports the api style it used"

  ##########################################################################
  # 4. Exit 0 with nothing written: still a failure — an empty include/ is
  #    what made the original bug invisible until a downstream link broke.
  ##########################################################################
  silent=$(make_stub silent 'exit 0')
  run "silent-empty" "$silent" "$work/out4" qt
  if [ "$status" -ne 0 ]; then check ok "a zero exit with no output fails the build (exit $status)";
  else check no "a zero exit with no output fails the build: got exit 0"; fi
  expect_output "produced no client wrapper" "the failure explains the empty output"

  ##########################################################################
  # 5. Half the pair written (header, no source) is also incomplete.
  ##########################################################################
  halfway=$(make_stub halfway '
    outdir=""
    while [ $# -gt 0 ]; do case "$1" in --output-dir) outdir="$2"; shift 2;; *) shift;; esac; done
    printf "class Half {};\n" > "$outdir/half_api.h"
    exit 0
  ')
  run "half-output" "$halfway" "$work/out5" qt
  if [ "$status" -ne 0 ]; then check ok "a missing _api.cpp fails the build (exit $status)";
  else check no "a missing _api.cpp fails the build: got exit 0"; fi

  ##########################################################################
  # 6. Generator absent from PATH: a clear message, not "command not found".
  ##########################################################################
  run "generator-missing" "" "$work/out6" qt
  if [ "$status" -ne 0 ]; then check ok "a missing generator fails the build (exit $status)";
  else check no "a missing generator fails the build: got exit 0"; fi
  expect_output "not on PATH" "the failure says the generator is missing"

  ##########################################################################
  # 7. Argument forwarding: --module-only, the requested --api-style and the
  #    events sidecar must reach the generator (an api-style regression is
  #    how the original empty-header report was produced in the first place).
  ##########################################################################
  recorder=$(make_stub recorder '
    outdir=""
    args="$@"
    while [ $# -gt 0 ]; do case "$1" in --output-dir) outdir="$2"; shift 2;; *) shift;; esac; done
    echo "$args" > "$outdir/argv.txt"
    printf "h\n" > "$outdir/rec_api.h"; printf "c\n" > "$outdir/rec_api.cpp"
    exit 0
  ')
  run "argv-with-events" "$recorder" "$work/out7" lp "$work/rec.lidl"
  expect_status 0 "$status" "the forwarding case builds"
  argv=$(cat "$work/out7/argv.txt")
  echo "    argv: $argv"
  for needle in "--module-only" "--api-style lp" "--events-from $work/rec.lidl"; do
    case "$argv" in
      *"$needle"*) check ok "argv carries $needle" ;;
      *)           check no "argv is missing $needle" ;;
    esac
  done

  run "argv-without-events" "$recorder" "$work/out8" qt
  expect_status 0 "$status" "the no-sidecar case builds"
  argv=$(cat "$work/out8/argv.txt")
  echo "    argv: $argv"
  case "$argv" in
    *--events-from*) check no "argv must not carry --events-from without a sidecar" ;;
    *)               check ok "argv omits --events-from when there is no sidecar" ;;
  esac
  case "$argv" in
    *"--api-style qt"*) check ok "argv carries --api-style qt" ;;
    *)                  check no "argv is missing --api-style qt" ;;
  esac

  echo ""
  if [ "$failures" -ne 0 ]; then
    echo "FAILED: $failures assertion(s)"
    exit 1
  fi
  echo "All header-generator guard assertions passed"
  mkdir -p $out
  echo "ok" > $out/result.txt
''
