// The Qt half of the cdylib module path: the uniform Qt-plugin glue that
// wraps the (language-agnostic) module-impl C ABI. The Qt-FREE half — the
// C-ABI impl-exports around a C++ impl class — stays with logos-cpp-sdk's
// generator; this glue is emitted by logos-qt-generator.
#pragma once

#include <QString>
#include "lidl_compat.h"

// `multi` ⇒ the module was built with concurrency:"multi": also emit a
// callMethodAsync override that drives the cdylib's logos_module_dispatch_async
// (concurrent handler execution). Default false = single (sync callMethod only).
QString lidlMakeCdylibGlueHeader(const ModuleDecl& module, bool multi = false);
QString lidlMakeCdylibGlueSource(const ModuleDecl& module, bool multi = false);
