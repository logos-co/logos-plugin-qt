#include "logos_qt_arg_decode.h"

namespace logos {

namespace {

// One case per QMetaType the Qt type mapping can produce for a parameter.
// Each hands off to the SAME QtArgCodec<T> the generated dispatch uses, so the
// two provider sites cannot answer differently for the same argument.
template <class T>
QtArgVerdict decodeAs(const QVariant& in, const std::string& path, QVariant& out,
                      std::string& error)
{
    try {
        out = QVariant::fromValue(detail::QtArgCodec<T>::from(in, path));
        return QtArgVerdict::Ok;
    } catch (const CodecError& e) {
        error = e.what();
        return QtArgVerdict::Rejected;
    }
}

} // namespace

QtArgVerdict qtArgDecode(const QVariant& in, QMetaType paramType,
                         const std::string& path, QVariant& out,
                         std::string& error)
{
    switch (paramType.id()) {
    case QMetaType::Bool:      return decodeAs<bool>(in, path, out, error);
    case QMetaType::Int:       return decodeAs<int>(in, path, out, error);
    case QMetaType::UInt:      return decodeAs<unsigned int>(in, path, out, error);
    case QMetaType::Short:     return decodeAs<short>(in, path, out, error);
    case QMetaType::UShort:    return decodeAs<unsigned short>(in, path, out, error);
    case QMetaType::Long:      return decodeAs<long>(in, path, out, error);
    case QMetaType::ULong:     return decodeAs<unsigned long>(in, path, out, error);
    case QMetaType::LongLong:  return decodeAs<qlonglong>(in, path, out, error);
    case QMetaType::ULongLong: return decodeAs<qulonglong>(in, path, out, error);
    case QMetaType::Double:    return decodeAs<double>(in, path, out, error);
    case QMetaType::Float:     return decodeAs<float>(in, path, out, error);

    case QMetaType::QString:     return decodeAs<QString>(in, path, out, error);
    case QMetaType::QByteArray:  return decodeAs<QByteArray>(in, path, out, error);
    case QMetaType::QStringList: return decodeAs<QStringList>(in, path, out, error);
    case QMetaType::QVariantList: return decodeAs<QVariantList>(in, path, out, error);
    case QMetaType::QVariantMap:  return decodeAs<QVariantMap>(in, path, out, error);
    case QMetaType::QJsonArray:   return decodeAs<QJsonArray>(in, path, out, error);
    case QMetaType::QJsonObject:  return decodeAs<QJsonObject>(in, path, out, error);

    // `any`, QUrl, QChar, enums, pointers, LogosResult, anything a module
    // author invented: no LIDL counterpart, so no rule to check against. The
    // caller keeps whatever it did before — see the header comment.
    default:
        return QtArgVerdict::Unchecked;
    }
}

nlohmann::json dispatchFailedJson(const std::string& origin,
                                  const std::string& message)
{
    return nlohmann::json{{"code", "dispatch_failed"},
                          {"message", message},
                          {"origin", origin}};
}

QVariant dispatchFailedVariant(const QString& origin, const QString& message)
{
    QVariantMap m;
    m.insert(QStringLiteral("code"), QStringLiteral("dispatch_failed"));
    m.insert(QStringLiteral("message"), message);
    m.insert(QStringLiteral("origin"), origin);
    return m;
}

} // namespace logos
