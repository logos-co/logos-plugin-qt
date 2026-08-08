#!/usr/bin/env bash
#
# Generate a module's SDK client wrapper by introspecting its built Qt plugin.
#
#   generate-module-headers.sh <plugin-file> <output-dir> <api-style> [events-sidecar]
#
# Called from lib/buildHeaders.nix. It lives in its own file (rather than
# inline in the buildPhase) because the exit-status handling below is the
# thing that keeps a BROKEN build from looking like a successful one, and
# tests/test-header-generator-guard.nix drives THIS file — so the guard the
# tests check is literally the guard the build runs.
#
# ---------------------------------------------------------------------------
# Why every non-zero status is fatal here
# ---------------------------------------------------------------------------
# "The module has no public API" is a legitimate, non-failing case — but it is
# NOT signalled by a non-zero exit. logos-cpp-generator introspects the
# plugin's QMetaObject: a module that exposes no Q_INVOKABLE method still
# yields a wrapper class (with zero methods) and exits 0. Measured against
# logos-cpp-sdk's generator (plugin-introspection mode, the mode used here):
#
#   plugin with a Q_INVOKABLE method  -> exit 0, wrote <name>_api.{h,cpp}
#   plugin with NO Q_INVOKABLE method -> exit 0, wrote <name>_api.{h,cpp}
#   plugin that fails to dlopen       -> exit 3, wrote nothing   (SDK/ABI skew)
#   unknown / retired --api-style     -> exit 1, wrote nothing   (SDK-pin skew)
#   plugin file missing               -> exit 2, wrote nothing
#   write failure in the output dir   -> exit 5/6
#
# So there is no "expected" failure to swallow. The historical
# `|| { echo Warning...; }` turned an SDK-pin mismatch into a SILENTLY EMPTY
# header set: `nix build .#headers-<style>` exited 0 with an empty include/,
# and the first symptom was an unresolved symbol when some downstream module
# linked — far from the cause. (buildPlugin.nix never swallowed the
# generator's status; buildHeaders.nix was the outlier.)
#
# Belt and braces: a zero exit is additionally required to have PRODUCED the
# wrapper pair, so a generator that ever "succeeds" without writing anything
# fails the build here instead of shipping an empty include/.

set -uo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <plugin-file> <output-dir> <api-style> [events-sidecar]" >&2
  exit 64
fi

plugin_file="$1"
output_dir="$2"
api_style="$3"
events_sidecar="${4:-}"

if ! command -v logos-cpp-generator >/dev/null 2>&1; then
  echo "Error: logos-cpp-generator is not on PATH." >&2
  echo "       The headers derivation must have logos-cpp-sdk in nativeBuildInputs." >&2
  exit 1
fi

mkdir -p "$output_dir"

gen_args=("$plugin_file" --output-dir "$output_dir" --module-only --api-style "$api_style")

# --events-from: typed `on<EventName>(callback)` accessors on the generated
# wrapper come from the dep's LIDL sidecar. Handcrafted Qt modules publish
# none — that is fine, the flag is simply omitted.
if [ -n "$events_sidecar" ]; then
  gen_args+=(--events-from "$events_sidecar")
fi

echo "Running: logos-cpp-generator ${gen_args[*]}"
logos-cpp-generator "${gen_args[@]}"
status=$?

if [ "$status" -ne 0 ]; then
  {
    echo ""
    echo "Error: logos-cpp-generator failed (exit status $status)."
    echo "  plugin:    $plugin_file"
    echo "  api-style: $api_style"
    [ -n "$events_sidecar" ] && echo "  events:    $events_sidecar"
    echo ""
    echo "This is a build error, not the 'module has no public API' case: a"
    echo "module without Q_INVOKABLE methods still generates a wrapper and"
    echo "exits 0. Common causes of a non-zero status here:"
    echo "  * the plugin cannot be dlopen'd by the generator (exit 3) — usually"
    echo "    the module and logos-cpp-sdk are pinned to incompatible commits;"
    echo "  * the SDK does not accept --api-style $api_style (exit 1) — again a"
    echo "    pin mismatch between this backend and logos-cpp-sdk;"
    echo "  * the built plugin is missing or unreadable (exit 2)."
    echo "See the generator's own message above for which one it is."
  } >&2
  exit "$status"
fi

# Postcondition: a successful generator run wrote the per-module wrapper pair.
shopt -s nullglob
generated_headers=("$output_dir"/*_api.h)
generated_sources=("$output_dir"/*_api.cpp)
shopt -u nullglob

if [ "${#generated_headers[@]}" -eq 0 ] || [ "${#generated_sources[@]}" -eq 0 ]; then
  {
    echo ""
    echo "Error: logos-cpp-generator exited 0 but produced no client wrapper."
    echo "  plugin:     $plugin_file"
    echo "  api-style:  $api_style"
    echo "  expected:   $output_dir/<module>_api.h and <module>_api.cpp"
    echo "  contents of $output_dir:"
    ls -la "$output_dir" >&2 || true
    echo ""
    echo "Refusing to install an empty header set — a downstream module would"
    echo "fail much later, at link time, with a missing symbol."
  } >&2
  exit 1
fi

echo "Generated ${#generated_headers[@]} header(s) and ${#generated_sources[@]} source(s) in $output_dir"
