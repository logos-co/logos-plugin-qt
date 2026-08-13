#ifndef LOGOS_QT_ARG_DECODE_H
#define LOGOS_QT_ARG_DECODE_H

// ---------------------------------------------------------------------------
// logos_qt_arg_decode.h — decoding an incoming RPC argument into the Qt type a
// provider method DECLARES. The Qt face of logos::fromJson<T>.
//
// WHY THIS EXISTS. A Qt-typed provider used to hand every incoming argument to
// a Qt conversion — `args.at(0).toULongLong()` in the generated dispatch,
// `QVariant::convert(paramType)` in the QMetaObject one. Both COERCE rather
// than check, so a hostile value never reached the author's method body wearing
// the shape it arrived in:
//
//     echoUint(-1)     ran the body with 18446744073709551615
//     echoInt(3.7)     ran it with 4
//     echoBool(1)      ran it with true
//     echoMap(5)       ran it with {}
//     stringLength(42) ran it with "42"
//
// Every non-Qt surface — the generated cdylib dispatch, the Rust provider, the
// plain wire — decodes the same argument through logos::fromJson<T> and answers
// {"code":"dispatch_failed", ...} instead. That asymmetry meant argument
// validation was not something a Qt module could rely on: the author's own
// precondition checks never saw the value the caller actually sent.
//
// THE RULE IS THE CODEC'S. Nothing here re-derives what a legal value is. The
// argument is encoded to canonical JSON with the same qvariantToNlohmann every
// other Qt hop uses and handed to logos::fromJson<T>. The codec already owns
// the nuance a hand-written check gets wrong — a WHOLE-VALUED float is a legal
// integer (JSON does not distinguish 3 from 3.0, and an argument-typing CLI
// produces 3.0 for "3.0") while 3.7 is refused; `bstr` keeps its documented
// lenient form. A stricter check written here would diverge the moment the
// codec learned something new, which is the failure this whole layer exists to
// prevent.
//
// WHAT IS NOT CHECKED, AND WHY
//   * `any` (QVariant) declares nothing, so there is nothing to check it
//     against. The value is handed on EXACTLY as it arrived — not round-tripped
//     through JSON, which would reinterpret a one-key `_bytes` map as bytes.
//   * LogosList / LogosMap (QVariantList / QVariantMap) are shape-checked
//     (array-ness / object-ness) and then handed on unchanged. Element types
//     are erased by the Qt spelling itself: `[uint]` and `[any]` are both
//     QVariantList, so array-ness is the whole of the declared type at this
//     layer. Rebuilding the payload from JSON instead of passing it through
//     would retype nested elements (an int element would arrive as qlonglong)
//     for no validation gain.
//   * Types with no LIDL counterpart (QUrl, enums, pointers, LogosResult as a
//     parameter) are left to the caller's existing conversion. The codec has no
//     rule for them and inventing one would reject arguments that work today.
// ---------------------------------------------------------------------------

#include <QByteArray>
#include <QJsonArray>
#include <QJsonObject>
#include <QMetaType>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

#include <nlohmann/json.hpp>

#include <cstdint>
#include <map>
#include <string>
#include <type_traits>
#include <vector>

#include "logos_codec.h"
#include "logos_json_convert.h"
#include "logos_types.h"   // LogosResult

namespace logos {

namespace detail {

// QtArgCodec<T>::from(v, path) -> T, throwing logos::CodecError on a mismatch.
// An unsupported T leaves the trait incomplete, so a generator emitting a type
// nobody taught this file about fails to COMPILE naming the type — never
// silently falls back to a coercion.
template <class T, class Enable = void> struct QtArgCodec;

// bool / int / uint / qlonglong / qulonglong / double / float — straight
// through to the canonical codec, which owns signedness, range and the
// whole-valued-float rule. `int` is checked against int32, not widened: a
// method declaring `int` and handed 4294967296 used to run with 0.
template <class T>
struct QtArgCodec<T, std::enable_if_t<std::is_arithmetic_v<T>>> {
    static T from(const QVariant& v, const std::string& path)
    {
        return logos::fromJson<T>(qvariantToNlohmann(v), path);
    }
};

template <> struct QtArgCodec<QString, void> {
    static QString from(const QVariant& v, const std::string& path)
    {
        return QString::fromStdString(
            logos::fromJson<std::string>(qvariantToNlohmann(v), path));
    }
};

// bstr — Codec<std::vector<uint8_t>> is the lenient decoder by design (a Qt
// consumer passing a QString and a CLI typing its arguments both produce a
// plain string for a byte parameter), so that leniency is inherited here rather
// than re-decided.
template <> struct QtArgCodec<QByteArray, void> {
    static QByteArray from(const QVariant& v, const std::string& path)
    {
        const std::vector<uint8_t> bytes =
            logos::fromJson<std::vector<uint8_t>>(qvariantToNlohmann(v), path);
        return QByteArray(reinterpret_cast<const char*>(bytes.data()),
                          static_cast<qsizetype>(bytes.size()));
    }
};

// [tstr] — the one container whose element type the Qt spelling preserves, so
// it is the one container whose elements are checked.
template <> struct QtArgCodec<QStringList, void> {
    static QStringList from(const QVariant& v, const std::string& path)
    {
        const std::vector<std::string> items =
            logos::fromJson<std::vector<std::string>>(qvariantToNlohmann(v), path);
        QStringList out;
        out.reserve(static_cast<qsizetype>(items.size()));
        for (const std::string& s : items) out.append(QString::fromStdString(s));
        return out;
    }
};

// LogosList — shape only (see the header comment). Decoding into
// vector<nlohmann::json> is what produces the array-ness check AND the codec's
// own diagnostic ("expected array at arg0, got string"); the value handed on is
// the caller's, untouched.
template <> struct QtArgCodec<QVariantList, void> {
    static QVariantList from(const QVariant& v, const std::string& path)
    {
        logos::fromJson<std::vector<nlohmann::json>>(qvariantToNlohmann(v), path);
        return v.toList();
    }
};

template <> struct QtArgCodec<QVariantMap, void> {
    static QVariantMap from(const QVariant& v, const std::string& path)
    {
        logos::fromJson<std::map<std::string, nlohmann::json>>(
            qvariantToNlohmann(v), path);
        return v.toMap();
    }
};

template <> struct QtArgCodec<QJsonArray, void> {
    static QJsonArray from(const QVariant& v, const std::string& path)
    {
        logos::fromJson<std::vector<nlohmann::json>>(qvariantToNlohmann(v), path);
        return qvariant_cast<QJsonArray>(v);
    }
};

template <> struct QtArgCodec<QJsonObject, void> {
    static QJsonObject from(const QVariant& v, const std::string& path)
    {
        logos::fromJson<std::map<std::string, nlohmann::json>>(
            qvariantToNlohmann(v), path);
        return qvariant_cast<QJsonObject>(v);
    }
};

// `any` — verbatim, deliberately. See the header comment.
template <> struct QtArgCodec<QVariant, void> {
    static QVariant from(const QVariant& v, const std::string&) { return v; }
};

// No LIDL counterpart as a PARAMETER; kept at today's behaviour so a provider
// declaring one still compiles and still behaves the way it did.
template <> struct QtArgCodec<LogosResult, void> {
    static LogosResult from(const QVariant& v, const std::string&)
    {
        return v.value<LogosResult>();
    }
};

} // namespace detail

// Compile-time entry point — what a generator emits, one call per parameter,
// with the type the author WROTE. Throws logos::CodecError naming the path.
template <class T>
T qtArgFromVariant(const QVariant& v, const std::string& path)
{
    return detail::QtArgCodec<std::decay_t<T>>::from(v, path);
}

// `[Elem]` for a caller that still KNOWS the element type.
//
// A C++ signature spells every typed numeric array QVariantList, so neither the
// QMetaObject dispatch nor a generator scanning a C++ header can check the
// elements — array-ness is all they have. A LIDL-driven generator does have the
// element type, and this is where it spends it. The value handed on is still
// the caller's list, for the reason given in the header comment.
template <class Elem>
QVariantList qtArgListOf(const QVariant& v, const std::string& path)
{
    logos::fromJson<std::vector<Elem>>(qvariantToNlohmann(v), path);
    return v.toList();
}

// Runtime entry point — for the QMetaObject dispatch, which knows a parameter
// only as a QMetaType.
enum class QtArgVerdict {
    Ok,         // `out` holds a value of exactly `paramType`
    Rejected,   // `error` holds the codec's diagnostic
    Unchecked,  // no LIDL counterpart; the caller keeps its own conversion
};

QtArgVerdict qtArgDecode(const QVariant& in, QMetaType paramType,
                         const std::string& path, QVariant& out,
                         std::string& error);

// The canonical rejection value: the same {code, message, origin} object the
// generated cdylib dispatch and the Rust provider return, so a rejected call
// reads identically whichever provider produced it.
nlohmann::json dispatchFailedJson(const std::string& origin,
                                  const std::string& message);

// The same object as a QVariantMap, for a provider whose dispatch returns
// QVariant. Round-trips faithfully on every transport (qt_local pass-through,
// QtRO serialization, and the plain wire's map<->JSON).
QVariant dispatchFailedVariant(const QString& origin, const QString& message);

} // namespace logos

#endif // LOGOS_QT_ARG_DECODE_H
