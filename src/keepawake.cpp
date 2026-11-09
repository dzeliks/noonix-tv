#include "keepawake.h"

#include <QCoreApplication>

#if defined(Q_OS_ANDROID)
#include <QJniObject>
#elif defined(Q_OS_WIN)
#include <windows.h>
#elif defined(Q_OS_LINUX)
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#endif

namespace KeepAwake {

static bool held = false;

#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
// org.freedesktop.ScreenSaver (kde, gnome, xfce...): the cookie lifts it; the bus drops it if we die
static quint32 cookie = 0;
static bool asking = false;

static QDBusMessage saver(const QString &method)
{
    return QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.ScreenSaver"), QStringLiteral("/org/freedesktop/ScreenSaver"),
                                          QStringLiteral("org.freedesktop.ScreenSaver"), method);
}

static void apply()
{
    if (asking)
        return;
    if (held && !cookie) {
        QDBusMessage m = saver(QStringLiteral("Inhibit"));
        m << QStringLiteral("noonix-tv") << QStringLiteral("Playing a video");
        asking = true;
        auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m, 3000), qApp);
        QObject::connect(w, &QDBusPendingCallWatcher::finished, qApp, [](QDBusPendingCallWatcher *w) {
            QDBusPendingReply<quint32> r = *w;
            w->deleteLater();
            asking = false;
            if (!r.isError())
                cookie = r.value();
            apply(); // it may have stopped meanwhile
        });
    } else if (!held && cookie) {
        QDBusMessage m = saver(QStringLiteral("UnInhibit"));
        m << cookie;
        cookie = 0;
        QDBusConnection::sessionBus().asyncCall(m, 3000);
    }
}
#endif

void set(bool on)
{
    if (on == held)
        return;
    held = on;
#if defined(Q_OS_ANDROID)
    QNativeInterface::QAndroidApplication::runOnAndroidMainThread([on] {
        QJniObject activity = QJniObject(QNativeInterface::QAndroidApplication::context());
        QJniObject window = activity.callObjectMethod("getWindow", "()Landroid/view/Window;");
        if (window.isValid())
            window.callMethod<void>(on ? "addFlags" : "clearFlags", "(I)V", 128); // FLAG_KEEP_SCREEN_ON
    });
#elif defined(Q_OS_WIN)
    SetThreadExecutionState(on ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
#elif defined(Q_OS_LINUX)
    apply();
#endif
}

} // namespace KeepAwake
