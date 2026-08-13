#ifndef LIDL_COMPAT_H
#define LIDL_COMPAT_H

// Bridge the copied cdylib-glue backend onto the canonical logos-lidl frontend.
//
// The backend (lidl_gen_cdylib_glue.{h,cpp}) came across from logos-qt-sdk
// BYTE-IDENTICAL, so it still spells the AST types unqualified and still
// streams std::string straight into a QTextStream. This header supplies
// exactly those two affordances and nothing else. logos-cpp-sdk's
// share/lidl-frontend has a much larger header of the same name (records
// checks, the serializer/validator shims, the Qt/std type-name mappers); the
// cdylib backend touches none of it, and pulling it in would put a
// logos-cpp-sdk dependency on this repo for no gain.

#include "lidl/ast.hpp"
#include "lidl/parser.hpp"

#include <QString>
#include <QTextStream>
#include <string>

// The canonical AST, in the global scope the backend references it from.
using lidl::MethodDecl;
using lidl::ModuleDecl;
using lidl::TypeExpr;

// std::string -> QString, and let QTextStream accept std::string directly so
// emission of AST string fields (`s << md.name`) compiles unchanged.
inline QString qs(const std::string& s) { return QString::fromStdString(s); }
inline QTextStream& operator<<(QTextStream& s, const std::string& v)
{
    return s << QString::fromStdString(v);
}

using LidlParseResult = lidl::ParseResult;

inline lidl::ParseResult lidlParse(const QString& source)
{
    return lidl::parse(source.toStdString());
}

#endif // LIDL_COMPAT_H
