# Drives logos-qt-host-generator over a real LIDL contract and asserts on the
# C++ it emits. The generator has no other test surface — nothing downstream
# compiles its output inside this repo — so these greps are what stands between
# a contract-parsing or emission regression and a module that fails to build
# (or, worse, builds and forwards the wrong thing across the C ABI).
{ pkgs, generator }:

pkgs.runCommand "logos-qt-host-generator-test" {
  nativeBuildInputs = [ generator ];
} ''
  mkdir -p work && cd work
  cat > sample.lidl <<'EOF'
  module sample_probe {
    version "2.1.0"

    method whoAmI() -> tstr
    method echoInt(v: int) -> int
    method doVoid() -> void
    method makeResult(ok: bool) -> result

    event tickEvent(v: tstr)
  }
  EOF

  # ---- single (default) concurrency ------------------------------------
  logos-qt-host-generator --lidl sample.lidl --output-dir out

  for f in sample_probe_cdylib_glue.h sample_probe_cdylib_glue.cpp; do
    test -f "out/$f" || { echo "MISSING: $f"; exit 1; }
  done

  h=out/sample_probe_cdylib_glue.h
  c=out/sample_probe_cdylib_glue.cpp

  # The class stem is PascalCase of the module name; the provider derives
  # LogosProviderBase (NOT the bare interface) because that is what saves the
  # token into the host-stack TokenManager ModuleProxy validates against, and
  # the plugin must also implement PluginInterface or logos_host's
  # module_initializer refuses it before any provider detection.
  grep -q "class SampleProbeCdylibProvider : public LogosProviderBase" $h \
    || { echo "provider class name/base wrong"; exit 1; }
  grep -q "class SampleProbeCdylibPlugin : public QObject, public PluginInterface, public LogosProviderPlugin" $h \
    || { echo "plugin class name/bases wrong"; exit 1; }
  grep -q 'Q_PLUGIN_METADATA(IID LogosProviderPlugin_iid FILE "metadata.json")' $h \
    || { echo "plugin metadata macro missing"; exit 1; }
  grep -q 'providerName() const override { return QStringLiteral("sample_probe"); }' $h \
    || { echo "module name not carried into providerName()"; exit 1; }
  grep -q 'providerVersion() const override { return QStringLiteral("2.1.0"); }' $h \
    || { echo "version not carried from the contract"; exit 1; }

  # Every C-ABI entry point the glue exists to forward across. Losing any one
  # of these is a module that loads and then silently does nothing.
  for sym in logos_module_dispatch logos_module_string_free \
             logos_module_get_methods logos_module_accept_token \
             logos_module_set_emit_callback logos_module_set_context \
             logos_module_grant_host_services; do
    grep -q "$sym" $c || { echo "C-ABI forwarding lost: $sym"; exit 1; }
  done

  # ---- the host-services grant --------------------------------------------
  # The grant has to reach the MODULE's image: the host binary and the cdylib
  # each link their own logos-protocol, so each has its own process-global
  # grant state. If the glue stopped forwarding it, every gated call in a
  # privileged module would fail closed and do so SILENTLY — lp_token_keys()
  # simply returns null, which is indistinguishable from an empty store.
  grep -q 'obj->property("hostServices")' $c \
    || { echo "grant not read from the host's property stamping"; exit 1; }

  # Ordered BEFORE the context forward, so a privileged impl may already use
  # the granted services from its context-ready hook. Compare line numbers
  # rather than eyeballing: this is exactly the kind of ordering that survives
  # a refactor by accident and then breaks a trust-root module at startup.
  grant_line=$(grep -n 'logos_module_grant_host_services' $c | head -1 | cut -d: -f1)
  ctx_line=$(grep -n 'logos_module_set_context' $c | head -1 | cut -d: -f1)
  if [ "$grant_line" -ge "$ctx_line" ]; then
    echo "grant ($grant_line) must be forwarded BEFORE set_context ($ctx_line)"; exit 1
  fi

  # An ungranted module must not be handed an empty grant: lp_grant_host_services
  # REPLACES the current grant, so pushing "" would be a needless clear, and the
  # emitted guard is what keeps an ordinary module fail-closed without a call.
  grep -q 'if (!hostServices.isEmpty())' $c \
    || { echo "missing the empty-property guard"; exit 1; }

  # A refused grant must be reported. It leaves the module running UNPRIVILEGED,
  # and the symptom otherwise surfaces far away as an unexplained empty registry.
  grep -q 'host services refused' $c \
    || { echo "a refused grant is swallowed"; exit 1; }

  # `void` and `result` returns are the two shapes the glue has to special-case
  # (an invalid QVariant is this slot's failure token, so a void method needs
  # SOME value; a result has to be re-materialized as a Qt LogosResult).
  grep -q 'kVoidMethods = {QStringLiteral("doVoid")}' $c \
    || { echo "void method set not derived from the contract"; exit 1; }
  grep -q 'kResultMethods = {QStringLiteral("makeResult")}' $c \
    || { echo "result method set not derived from the contract"; exit 1; }

  # Single concurrency: callMethod BLOCKS on the C ABI and returns the answer.
  grep -q "char\* result = logos_module_dispatch(methodName.toUtf8().constData()" $c \
    || { echo "single-concurrency callMethod is not the blocking dispatch"; exit 1; }
  if grep -q "pendingCallKey" $c; then
    echo "single concurrency emitted the deferred path"; exit 1
  fi

  # ---- concurrency: multi ----------------------------------------------
  # A different code path entirely: callMethod hands the call to a worker and
  # returns a pending sentinel, and the result arrives as a completion event.
  logos-qt-host-generator --lidl sample.lidl --concurrency multi --output-dir out-multi

  hm=out-multi/sample_probe_cdylib_glue.h
  cm=out-multi/sample_probe_cdylib_glue.cpp

  grep -q '#include "logos_async_dispatch.h"' $hm \
    || { echo "multi header missing the async-dispatch include"; exit 1; }
  grep -q "m_callCounter" $hm \
    || { echo "multi header missing the deferred-call id counter"; exit 1; }
  # A real QThread, not a raw std::thread: a handler making an outbound
  # module->module call spins nested QEventLoops, which only a QThread's event
  # dispatcher can drive.
  grep -q "QThread::create" $cm \
    || { echo "multi source does not run the handler on a QThread"; exit 1; }
  grep -q "pending\[logos::pendingCallKey()\] = callId;" $cm \
    || { echo "multi source does not return the pending sentinel"; exit 1; }
  grep -q "eventCb(logos::callCompleteEvent(), QVariantList{ callId, value });" $cm \
    || { echo "multi source does not push the completion event"; exit 1; }

  # ---- refusals ---------------------------------------------------------
  # No contract at all, and an unparseable one, must both FAIL rather than
  # emit half a plugin.
  if logos-qt-host-generator --output-dir out-bad; then
    echo "generator accepted a run with no --lidl"; exit 1
  fi
  echo 'this file is not a LIDL contract' > broken.lidl
  if logos-qt-host-generator --lidl broken.lidl --output-dir out-bad; then
    echo "generator accepted an unparseable contract"; exit 1
  fi

  touch $out
''
