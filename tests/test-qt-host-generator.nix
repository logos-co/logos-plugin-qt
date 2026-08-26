# Drives logos-qt-host-generator over a real LIDL contract and asserts on the
# C++ it emits. The generator has no other test surface — nothing downstream
# compiles its output inside this repo — so these greps are what stands between
# a contract-parsing or emission regression and a module that fails to build
# (or, worse, builds and forwards the wrong thing across the C ABI).
{ pkgs, generator }:

pkgs.runCommand "logos-qt-host-generator-test" {
  # unifdef, so the emitted protocol-version guards can be RESOLVED rather than
  # grepped as text. A grep sees both branches of every #if at every version and
  # would pass vacuously; see the token-doors block below.
  nativeBuildInputs = [ generator pkgs.unifdef ];
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

  # ---- THE TWO TOKEN DOORS, AND WHICH DIRECTION EACH CARRIES ---------------
  #
  # The glue writes a token into the cdylib's own protocol stack from two
  # places, and they mean opposite things:
  #
  #   onInit()             the module's OWN host-issued anchor, under the two
  #                        bootstrap role labels. What this module PRESENTS.
  #                        -> logos_module_accept_token  (OUTBOUND)
  #   informModuleToken()  a CALLER's token, named by capability_module. What
  #                        that caller presents to US.
  #                        -> logos_module_accept_inbound_token  (INBOUND)
  #
  # They were one export until protocol 0.8, and that is why this block exists.
  # A caller's token written through the outbound door lands in this image's
  # per-target cache, so the next call to that same peer finds a token under the
  # peer's name, SKIPS requestModule, presents the peer its own issued token,
  # is rejected, and re-exchanges -- measured on shipped artifacts as a rejection
  # plus a full extra round trip on every call of every two-way pair, forever,
  # and reported to the caller as success. Nothing else in this repo would
  # notice: both spellings compile, link, load and return true.
  #
  # RESOLVED, not grepped. The emitter writes the guard as TEXT -- it is
  # evaluated when the MODULE compiles -- so a plain grep finds both branches at
  # every protocol version and would pass vacuously. unifdef turns the text into
  # the code a module built against a given protocol actually compiles.
  # (rc 0 = unchanged, 1 = changed, >= 2 = error.)
  resolve() {   # <major> <minor> <out>
    set +e
    unifdef -DLOGOS_PROTOCOL_VERSION_MAJOR="$1" -DLOGOS_PROTOCOL_VERSION_MINOR="$2" \
            $c > "$3"
    rc=$?
    set -e
    [ "$rc" -le 1 ] || { echo "unifdef exited $rc on $c"; exit 1; }
    if grep -nE '^[[:space:]]*#[[:space:]]*(if|ifdef|ifndef|else|elif|endif)' "$3"; then
      echo "unifdef left the conditionals above unresolved at $1.$2"; exit 1
    fi
  }

  resolve 0 8 at-0.8
  resolve 0 7 at-0.7
  # One MAJOR up, where a bare `MINOR >= 8` silently goes false and takes the
  # call and the backend's definition away TOGETHER -- everything still builds
  # and loads, and every module quietly goes back to filing its callers as
  # outbound credentials.
  resolve 1 0 at-1.0

  # The CODE of one function, comments stripped. Stripping is not tidiness: the
  # emitted bodies deliberately cross-reference the OTHER door by name ("do not
  # merge this with the logos_module_accept_token() calls in onInit"), and that
  # comment is exactly what a naive grep would score as a call.
  body() {   # <resolved file> <function signature fragment> -> stdout
    awk -v sig="$2" '
      index($0, sig) { inb = 1 }
      inb { print }
      inb && /^}/ { exit }
    ' "$1" | grep -vE '^[[:space:]]*//' || true
  }

  # At 0.8 the caller path takes the INBOUND door and only that door.
  body at-0.8 "::informModuleToken(const QString& moduleName" > inform-0.8
  grep -q "logos_module_accept_inbound_token(" inform-0.8 \
    || { echo "informModuleToken does not use the inbound door at protocol 0.8"; exit 1; }
  grep -q "logos_module_accept_token(" inform-0.8 \
    && { echo "informModuleToken still files a CALLER's token through the OUTBOUND door"; exit 1; }

  # ...and onInit still takes the OUTBOUND one, which is correct there: what it
  # seeds is this module's own credential, not a peer's.
  body at-0.8 "::onInit(LogosAPI* api)" > oninit-0.8
  grep -q 'logos_module_accept_token("core"' oninit-0.8 \
    || { echo "onInit no longer seeds the module's own anchor outbound"; exit 1; }
  grep -q 'logos_module_accept_token("capability_module"' oninit-0.8 \
    || { echo "onInit seeds only one of the two bootstrap role labels"; exit 1; }
  grep -q "logos_module_accept_inbound_token(" oninit-0.8 \
    && { echo "onInit files the module's OWN anchor through the inbound door"; exit 1; }

  # At 0.7 there is no inbound door in the module-impl ABI, so the fallback must
  # still write SOMETHING: dropping the write would break the module's own
  # outbound calls to that peer, which is a regression rather than a fix.
  body at-0.7 "::informModuleToken(const QString& moduleName" > inform-0.7
  grep -q "logos_module_accept_inbound_token(" inform-0.7 \
    && { echo "an inbound-door call survives at protocol 0.7, where the symbol does not exist"; exit 1; }
  grep -q "logos_module_accept_token(" inform-0.7 \
    || { echo "the pre-0.8 fallback write was lost"; exit 1; }

  # THE MAJOR PROBE. This is the assertion that fails against
  # `#if LOGOS_PROTOCOL_VERSION_MINOR >= 8` and passes against the expanded,
  # MAJOR-aware form.
  body at-1.0 "::informModuleToken(const QString& moduleName" > inform-1.0
  grep -q "logos_module_accept_inbound_token(" inform-1.0 \
    || { echo "the inbound door vanishes at protocol 1.0: the guard tests MINOR without MAJOR"; exit 1; }

  # And the guard is spelled EXPANDED rather than behind a function-like macro,
  # because unifdef -- which every backend's ABI check runs -- handles nested
  # integer arithmetic and silently no-ops on anything it cannot evaluate.
  grep -q "LOGOS_PROTOCOL_VERSION_MAJOR == 0 && LOGOS_PROTOCOL_VERSION_MINOR >= 8" $c \
    || { echo "the 0.8 guard is not the expanded MAJOR-aware arithmetic"; exit 1; }

  # ---- drift guard, kept from when there were TWO copies of this emitter ----
  # logos-qt-sdk used to ship qt-generator/lidl_gen_cdylib_glue.cpp, the same
  # emitter this file tests. Both compiled, both emitted loadable glue, so
  # calling the wrong one was not an error — it silently emitted OLDER glue.
  # That is exactly how the host-services grant below went undelivered for a
  # whole phase while every build stayed green.
  #
  # That second copy is GONE: logos-qt-generator deleted `--backend cdylib`
  # (and `--backend qt` with it) and now refuses either flag, emitting only
  # `consumer` and `ui`. So a misrouted builder fails loudly today instead of
  # silently. The assertion below stays anyway — it pins the property that made
  # the divergence detectable in the first place, which is worth having whether
  # or not a rival emitter exists.

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

  # The worker lambda outlives the frame that builds it, so it takes NO
  # capture-default and every local its body reads has to be named explicitly.
  # This suite only ever grepped the emitted text and never compiled it, so a
  # capture list that omitted one read the body still made was invisible here
  # and surfaced as a module build failure instead. The contract above has both
  # a void method and a result method, so both flags must be captured.
  worker_capture=$(grep -o 'QThread::create(\[[^]]*\]' $cm)
  for flag in isVoidMethod isResultMethod; do
    printf '%s' "$worker_capture" | grep -q "$flag" \
      || { echo "multi worker lambda reads $flag but does not capture it: $worker_capture"; exit 1; }
  done

  # A void method's REFUSAL must survive. This branch used to be an
  # unconditional `value = QVariant(true)`: the dispatch JSON was parsed and
  # then discarded, so a provider answering {"code":"invalid_args", ...} was
  # reported to the caller as a successful void call. With the arity upper
  # bound in the generated dispatches (logos-cpp-sdk #150, logos-rust-sdk #50)
  # the provider genuinely refuses `doVoid("junk")` -- and the conformance cell
  # still went green-on-`true` until this branch stopped throwing it away.
  # BOTH void sites, and each in ITS OWN FILE -- not merely 'present
  # somewhere'. There are two, on different concurrency paths: the SINGLE path
  # ($c) returns early via `kVoidMethods.contains(methodName)`, and the MULTI
  # path ($cm) decides inside the worker via `isVoidMethod`. The first fix
  # patched only the multi one, and the assertion here only checked for
  # presence -- so it passed while the conformance cells stayed red. Checking
  # the right property in the wrong file is the same mistake one step over,
  # which is why each site is now asserted against the file it lives in.
  grep -q 'kVoidMethods.contains(methodName)) {' $c \
    || { echo "single-path void return short-circuits before testing the reply"; exit 1; }
  grep -q '__rejected' $c \
    || { echo "single-path void return does not test the reply for a rejection"; exit 1; }
  grep -q '__rejected' $cm \
    || { echo "multi-path void arm does not test the reply for a rejection"; exit 1; }
  for code in dispatch_failed invalid_args unknown_method; do
    grep -q "\"$code\"" $c \
      || { echo "the single-path void rejection set omits $code"; exit 1; }
    grep -q "\"$code\"" $cm \
      || { echo "the multi-path void rejection set omits $code"; exit 1; }
  done
  # It must still answer `true` for an ordinary void reply -- the fix is a
  # branch, not a replacement.
  grep -q 'QVariant(true)' $cm \
    || { echo "the void arm no longer answers true for a normal reply"; exit 1; }

  # void WITHOUT result — the fourth combination, and the one neither
  # hand-written capture list could express: it captured neither flag while the
  # body still named isVoidMethod, so `concurrency: "multi"` on any module with
  # a void method and no result method did not compile at all.
  cat > voidonly.lidl <<'EOF'
  module void_only_probe {
    version "1.0.0"

    method doVoid() -> void
    method echoInt(v: int) -> int
  }
  EOF
  logos-qt-host-generator --lidl voidonly.lidl --concurrency multi --output-dir out-voidonly
  cv=out-voidonly/void_only_probe_cdylib_glue.cpp
  vo_capture=$(grep -o 'QThread::create(\[[^]]*\]' $cv)
  printf '%s' "$vo_capture" | grep -q "isVoidMethod" \
    || { echo "void-only multi lambda does not capture isVoidMethod: $vo_capture"; exit 1; }
  # `if`, not `&& { ...; }` — the negative assertion's SUCCESS path is a failing
  # grep, and a chain ending non-zero would abort the builder under set -e.
  if printf '%s' "$vo_capture" | grep -q "isResultMethod"; then
    echo "void-only multi lambda captures isResultMethod, which it never declares"; exit 1
  fi

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

  # ---- teardown -------------------------------------------------------
  #
  # The host reaches the plugin through the META-OBJECT, so the hook has to be
  # Q_INVOKABLE on the plugin class and the completion has to be a signal. A
  # plain method compiles and is silently unreachable, which is the failure this
  # guards: teardown would look wired and never fire.
  grep -q "Q_INVOKABLE int aboutToUnload();" $h \
    || { echo "plugin class does not expose aboutToUnload() to the meta-object"; exit 1; }
  grep -q "void unloadFinished();" $h \
    || { echo "plugin class has no unloadFinished() signal"; exit 1; }
  grep -q "Q_SIGNALS:" $h \
    || { echo "unloadFinished() is not declared as a signal"; exit 1; }

  # The work itself lives behind the C ABI, in the module's own language.
  grep -q "int SampleProbeCdylibPlugin::aboutToUnload()" $c \
    || { echo "no plugin-side aboutToUnload body"; exit 1; }
  grep -q "return logos_module_about_to_unload();" $c \
    || { echo "plugin does not forward teardown across the C ABI"; exit 1; }

  # Ordering, and it is load-bearing: the completion callback must be installed
  # BEFORE the module is asked to unload. An impl that finishes inline would
  # otherwise signal into an empty slot, and the host would wait out its whole
  # grace period for a module that was already done.
  set_line=$(grep -n "logos_module_set_unload_done_callback" $c | head -1 | cut -d: -f1)
  ask_line=$(grep -n "return logos_module_about_to_unload();" $c | head -1 | cut -d: -f1)
  if [ -z "$set_line" ] || [ -z "$ask_line" ] || [ "$set_line" -ge "$ask_line" ]; then
    echo "completion callback is not installed before the unload request"; exit 1
  fi

  # The teardown pair arrived in logos-protocol 0.5, so the BODY is guarded --
  # a module built against an older protocol has no such C symbols and would
  # fail to link on generated code its author never wrote. The DECLARATION is
  # deliberately NOT guarded: moc emits a call to it, and the host's by-name
  # lookup should find the same meta-object surface on every module.
  grep -q "LOGOS_PROTOCOL_VERSION_MINOR >= 5" $c \
    || { echo "teardown body is not guarded on the protocol that carries it"; exit 1; }
  grep -q "LOGOS_PROTOCOL_VERSION_MINOR" $h \
    && { echo "the aboutToUnload DECLARATION must not be guarded away"; exit 1; }

  # The callback fires on whichever thread the module finished on, so it must
  # not touch the plugin directly -- a queued invocation marshals the emission
  # back to the thread the host is waiting on.
  grep -q "Qt::QueuedConnection" $c \
    || { echo "unloadFinished is emitted without marshalling to the plugin thread"; exit 1; }

  touch $out
''
