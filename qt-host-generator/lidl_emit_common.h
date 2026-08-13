#ifndef LIDL_EMIT_COMMON_H
#define LIDL_EMIT_COMMON_H

// The one shared-frontend helper the cdylib glue backend uses, inlined.
//
// logos-cpp-sdk distributes a header of this name under share/lidl-frontend
// with four functions; the cdylib backend calls exactly one of them,
// lidlToPascalCase, to derive the plugin class stem from the module name.
// Twelve lines of definition are a far smaller thing to own than a
// logos-cpp-sdk input on this repo, so the definition lives here and the
// backend source stays byte-identical to the copy it came from.
//
// This is the same rule every other Logos generator applies to a module name
// (logos-view-module's view-generator inlines it too); it must not drift, or
// the class names in the emitted glue stop matching the ones the rest of the
// toolchain expects.

#include <QString>

#include "lidl_compat.h"

inline QString lidlToPascalCase(const QString& name)
{
    QString out;
    bool cap = true;
    for (QChar c : name) {
        if (!c.isLetterOrNumber()) { cap = true; continue; }
        if (cap) { out.append(c.toUpper()); cap = false; }
        else { out.append(c.toLower()); }
    }
    if (out.isEmpty()) return QString("Module");
    return out;
}

#endif // LIDL_EMIT_COMMON_H
