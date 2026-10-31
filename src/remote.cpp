#include "remote.h"

// qt says linux on android too: this is the desktop's (wayland, kwin, the session bus)
#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
#define NOONIX_DESKTOP_LINUX
#endif

#include <chrono>
#ifdef Q_OS_LINUX
#include <ctime>
#include <unistd.h>
#endif
#ifdef NOONIX_DESKTOP_LINUX
#include <qpa/qwindowsysteminterface.h>
#elif defined(Q_OS_WIN)
#include <windows.h>
#endif

#include <QClipboard>
#include <QFile>
#include <QCoreApplication>
#include <QDateTime>
#ifdef NOONIX_DBUS
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusReply>
#endif
#include <QJsonDocument>
#include <QJsonObject>
#include <QGuiApplication>
#include <QHash>
#include <QKeyEvent>
#include <QLocale>
#include <QMouseEvent>
#include <QQmlEngine>
#include <QStandardPaths>
#include <QUrl>

Remote::Remote(QObject *parent)
    : QObject(parent)
{
}

void Remote::setWindow(QWindow *w)
{
    m_window = w;
    w->installEventFilter(this);
}

// qt drops the focused item when the window loses the keyboard: keep it, so remote keys still
// land (and the focus ring stays) while someone types in another app
bool Remote::eventFilter(QObject *obj, QEvent *ev)
{
    if (obj == m_window && ev->type() == QEvent::FocusOut)
        return true;
    return QObject::eventFilter(obj, ev);
}

void Remote::activate()
{
    m_window->requestActivate();
#ifdef NOONIX_DESKTOP_LINUX
    // wayland only lets the compositor move focus: a one-line kwin script does it on plasma
    static const QString script = [] {
        const QString path = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation)
            + QStringLiteral("/noonix-tv-activate.js");
        QFile f(path);
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
            f.write(QStringLiteral("for (const w of workspace.windowList()) if (w.pid === %1 && w.normalWindow) workspace.activeWindow = w;\n")
                        .arg(QCoreApplication::applicationPid()).toUtf8());
        return path;
    }();
    // async: one connection keeps the order, and the gui never waits on kwin
    auto call = [](const QString &method, const QVariantList &args) {
        QDBusMessage m = QDBusMessage::createMethodCall(QStringLiteral("org.kde.KWin"), QStringLiteral("/Scripting"),
                                                        QStringLiteral("org.kde.kwin.Scripting"), method);
        m.setArguments(args);
        QDBusConnection::sessionBus().asyncCall(m);
    };
    call(QStringLiteral("unloadScript"), {QStringLiteral("noonix-tv-activate")});
    call(QStringLiteral("loadScript"), {script, QStringLiteral("noonix-tv-activate")});
    call(QStringLiteral("start"), {});
    call(QStringLiteral("unloadScript"), {QStringLiteral("noonix-tv-activate")});
#endif
}

bool Remote::registerService()
{
#ifndef NOONIX_DBUS
    return false;
#else
    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerService(QStringLiteral("local.NoonixTV")))
        return false;
    return bus.registerObject(QStringLiteral("/local/NoonixTV"), this, QDBusConnection::ExportScriptableSlots);
#endif
}

QString Remote::wallpaperId()
{
#ifdef NOONIX_DESKTOP_LINUX
    QDBusMessage m = QDBusMessage::createMethodCall(QStringLiteral("local.TvRemote"), QStringLiteral("/"),
                                                    QStringLiteral("local.TvRemote"), QStringLiteral("State"));
    QDBusReply<QString> r = QDBusConnection::sessionBus().call(m, QDBus::Block, 1500);
    if (!r.isValid())
        return {};
    return QJsonDocument::fromJson(r.value().toUtf8()).object().value(QStringLiteral("bg")).toObject()
        .value(QStringLiteral("id")).toString();
#else
    return {};   // the tv wallpaper comes from the remote daemon, a linux piece
#endif
}

void Remote::setCovered(bool covered)
{
    m_covered = covered;
#ifdef NOONIX_DBUS
    QDBusMessage m = QDBusMessage::createMethodCall(QStringLiteral("local.TvScreensaver"), QStringLiteral("/local/TvScreensaver"),
                                                    QStringLiteral("local.TvScreensaver"), QStringLiteral("SetCovered"));
    m.setArguments({covered});
    QDBusConnection::sessionBus().asyncCall(m);
#endif
}

void Remote::setGlass(bool on)
{
    m_glass = on;
#ifdef NOONIX_DBUS
    QDBusMessage m = QDBusMessage::createMethodCall(QStringLiteral("local.TvScreensaver"), QStringLiteral("/local/TvScreensaver"),
                                                    QStringLiteral("local.TvScreensaver"), QStringLiteral("SetGlass"));
    m.setArguments({QStringLiteral("noonix-tv"), on});
    QDBusConnection::sessionBus().asyncCall(m);
#endif
}

void Remote::release()
{
    if (m_glass)
        setGlass(false);
    // only take back what we said: noonix tv on a desk monitor never told the tv anything
    if (m_covered)
        setCovered(false);
}

void Remote::Key(const QString &button)
{
    static const QHash<QString, int> keys = {
        {QStringLiteral("UP"), Qt::Key_Up},
        {QStringLiteral("DOWN"), Qt::Key_Down},
        {QStringLiteral("LEFT"), Qt::Key_Left},
        {QStringLiteral("RIGHT"), Qt::Key_Right},
        {QStringLiteral("OK"), Qt::Key_Return},
        {QStringLiteral("BACK"), Qt::Key_Escape},
        {QStringLiteral("MENU"), Qt::Key_Menu},
        {QStringLiteral("SELECT"), Qt::Key_Menu},
        {QStringLiteral("CREATE"), Qt::Key_Menu},
        {QStringLiteral("INFO"), Qt::Key_Menu},
        {QStringLiteral("HOME"), Qt::Key_HomePage},
        {QStringLiteral("PLAYPAUSE"), Qt::Key_MediaTogglePlayPause},
        {QStringLiteral("STOP"), Qt::Key_MediaStop},
        {QStringLiteral("FF"), Qt::Key_AudioForward},
        {QStringLiteral("RW"), Qt::Key_AudioRewind},
        {QStringLiteral("NEXT"), Qt::Key_MediaNext},
        {QStringLiteral("PREV"), Qt::Key_MediaPrevious},
        {QStringLiteral("CH_UP"), Qt::Key_PageUp},
        {QStringLiteral("CH_DOWN"), Qt::Key_PageDown},
    };
    // a pad button by position (remote daemon): the bindings decide what it does
    if (button.startsWith(QLatin1String("PAD:"))) {
        emit padKey(button.mid(4).toLower());
        return;
    }
    const auto it = keys.find(button.toUpper());
    if (it == keys.end() || !m_window)
        return;
    const int k = it.value();
    const QString text = k == Qt::Key_Return ? QStringLiteral("\r") : QString();
    // a dialog of ours on top (a folder or file picker) takes the keys, not the page behind it
    QWindow *to = QGuiApplication::modalWindow() ? QGuiApplication::modalWindow() : m_window.data();
    QCoreApplication::postEvent(to, new QKeyEvent(QEvent::KeyPress, k, Qt::NoModifier, text));
    QCoreApplication::postEvent(to, new QKeyEvent(QEvent::KeyRelease, k, Qt::NoModifier, text));
}

void Remote::Pointer(double x, double y)
{
    if (!m_window || qgetenv("NOONIX_TEST") != "1")
        return;
    const QPointF at(x, y);
#ifdef NOONIX_DESKTOP_LINUX
    QWindowSystemInterface::handleMouseEvent(m_window, at, m_window->mapToGlobal(at), Qt::NoButton, Qt::NoButton, QEvent::MouseMove);
#else
    QCoreApplication::postEvent(m_window, new QMouseEvent(QEvent::MouseMove, at, m_window->mapToGlobal(at), Qt::NoButton, Qt::NoButton, Qt::NoModifier));
#endif
}

void Remote::Click(double x, double y)
{
    if (!m_window || qgetenv("NOONIX_TEST") != "1")
        return;
#ifdef NOONIX_DESKTOP_LINUX
    // through qt's own input path, like a real mouse (press positions and grabs as they'd be)
    const QPointF at(x, y);
    QWindowSystemInterface::handleMouseEvent(m_window, at, m_window->mapToGlobal(at), Qt::LeftButton, Qt::LeftButton, QEvent::MouseButtonPress);
    QWindowSystemInterface::handleMouseEvent(m_window, at, m_window->mapToGlobal(at), Qt::NoButton, Qt::LeftButton, QEvent::MouseButtonRelease);
#else
    Q_UNUSED(x) Q_UNUSED(y)
#endif
}

void Remote::InputKind(const QString &kind)
{
    if (kind == m_kind)
        return;
    m_kind = kind;
    emit inputKindChanged();
}

void Remote::Raise()
{
    if (m_window) {
        // show() means "show normal": it would drop fullscreen and the window would resize mid-splash
        if (qEnvironmentVariableIsSet("NOONIX_WINDOWED"))
            m_window->show();
        else
            m_window->showFullScreen();
        m_window->raise();
        activate();
    }
}

void Desktop::devMark(const QString &name)
{
    static const bool on = qEnvironmentVariableIsSet("NOONIX_FPS");
    if (!on)
        return;
#ifdef Q_OS_LINUX
    // field 22 of /proc/self/stat = start time in clock ticks since boot
    static const double started = [] {
        QFile f(QStringLiteral("/proc/self/stat"));
        if (!f.open(QIODevice::ReadOnly))
            return 0.0;
        const QByteArray stat = f.readAll();
        const QList<QByteArray> rest = stat.mid(stat.lastIndexOf(')') + 2).split(' ');
        return rest.size() > 19 ? rest.at(19).toDouble() * 1000.0 / sysconf(_SC_CLK_TCK) : 0.0;
    }();
    timespec now;
    clock_gettime(CLOCK_BOOTTIME, &now);
    const double ms = now.tv_sec * 1000.0 + now.tv_nsec / 1e6 - started;
#elif defined(Q_OS_WIN)
    // the process's creation time (filetime: 100 ns since 1601)
    static const qint64 started = [] {
        FILETIME created, exited, kernel, user;
        if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user))
            return QDateTime::currentMSecsSinceEpoch();
        const quint64 t = (quint64(created.dwHighDateTime) << 32) | created.dwLowDateTime;
        return qint64(t / 10000) - 11644473600000LL;
    }();
    const double ms = double(QDateTime::currentMSecsSinceEpoch() - started);
#endif
    fprintf(stderr, "mark %s at %.0f ms (mono %.3f)\n", qPrintable(name), ms, monoMs() / 1e3);
}

qint64 Desktop::monoMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

QString Desktop::systemLanguage() const
{
    return QLocale::system().language() == QLocale::Serbian ? QStringLiteral("sr") : QStringLiteral("en");
}

void Desktop::setLanguage(const QString &code)
{
    const QString lang = code == QLatin1String("sr") ? code : QStringLiteral("en");
    if (lang == m_language)
        return;
    QCoreApplication::removeTranslator(&m_translator);
    if (lang == QLatin1String("sr") && m_translator.load(QStringLiteral(":/i18n/noonix-tv_sr_Latn.qm"))) {
        QCoreApplication::installTranslator(&m_translator);
        QLocale::setDefault(QLocale(QLocale::Serbian, QLocale::LatinScript, QLocale::Serbia));
    } else {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
    }
    m_language = lang;
    if (m_engine)
        m_engine->retranslate();
    emit languageChanged();
}

void Desktop::copy(const QString &text)
{
    QGuiApplication::clipboard()->setText(text);
}

QString Desktop::paste() const
{
    return QGuiApplication::clipboard()->text().trimmed();
}

QString Desktop::wallpaper() const
{
#ifdef Q_OS_WIN
    wchar_t path[MAX_PATH] = {};
    if (SystemParametersInfoW(SPI_GETDESKWALLPAPER, MAX_PATH, path, 0) && path[0] && QFile::exists(QString::fromWCharArray(path)))
        return QUrl::fromLocalFile(QString::fromWCharArray(path)).toString();
#endif
    return {};
}
