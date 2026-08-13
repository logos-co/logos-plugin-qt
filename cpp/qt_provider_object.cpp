#include "qt_provider_object.h"
#include "../core/interface.h"
#include "logos_api.h"
#include "token_manager.h"
#include "logos_types.h"
#include "logos_qt_arg_decode.h"
#include <QDebug>
#include <QMetaObject>
#include <QMetaMethod>
#include <QMetaType>
#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <QUrl>

// ── QMetaObject dispatch helpers (moved from module_proxy.cpp) ──────────────

#define INVOKE_METHOD_WITH_RETURN(returnType, castType) \
    do { \
        castType* result = static_cast<castType*>(returnValue); \
        switch (args.size()) { \
            case 0: \
                return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, Q_RETURN_ARG(returnType, *result)); \
            case 1: \
                return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, Q_RETURN_ARG(returnType, *result), scopedArgs[0].arg); \
            case 2: \
                return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, Q_RETURN_ARG(returnType, *result), scopedArgs[0].arg, scopedArgs[1].arg); \
            case 3: \
                return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, Q_RETURN_ARG(returnType, *result), scopedArgs[0].arg, scopedArgs[1].arg, scopedArgs[2].arg); \
            case 4: \
                return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, Q_RETURN_ARG(returnType, *result), scopedArgs[0].arg, scopedArgs[1].arg, scopedArgs[2].arg, scopedArgs[3].arg); \
            case 5: \
                return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, Q_RETURN_ARG(returnType, *result), scopedArgs[0].arg, scopedArgs[1].arg, scopedArgs[2].arg, scopedArgs[3].arg, scopedArgs[4].arg); \
            default: \
                qWarning() << "QtProviderObject: Currently supports 0-5 arguments. Got:" << args.size(); \
                return false; \
        } \
    } while(0)

namespace {
    class ScopedQArg {
    public:
        ScopedQArg(QMetaMethodArgument a, std::function<void(const void*)> d)
            : arg(a), deleter(std::move(d)) {}

        ~ScopedQArg() {
            if (deleter) {
                deleter(arg.data);
            }
        }

        ScopedQArg(ScopedQArg&& other)
            : arg(std::move(other.arg)), deleter(std::move(other.deleter)) {
                other.deleter = nullptr;
        }
        ScopedQArg& operator=(ScopedQArg&&) = delete;
        ScopedQArg(const ScopedQArg&) = delete;
        ScopedQArg& operator=(const ScopedQArg&) = delete;

        QMetaMethodArgument arg;

    private:
        std::function<void(const void*)> deleter;
    };

    // Every `new T(...)` below is a copy-construction from a value that is
    // ALREADY a T, and every one of them uses parentheses deliberately.
    //
    // With braces, `new QVariantList{arg.toList()}` is list-initialization of a
    // QList<QVariant> from a single QVariantList — and because QVariantList is
    // implicitly convertible to QVariant, QList's initializer_list<QVariant>
    // constructor is also viable. Which one wins is exactly the question CWG
    // 2137 covers, and the compilers answer it differently: Clang picks the
    // copy constructor, GCC picks the initializer-list one and WRAPS the value,
    // so a two-element [1,2] reached the method body as [[1,2]], size 1. That
    // is why this only ever failed on Linux CI.
    //
    // Parentheses cannot select an initializer-list constructor, so they mean
    // the same thing on both compilers. QVariantList was the only type here the
    // divergence could reach — QStringList and QVariantMap are safe only
    // because QString and std::pair are not constructible from their own
    // container — which is precisely why the rule is applied uniformly rather
    // than to the one case that bit.
    auto toScopedQArgs(const QVariantList& args)
    {
        auto scopedArgs = std::vector<ScopedQArg>{};
        for (const auto& arg : args) {
            switch (arg.typeId()) {
                case QMetaType::Int: {
                    auto value = new int(arg.toInt());
                    scopedArgs.emplace_back(
                        Q_ARG(int, *value),
                        [](const void* data) { delete static_cast<const int*>(data); }
                    );
                    break;
                }
                case QMetaType::LongLong: {
                    auto value = new qlonglong(arg.toLongLong());
                    scopedArgs.emplace_back(
                        Q_ARG(qlonglong, *value),
                        [](const void* data) { delete static_cast<const qlonglong*>(data); }
                    );
                    break;
                }
                case QMetaType::ULongLong: {
                    auto value = new qulonglong(arg.toULongLong());
                    scopedArgs.emplace_back(
                        Q_ARG(qulonglong, *value),
                        [](const void* data) { delete static_cast<const qulonglong*>(data); }
                    );
                    break;
                }
                // A typed-numeric array ([int]/[uint]/[float64]/[bool]) maps to
                // QVariantList (only [tstr] maps to QStringList). Without this
                // case such an arg fell to the QString default below, stringified
                // to "" and failed the typed invokeMethod → an EMPTY list arrived.
                case QMetaType::QVariantList: {
                    auto value = new QVariantList(arg.toList());
                    scopedArgs.emplace_back(
                        Q_ARG(QVariantList, *value),
                        [](const void* data) { delete static_cast<const QVariantList*>(data); }
                    );
                    break;
                }
                case QMetaType::QVariantMap: {
                    auto value = new QVariantMap(arg.toMap());
                    scopedArgs.emplace_back(
                        Q_ARG(QVariantMap, *value),
                        [](const void* data) { delete static_cast<const QVariantMap*>(data); }
                    );
                    break;
                }
                case QMetaType::QStringList: {
                    auto value = new QStringList(arg.toStringList());
                    scopedArgs.emplace_back(
                        Q_ARG(QStringList, *value),
                        [](const void* data) { delete static_cast<const QStringList*>(data); }
                    );
                    break;
                }
                case QMetaType::QByteArray: {
                    auto value = new QByteArray(arg.toByteArray());
                    scopedArgs.emplace_back(
                        Q_ARG(QByteArray, *value),
                        [](const void* data) { delete static_cast<const QByteArray*>(data); }
                    );
                    break;
                }
                case QMetaType::QUrl: {
                    auto value = new QUrl(arg.toUrl());
                    scopedArgs.emplace_back(
                        Q_ARG(QUrl, *value),
                        [](const void* data) { delete static_cast<const QUrl*>(data); }
                    );
                    break;
                }
                case QMetaType::Bool: {
                    auto value = new bool(arg.toBool());
                    scopedArgs.emplace_back(
                        Q_ARG(bool, *value),
                        [](const void* data) { delete static_cast<const bool*>(data); }
                    );
                    break;
                }
                case QMetaType::Double: {
                    auto value = new double(arg.toDouble());
                    scopedArgs.emplace_back(
                        Q_ARG(double, *value),
                        [](const void* data) { delete static_cast<const double*>(data); }
                    );
                    break;
                }
                case QMetaType::Float: {
                    auto value = new float(arg.toFloat());
                    scopedArgs.emplace_back(
                        Q_ARG(float, *value),
                        [](const void* data) { delete static_cast<const float*>(data); }
                    );
                    break;
                }
                case QMetaType::QString:
                default: {
                    auto value = new QString(arg.toString());
                    scopedArgs.emplace_back(
                        Q_ARG(QString, *value),
                        [](const void* data) { delete static_cast<const QString*>(data); }
                    );
                    break;
                }
            }
        }
        return scopedArgs;
    }

    bool invokeMethodByArgCount(QObject *module, const QString& methodName, const QVariantList& args, void* returnValue, const char* returnTypeName)
    {
        QByteArray methodNameBytes = methodName.toUtf8();
        const char* methodNameCStr = methodNameBytes.constData();

        auto scopedArgs = toScopedQArgs(args);

        if (returnValue == nullptr) {
            switch (args.size()) {
                case 0:  return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection);
                case 1:  return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, scopedArgs[0].arg);
                case 2:  return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, scopedArgs[0].arg, scopedArgs[1].arg);
                case 3:  return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, scopedArgs[0].arg, scopedArgs[1].arg, scopedArgs[2].arg);
                case 4:  return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, scopedArgs[0].arg, scopedArgs[1].arg, scopedArgs[2].arg, scopedArgs[3].arg);
                case 5:  return QMetaObject::invokeMethod(module, methodNameCStr, Qt::DirectConnection, scopedArgs[0].arg, scopedArgs[1].arg, scopedArgs[2].arg, scopedArgs[3].arg, scopedArgs[4].arg);
                default:
                    qWarning() << "QtProviderObject: Currently supports 0-5 arguments. Got:" << args.size();
                    return false;
            }
        } else if (strcmp(returnTypeName, "bool") == 0) {
            INVOKE_METHOD_WITH_RETURN(bool, bool);
        } else if (strcmp(returnTypeName, "int") == 0) {
            INVOKE_METHOD_WITH_RETURN(int, int);
        } else if (strcmp(returnTypeName, "double") == 0) {
            INVOKE_METHOD_WITH_RETURN(double, double);
        } else if (strcmp(returnTypeName, "float") == 0) {
            INVOKE_METHOD_WITH_RETURN(float, float);
        } else if (strcmp(returnTypeName, "QString") == 0) {
            INVOKE_METHOD_WITH_RETURN(QString, QString);
        } else if (strcmp(returnTypeName, "LogosResult") == 0) {
            INVOKE_METHOD_WITH_RETURN(LogosResult, LogosResult);
        } else if (strcmp(returnTypeName, "QVariant") == 0) {
            INVOKE_METHOD_WITH_RETURN(QVariant, QVariant);
        } else if (strcmp(returnTypeName, "QJsonArray") == 0) {
            INVOKE_METHOD_WITH_RETURN(QJsonArray, QJsonArray);
        } else if (strcmp(returnTypeName, "QVariantList") == 0) {
            INVOKE_METHOD_WITH_RETURN(QVariantList, QVariantList);
        } else if (strcmp(returnTypeName, "QVariantMap") == 0) {
            INVOKE_METHOD_WITH_RETURN(QVariantMap, QVariantMap);
        } else if (strcmp(returnTypeName, "QStringList") == 0) {
            INVOKE_METHOD_WITH_RETURN(QStringList, QStringList);
        } else {
            qWarning() << "QtProviderObject: Unsupported return type:" << returnTypeName;
            return false;
        }
    }
}

// ── QtProviderObject implementation ─────────────────────────────────────────

QtProviderObject::QtProviderObject(QObject* module, QObject* parent)
    : QObject(parent)
    , m_module(module)
{
    if (m_module) {
        connect(m_module, SIGNAL(eventResponse(QString, QVariantList)),
                this, SLOT(onWrappedEventResponse(QString, QVariantList)));
        qDebug() << "[LogosProviderObject] QtProviderObject: connected to QObject eventResponse signal";
    }
}

QtProviderObject::~QtProviderObject()
{
    qDebug() << "[LogosProviderObject] QtProviderObject: destroyed";
}

void QtProviderObject::onWrappedEventResponse(const QString& eventName, const QVariantList& data)
{
    if (m_eventCallback) {
        m_eventCallback(eventName, data);
    }
}

void QtProviderObject::init(void* apiInstance)
{
    if (!m_module) return;

    LogosAPI* api = static_cast<LogosAPI*>(apiInstance);

    int methodIndex = m_module->metaObject()->indexOfMethod("initLogos(LogosAPI*)");
    if (methodIndex != -1) {
        qDebug() << "[LogosProviderObject] QtProviderObject: calling initLogos on wrapped QObject";
        QMetaObject::invokeMethod(m_module, "initLogos",
                                  Qt::DirectConnection,
                                  Q_ARG(LogosAPI*, api));
    } else {
        qDebug() << "[LogosProviderObject] QtProviderObject: wrapped QObject has no initLogos, skipping";
    }
}

QString QtProviderObject::providerName() const
{
    PluginInterface* pi = qobject_cast<PluginInterface*>(m_module);
    return pi ? pi->name() : QString();
}

QString QtProviderObject::providerVersion() const
{
    PluginInterface* pi = qobject_cast<PluginInterface*>(m_module);
    return pi ? pi->version() : QString();
}

void QtProviderObject::setEventListener(EventCallback callback)
{
    m_eventCallback = std::move(callback);
}

QVariant QtProviderObject::callMethod(const QString& methodName, const QVariantList& args)
{
    if (!m_module) {
        qWarning() << "[LogosProviderObject] QtProviderObject::callMethod: null module";
        return QVariant();
    }

    if (methodName.isEmpty()) {
        qWarning() << "[LogosProviderObject] QtProviderObject::callMethod: empty method name";
        return QVariant();
    }

    // Special-case getPluginMethods (framework-level, not on the wrapped plugin)
    if (methodName == "getPluginMethods" && args.isEmpty()) {
        return QVariant(getMethods());
    }

    // Special-case getPluginEvents / getPluginInterface. Legacy Qt modules have
    // no logos_events: section, so getMethods() (built here from QMetaObject)
    // only ever contains methods: events are always empty and the interface is
    // just the methods list.
    if (methodName == "getPluginEvents" && args.isEmpty()) {
        return QVariant(QJsonArray());
    }

    if (methodName == "getPluginInterface" && args.isEmpty()) {
        return QVariant(getMethods());
    }

    // No auth check here by design: this adapter has no token parameter and is
    // only ever reached through ModuleProxy::callRemoteMethod, which authorizes
    // the caller's token before dispatching (see ModuleProxy::isAuthorized).
    // The checks below are sanity guards on the wrapped plugin, not authz.
    PluginInterface* pluginInterface = qobject_cast<PluginInterface*>(m_module);
    if (!pluginInterface) {
        qWarning() << "[LogosProviderObject] QtProviderObject::callMethod: module is not a PluginInterface";
        return QVariant();
    }

    LogosAPI* api = pluginInterface->logosAPI;
    if (!api) {
        qWarning() << "[LogosProviderObject] QtProviderObject::callMethod: LogosAPI not available";
        return QVariant();
    }

    // Find method via QMetaObject
    const QMetaObject* metaObject = m_module->metaObject();
    int methodIndex = -1;
    for (int i = 0; i < metaObject->methodCount(); ++i) {
        QMetaMethod method = metaObject->method(i);
        if (method.name() == methodName && method.parameterCount() == args.size()) {
            methodIndex = i;
            break;
        }
    }

    if (methodIndex == -1) {
        qWarning() << "[LogosProviderObject] QtProviderObject: method not found:" << methodName
                    << "with" << args.size() << "arguments";
        return QVariant();
    }

    QMetaMethod method = metaObject->method(methodIndex);
    QMetaType returnType = method.returnMetaType();

    // Decode args against the types the method actually declares.
    //
    // This used to be a bare QVariant::convert(paramType), which COERCES: an
    // argument the declared type cannot represent silently became one it can
    // (echoInt(3.7) ran the body with 4; echoBool("hello") with true;
    // stringLength(42) with "42"), so the author's own precondition checks
    // never saw the value the caller sent. logos::qtArgDecode routes the value
    // through the canonical codec instead — the same rule the cdylib dispatch,
    // the Rust provider and the plain wire apply — and a mismatch becomes the
    // canonical {"code":"dispatch_failed", ...} answer rather than a plausible
    // wrong value.
    //
    // A type the codec has no rule for (QUrl, an enum, a pointer) reports
    // Unchecked and keeps the old conversion verbatim: inventing a rule for it
    // here would reject arguments that work today.
    QVariantList coercedArgs = args;
    for (int i = 0; i < method.parameterCount() && i < coercedArgs.size(); ++i) {
        QMetaType paramType = method.parameterMetaType(i);

        QVariant decoded;
        std::string reason;
        const logos::QtArgVerdict verdict = logos::qtArgDecode(
            coercedArgs[i], paramType, "arg" + std::to_string(i), decoded, reason);

        if (verdict == logos::QtArgVerdict::Rejected) {
            const QString message = QString::fromStdString(reason);
            qWarning() << "[LogosProviderObject] QtProviderObject: rejected"
                       << methodName << "-" << message;
            return logos::dispatchFailedVariant(providerName(), message);
        }
        if (verdict == logos::QtArgVerdict::Ok) {
            coercedArgs[i] = decoded;
            continue;
        }
        if (coercedArgs[i].metaType() != paramType) {
            QVariant converted = coercedArgs[i];
            if (converted.convert(paramType)) {
                coercedArgs[i] = converted;
            } else {
                qWarning() << "[LogosProviderObject] QtProviderObject: could not convert arg" << i
                           << "from" << coercedArgs[i].typeName()
                           << "to" << paramType.name()
                           << "for method" << methodName;
            }
        }
    }

    bool success = false;
    QVariant result;

    if (returnType == QMetaType::fromType<void>()) {
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, nullptr, nullptr);
        if (success) result = QVariant(true);
    } else if (returnType == QMetaType::fromType<bool>()) {
        bool v = false;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "bool");
        if (success) result = QVariant(v);
    } else if (returnType == QMetaType::fromType<int>()) {
        int v = 0;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "int");
        if (success) result = QVariant(v);
    } else if (returnType == QMetaType::fromType<double>()) {
        double v = 0.0;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "double");
        if (success) result = QVariant(v);
    } else if (returnType == QMetaType::fromType<float>()) {
        float v = 0.0f;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "float");
        if (success) result = QVariant(v);
    } else if (returnType == QMetaType::fromType<QString>()) {
        QString v;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "QString");
        if (success) result = QVariant(v);
    } else if (returnType == QMetaType::fromType<LogosResult>()) {
        LogosResult v;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "LogosResult");
        if (success) result = QVariant::fromValue(v);
    } else if (returnType == QMetaType::fromType<QVariant>()) {
        QVariant v;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "QVariant");
        if (success) result = v;
    } else if (returnType == QMetaType::fromType<QJsonArray>()) {
        QJsonArray v;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "QJsonArray");
        if (success) result = QVariant(v);
    } else if (returnType == QMetaType::fromType<QVariantList>()) {
        QVariantList v;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "QVariantList");
        if (success) result = QVariant::fromValue(v);
    } else if (returnType == QMetaType::fromType<QVariantMap>()) {
        QVariantMap v;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "QVariantMap");
        if (success) result = QVariant::fromValue(v);
    } else if (returnType == QMetaType::fromType<QStringList>()) {
        QStringList v;
        success = invokeMethodByArgCount(m_module, methodName, coercedArgs, &v, "QStringList");
        if (success) result = QVariant(v);
    } else {
        qWarning() << "[LogosProviderObject] QtProviderObject: unsupported return type:"
                    << returnType.name() << "for method:" << methodName;
        return QVariant();
    }

    if (!success) {
        qWarning() << "[LogosProviderObject] QtProviderObject: failed to invoke" << methodName;
    }
    return result;
}

bool QtProviderObject::informModuleToken(const QString& moduleName, const QString& token)
{
    PluginInterface* pluginInterface = qobject_cast<PluginInterface*>(m_module);
    if (!pluginInterface) {
        qWarning() << "[LogosProviderObject] QtProviderObject::informModuleToken: not a PluginInterface";
        return false;
    }

    LogosAPI* api = pluginInterface->logosAPI;
    if (!api) {
        qWarning() << "[LogosProviderObject] QtProviderObject::informModuleToken: LogosAPI not available";
        return false;
    }

    TokenManager* tokenManager = api->getTokenManager();
    if (!tokenManager) {
        qWarning() << "[LogosProviderObject] QtProviderObject::informModuleToken: TokenManager not available";
        return false;
    }

    qDebug() << "[LogosProviderObject] QtProviderObject: saving token for module:" << moduleName;
    tokenManager->saveToken(moduleName, token);
    return true;
}

QJsonArray QtProviderObject::getMethods()
{
    if (!m_module) return QJsonArray();

    QJsonArray methodsArray;
    const QMetaObject* metaObject = m_module->metaObject();

    for (int i = 0; i < metaObject->methodCount(); ++i) {
        QMetaMethod method = metaObject->method(i);

        if (method.enclosingMetaObject() != metaObject) {
            continue;
        }

        QJsonObject methodObj;
        methodObj["signature"] = QString::fromUtf8(method.methodSignature());
        methodObj["name"] = QString::fromUtf8(method.name());
        methodObj["returnType"] = QString::fromUtf8(method.typeName());
        methodObj["isInvokable"] = method.isValid() &&
            (method.methodType() == QMetaMethod::Method || method.methodType() == QMetaMethod::Slot);

        if (method.parameterCount() > 0) {
            QJsonArray params;
            for (int p = 0; p < method.parameterCount(); ++p) {
                QJsonObject paramObj;
                paramObj["type"] = QString::fromUtf8(method.parameterTypeName(p));
                QByteArrayList paramNames = method.parameterNames();
                if (p < paramNames.size() && !paramNames.at(p).isEmpty()) {
                    paramObj["name"] = QString::fromUtf8(paramNames.at(p));
                } else {
                    paramObj["name"] = QString("param%1").arg(p);
                }
                params.append(paramObj);
            }
            methodObj["parameters"] = params;
        }

        methodsArray.append(methodObj);
    }

    return methodsArray;
}

#include "moc_qt_provider_object.cpp"
