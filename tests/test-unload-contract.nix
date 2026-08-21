# The teardown hook is a BY-NAME contract, and both of its halves live in this
# repo: qt-host-generator EMITS the two members on a module's plugin class, and
# cpp/logos_plugin_unload.cpp REACHES them through the meta-object. Nothing in
# either build ties the two together -- a rename on one side produces a plugin
# whose hook is simply never found, which is indistinguishable from a module
# that legitimately declined to implement it. Silent, and permanent.
#
# So: generate real glue, scrape the names OUT of it, and require the consumer
# to reach for exactly those. Bidirectional by construction -- renaming the
# emitter makes the greps miss the consumer, renaming the consumer makes them
# miss it too.
#
# The consumer source is read from `src` (the repo root) rather than from the
# built package, because a static archive does not preserve these strings in a
# form worth asserting on.
{ pkgs, generator, src }:

pkgs.runCommand "logos-qt-host-unload-contract-test" {
  nativeBuildInputs = [ generator ];
} ''
  mkdir -p work && cd work
  cat > sample.lidl <<'EOF'
  module teardown_probe {
    version "1.0.0"
    method ping() -> tstr
  }
  EOF

  logos-qt-host-generator --lidl sample.lidl --output-dir out
  h=out/teardown_probe_cdylib_glue.h
  test -f "$h" || { echo "generator emitted no glue header"; exit 1; }

  consumer=${src}/cpp/logos_plugin_unload.cpp
  test -f "$consumer" || { echo "MISSING consumer: $consumer"; exit 1; }

  # ---- the invokable, as the generator spells it ------------------------
  # `Q_INVOKABLE int <name>();` -- capture <name> rather than assuming it, so
  # this test keeps working (and keeps guarding) through a deliberate rename.
  method=$(sed -n 's/.*Q_INVOKABLE[[:space:]]\+int[[:space:]]\+\([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' $h | head -1)
  test -n "$method" || {
    echo "no 'Q_INVOKABLE int <name>();' in the generated glue header."
    echo "The host resolves the teardown hook by name and by an int return;"
    echo "changing either shape means changing runPluginAboutToUnload too."
    exit 1
  }
  echo "generator emits invokable: $method"

  grep -q "invokeMethod(plugin, \"$method\"" "$consumer" || {
    echo "DRIFT: the glue emits '$method', but logos_plugin_unload.cpp does not"
    echo "invoke that name. The hook would never be found -- and a plugin"
    echo "without the hook is a silent no-op, so nothing would report it."
    exit 1
  }

  # The int return is half the contract: the host reads it with
  # Q_RETURN_ARG(int) and treats 0 as Synchronous. A hook emitted as `void`
  # (or an enum) would leave `flag` untouched at 0, so EVERY module would look
  # Synchronous and no module could ever ask to be waited for.
  grep -q "Q_RETURN_ARG(int" "$consumer" || {
    echo "DRIFT: the glue returns int, the consumer does not read an int back"
    exit 1
  }

  # ---- the completion signal -------------------------------------------
  # Emitted under `Q_SIGNALS:` as `void <name>();`. Take the last declaration
  # in the file so the class's ordinary methods above it cannot match.
  sig=$(sed -n '/Q_SIGNALS:/,$ s/.*void[[:space:]]\+\([A-Za-z_][A-Za-z0-9_]*\)();.*/\1/p' $h | head -1)
  test -n "$sig" || { echo "no signal declared under Q_SIGNALS: in $h"; exit 1; }
  echo "generator emits signal: $sig"

  grep -q "SIGNAL($sig())" "$consumer" || {
    echo "DRIFT: the glue emits the signal '$sig', but logos_plugin_unload.cpp"
    echo "connects to a different one. An Asynchronous module would then be"
    echo "refused the wait it asked for -- or, worse, waited out in full."
    exit 1
  }

  # ---- the grace period stays a parameter -------------------------------
  # Two hosts drive this helper out of two DIFFERENT hard-kill budgets
  # (logos_host: 5s from the container; ui-host: 3s from ViewModuleHost::stop).
  # A constant baked in here would silently overrun whichever budget is
  # smaller, and the module would be killed mid-teardown rather than waited
  # for -- the exact failure the hook exists to prevent.
  grep -q "runPluginAboutToUnload(QObject\* plugin, int graceMs)" "$consumer" || {
    echo "the grace period must stay a per-host parameter, not a constant here"
    exit 1
  }

  echo "teardown contract intact: $method / $sig"
  touch $out
''
