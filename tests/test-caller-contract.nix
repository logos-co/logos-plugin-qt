# WHO IS CALLING is a BY-NAME contract, and both of its halves live in this
# repo -- which is the only reason a test can hold them together at all.
#
#   HOST HALF     cpp/logos_api.h declares an INVOKABLE on LogosAPI, and
#                 cpp/logos_provider_object.cpp reaches it through the
#                 meta-object (QMetaObject::invokeMethod, by STRING).
#   MODULE HALF   qt-host-generator emits glue that calls that helper and
#                 pushes the answer across the module-impl C ABI.
#
# Nothing in either build ties the string to the declaration. Rename the
# Q_INVOKABLE and every module in the fleet still COMPILES, still LINKS, still
# LOADS, and every handler that asks who called it is told "unknown" -- which is
# also the honest answer for a background thread, a timer and a legacy plugin,
# so there is no anomaly to notice. Silent, permanent, and fail-OPEN in the one
# direction that matters: code that gates on `caller.is_module("x")` simply
# stops recognising x.
#
# So: scrape the invokable's name OUT of the header, and require the consumer to
# reach for exactly that string. Bidirectional by construction -- renaming
# either side makes the grep miss.
#
# Modelled on tests/test-unload-contract.nix, which guards the same shape for
# aboutToUnload. Sources are read from `src` (the repo root) rather than from
# the built package for the same reason: a static archive does not preserve
# these strings in a form worth asserting on.
{ pkgs, generator, src }:

pkgs.runCommand "logos-qt-host-caller-contract-test" {
  nativeBuildInputs = [ generator pkgs.unifdef ];
} ''
  mkdir -p work && cd work
  cat > sample.lidl <<'EOF'
  module caller_probe {
    version "1.0.0"
    method ping() -> tstr
    method doVoid() -> void
  }
  EOF

  logos-qt-host-generator --lidl sample.lidl --output-dir out
  logos-qt-host-generator --lidl sample.lidl --concurrency multi --output-dir out-multi
  c=out/caller_probe_cdylib_glue.cpp
  cm=out-multi/caller_probe_cdylib_glue.cpp
  test -f "$c" && test -f "$cm" || { echo "generator emitted no glue source"; exit 1; }

  api_h=${src}/cpp/logos_api.h
  api_c=${src}/cpp/logos_api.cpp
  pull=${src}/cpp/logos_provider_object.cpp
  pull_h=${src}/cpp/logos_provider_object.h
  for f in "$api_h" "$api_c" "$pull" "$pull_h"; do
    test -f "$f" || { echo "MISSING source: $f"; exit 1; }
  done

  # ---- 1. the invokable, as LogosAPI declares it -------------------------
  # `Q_INVOKABLE QString <name>() const;` -- captured rather than assumed, so a
  # deliberate rename keeps this test working AND keeps it guarding.
  method=$(sed -n 's/.*Q_INVOKABLE[[:space:]]\+QString[[:space:]]\+\([A-Za-z_][A-Za-z0-9_]*\)()[[:space:]]*const.*/\1/p' "$api_h" | head -1)
  test -n "$method" || {
    echo "no 'Q_INVOKABLE QString <name>() const;' on LogosAPI in logos_api.h."
    echo "The pull resolves the caller by name and by a QString return; a"
    echo "plain (non-Q_INVOKABLE) method compiles and is silently unreachable"
    echo "through the meta-object, which is the ONLY channel that lands in the"
    echo "host image."
    exit 1
  }
  echo "LogosAPI exposes invokable: $method"

  # CODE ONLY, for the negative assertions below. Every one of them says "this
  # call must not appear", and both files NAME the forbidden calls in prose --
  # explaining why they are forbidden is the point of those comments. Stripping
  # `//` to end-of-line is crude (it would also cut a `//` inside a string
  # literal; there is none here), so each stripped text is checked against a
  # POSITIVE control first: if the stripping ever ate the real code, the control
  # fails loudly instead of the negatives passing vacuously.
  sed 's|//.*||' "$pull" > pull.code
  sed 's|//.*||' "$api_c" > api.code
  sed 's|//.*||' "$c"    > single.code
  sed 's|//.*||' "$cm"   > multi.code

  # ---- 2. the consumer reaches for exactly that string -------------------
  grep -q "invokeMethod(m_logosAPI, \"$method\"" pull.code || {
    echo "DRIFT: LogosAPI declares '$method', but logos_provider_object.cpp does"
    echo "not invoke that name. Every handler would read Unknown, forever, with"
    echo "nothing to report it."
    exit 1
  }
  grep -q "Q_RETURN_ARG(QString" pull.code || {
    echo "DRIFT: the invokable returns QString; the consumer reads no QString back."
    echo "A dynamic property was rejected on purpose (one process-global slot,"
    echo "clobbered by two overlapping concurrency:\"multi\" calls) -- the value"
    echo "MUST come back as a return."
    exit 1
  }

  # DirectConnection, not Auto/Queued. The document lives in a THREAD-LOCAL
  # opened by ModuleProxy on the dispatch thread; a queued invocation would run
  # on LogosAPI's owner thread instead and read that thread's (empty) slot --
  # and Qt refuses Q_RETURN_ARG on a queued connection anyway, so the symptom
  # would be a runtime warning and a permanent Unknown, not a build failure.
  grep -q "Qt::DirectConnection" pull.code || {
    echo "the pull must be a DirectConnection: the caller lives in the dispatch"
    echo "thread's thread-local, and only a synchronous call reads that thread"
    exit 1
  }

  # ---- 3. the pull must not be a DIRECT C++ call -------------------------
  # THE WHOLE MECHANISM. The host binary and the module plugin EACH define
  # LogosAPI and the protocol's caller thread-local, at distinct addresses,
  # with no undefined reference to the other (Mach-O is TWOLEVEL; PE has no
  # interposition). A direct call binds to the PLUGIN's copy and reads the
  # PLUGIN's empty thread-local -- silently, forever, on macOS and Windows, and
  # correctly on Linux, so a green Linux run proves nothing here.
  if grep -q "logos::currentInboundCallerJson" pull.code; then
    echo "logos_provider_object.cpp calls logos::currentInboundCallerJson()"
    echo "directly. That binds to the PLUGIN image's copy of the thread-local,"
    echo "which no CallerScope ever wrote. It reads empty on macOS and Windows"
    echo "and works on Linux -- see logos_caller_scope.h."
    exit 1
  fi
  if grep -qE "m_logosAPI *-> *$method" pull.code; then
    echo "logos_provider_object.cpp calls m_logosAPI->$method() directly."
    echo "A direct call binds to the PLUGIN image's LogosAPI; only"
    echo "QMetaObject::invokeMethod resolves through the virtual metaObject()"
    echo "the HOST's constructor installed."
    exit 1
  fi

  # THE POSITIVE CONTROL for the comment stripping above, and a contract in its
  # own right. logos_api.cpp is the ONE place in this repo that may read the
  # protocol thread-local directly, because that body runs in the host image by
  # construction -- it is only ever entered through the meta-object. If the
  # stripping had eaten real code, this call would have vanished with it and the
  # three negatives above would have passed on an empty file.
  grep -q "logos::currentInboundCallerJson" api.code || {
    echo "logos_api.cpp no longer reads logos::currentInboundCallerJson()."
    echo "Either the host-side invokable stopped answering from the protocol's"
    echo "own store, or the comment-stripping in this test ate the code and"
    echo "every negative assertion above just passed vacuously."
    exit 1
  }

  # ---- 4. "no caller" has exactly ONE spelling ---------------------------
  # logos-protocol 0.6 chose {"kind":"unknown"} and produces it from
  # logos::callerUnknownJson(). A second, hand-written copy of that literal is
  # how the two drift: a reader applying rule 2 (unrecognised kind => unknown)
  # cannot tell a typo'd spelling from a deliberate refusal to name.
  if grep -n '"kind":"unknown"\|\\"kind\\":\\"unknown\\"' api.code pull.code single.code multi.code; then
    echo "a hand-spelled unknown-caller document. Use logos::callerUnknownJson()"
    echo "-- logos-protocol owns that spelling."
    exit 1
  fi
  grep -q "callerUnknownJson()" pull.code || {
    echo "the pull never falls back to logos::callerUnknownJson(). An old host"
    echo "with no such invokable, or a provider with no LogosAPI, would push a"
    echo "NULL/empty document -- and NULL is the POP on this C ABI, so the"
    echo "module would keep whatever caller the previous dispatch left."
    exit 1
  }

  # ---- 5. the glue emits the triple, in order, in BOTH branches ----------
  # Line numbers are read off the COMMENT-STRIPPED copies (sed preserves the
  # line count, so they still name lines in the real file). The emitted glue
  # explains itself in comments that necessarily name logos_module_dispatch and
  # the push, and `grep -n | head -1` would otherwise anchor on the prose.
  for f in single.code multi.code; do
    label=$f
    grep -q "logos_module_set_call_caller" "$f" || {
      echo "[$label] the glue never pushes the caller across the C ABI"; exit 1; }

    push=$(grep -n "logos_module_set_call_caller(callerJson.c_str())" "$f" | head -1 | cut -d: -f1)
    disp=$(grep -n "logos_module_dispatch(" "$f" | head -1 | cut -d: -f1)
    pop=$(grep -n "logos_module_set_call_caller(nullptr)" "$f" | head -1 | cut -d: -f1)
    if [ -z "$push" ] || [ -z "$disp" ] || [ -z "$pop" ]; then
      echo "[$label] push/dispatch/pop is not the emitted shape:"
      echo "  push=$push dispatch=$disp pop=$pop"
      exit 1
    fi
    if [ "$push" -ge "$disp" ] || [ "$disp" -ge "$pop" ]; then
      echo "[$label] the triple is out of order (push=$push dispatch=$disp pop=$pop)."
      echo "A pop that precedes the dispatch means the handler reads Unknown; a"
      echo "push that follows it means the same. A pop that never runs leaks the"
      echo "caller into the NEXT dispatch on this thread."
      exit 1
    fi

    # The pull is the helper, not a direct call, in the emitted text too.
    grep -q "currentCallerJson()" "$f" || {
      echo "[$label] the glue does not pull the caller from the host"; exit 1; }
    if grep -q "logos::currentInboundCallerJson" "$f"; then
      echo "[$label] the glue reads the PLUGIN image's thread-local directly"; exit 1
    fi

    # MAJOR-aware guard, expanded arithmetic. `MINOR >= 6` alone goes FALSE at
    # 1.0.0 and takes the push and the backends' definition away together --
    # everything still builds and loads, and modules just stop being able to
    # name their caller. Behind a function-like macro, unifdef silently no-ops.
    grep -q "LOGOS_PROTOCOL_VERSION_MAJOR == 0 && LOGOS_PROTOCOL_VERSION_MINOR >= 6" "$f" || {
      echo "[$label] the caller push is not guarded MAJOR-aware on protocol 0.6"
      exit 1
    }
  done

  # ---- 6. concurrency:"multi" pulls on the DISPATCH thread ---------------
  # THE ONE THAT ONLY FAILS UNDER LOAD. callMethod is entered on the dispatch
  # thread, where ModuleProxy's CallerScope is open; the worker thread has no
  # scope and never will. Pulling inside the worker therefore reads Unknown on
  # EVERY platform -- and passes any test that only ever has one caller.
  pull_line=$(grep -n "currentCallerJson()" multi.code | head -1 | cut -d: -f1)
  thread_line=$(grep -n "QThread::create(" multi.code | head -1 | cut -d: -f1)
  if [ -z "$pull_line" ] || [ -z "$thread_line" ] || [ "$pull_line" -ge "$thread_line" ]; then
    echo "multi: the pull (line $pull_line) must happen BEFORE QThread::create"
    echo "(line $thread_line), on the dispatch thread. Inside the worker there is"
    echo "no CallerScope and the answer is Unknown on every platform."
    exit 1
  fi

  # ...and the document must ride into the worker BY VALUE. The lambda takes no
  # capture-default and outlives the frame that builds it, so an uncaptured
  # callerJson does not compile -- but a REFERENCE capture would compile and
  # dangle. The capture list is one line by construction (see
  # test-qt-host-generator.nix, which greps it the same way).
  worker_capture=$(grep -o 'QThread::create(\[[^]]*\]' multi.code)
  printf '%s' "$worker_capture" | grep -q "callerJson" || {
    echo "multi worker lambda does not capture callerJson: $worker_capture"; exit 1; }
  if printf '%s' "$worker_capture" | grep -qE '&[A-Za-z_]*callerJson|callerJson *&'; then
    echo "multi worker captures callerJson by REFERENCE; the frame is gone by"
    echo "the time the worker runs: $worker_capture"
    exit 1
  fi

  # ---- 7. the guard is EVALUATED, not just spelled -----------------------
  # Section 5 greps the guard as text, which proves only that the right
  # characters are present. This RESOLVES it, with the same tool the backends'
  # ABI checks use (logos-cpp-sdk nix/tests-module-impl-abi.nix), at the three
  # versions that matter:
  #
  #   0.5  the surface does not exist -- the push must be GONE, or a module
  #        built against an older protocol fails to link on a symbol its author
  #        never wrote. This is how the 0.3 and 0.5 ABI breaks presented.
  #   0.6  the push must be PRESENT. Obviously.
  #   1.0  the push must STILL be present, and this is the whole reason the
  #        guard is MAJOR-aware. At 1.0.0 the MINOR resets to 0, so a bare
  #        `MINOR >= 6` goes false and deletes the call here and the definition
  #        in every backend AT THE SAME TIME -- everything builds, everything
  #        loads, and every module silently stops being able to name its caller.
  #        Nothing else in this file can see that; the text grep passes and the
  #        compiler is never asked.
  check_guard() {
    M="$1"; m="$2"; want="$3"; f="$4"
    # `set +e` around unifdef, because its exit code is INFORMATION, not a
    # failure: 0 means the file was unchanged, 1 means conditionals were
    # resolved (the normal outcome here), and only >= 2 is an error. Under the
    # builder's `set -e` the 1 would abort this script silently, mid-test, with
    # every assertion below simply never running -- which is exactly what it did
    # the first time this section was written.
    set +e
    unifdef -DLOGOS_PROTOCOL_VERSION_MAJOR="$M" \
            -DLOGOS_PROTOCOL_VERSION_MINOR="$m" \
            -o resolved.cpp "$f"
    rc=$?
    set -e
    # 0 = unchanged, 1 = changed; anything else is a real unifdef failure, and
    # an unresolved conditional would make every assertion below vacuous.
    [ "$rc" -le 1 ] || { echo "unifdef exited $rc on $f at $M.$m"; exit 1; }
    if grep -q "LOGOS_PROTOCOL_VERSION" resolved.cpp; then
      echo "unifdef left a protocol conditional unresolved at $M.$m:"
      grep -n "LOGOS_PROTOCOL_VERSION" resolved.cpp
      echo "That is unifdef's silent no-op -- it cannot evaluate what it was"
      echo "given (a function-like macro, or arithmetic it does not parse), so"
      echo "the guard was never really tested. Emit it expanded."
      exit 1
    fi
    if grep -q "logos_module_set_call_caller" resolved.cpp; then
      got=present
    else
      got=absent
    fi
    if [ "$got" != "$want" ]; then
      echo "at protocol $M.$m the caller push is $got, expected $want ($f)"
      exit 1
    fi
    echo "  protocol $M.$m -> push $got  ($(basename $(dirname $f)))"
  }

  for f in "$c" "$cm"; do
    check_guard 0 5 absent  "$f"
    check_guard 0 6 present "$f"
    check_guard 1 0 present "$f"
  done

  echo "caller contract intact: $method"
  touch $out
''
