// The Qt half of the cdylib module path: the uniform Qt-plugin glue that
// wraps the (language-agnostic) module-impl C ABI. The Qt-FREE half — the
// C-ABI impl-exports around a C++ impl class — stays with logos-cpp-sdk's
// generator (`logos-cpp-generator --backend cdylib`); this glue is emitted by
// THIS repo's `logos-qt-host-generator --backend cdylib`. (It used to be
// logos-qt-generator's `--backend cdylib`; that flag is gone and now refuses.)
#pragma once

#include <QString>
#include "lidl_compat.h"

// `multi` ⇒ the module was built with concurrency:"multi": emit the DEFERRED
// shape of the ordinary callMethod — it hands logos_module_dispatch to a
// QThread worker and returns a pending sentinel at once, and the worker pushes
// the answer back as a completion event keyed by callId. There is no separate
// async override and no separate async C entry point: same callMethod slot,
// same `logos_module_dispatch` symbol, so the provider ABI is unchanged.
// Default false = single (callMethod blocks on the C ABI and returns the answer).
QString lidlMakeCdylibGlueHeader(const ModuleDecl& module, bool multi = false);
QString lidlMakeCdylibGlueSource(const ModuleDecl& module, bool multi = false);
