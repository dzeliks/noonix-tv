#include <QQuickWindow>
#include <thread>
#include "remote.h"

// qt says linux on android too: this is the desktop's (wayland, kwin, the session bus)
#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
#define NOONIX_DESKTOP_LINUX
#endif

#include <chrono>
#ifdef Q_OS_LINUX
#include <ctime>
#endif
#ifndef Q_OS_WIN
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
#ifdef Q_OS_ANDROID
#include <QJniObject>
#endif
#include <QJsonObject>
#include <QGuiApplication>
#include <QHash>
#include <QKeyEvent>
#include <QLocale>
#include <QMouseEvent>
#include <QPointingDevice>
#include <QQmlEngine>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

Remote::Remote(QObject *parent)
    : QObject(parent)
{
}

void Remote::setWindow(QWindow *w)
{
    m_window = w;
    w->installEventFilter(this);
    connect(w, &QWindow::visibilityChanged, this, &Remote::fullScreenChanged);
}

// qt drops the focused item when the window loses the keyboard: keep it, so remote keys still
// land (and the focus ring stays) while someone types in another app. alt held as the keyboard
// goes is alt-tab: the compositor keeps the release, and a fullscreen window goes down like a game
bool Remote::eventFilter(QObject *obj, QEvent *ev)
{
    if (obj != m_window)
        return QObject::eventFilter(obj, ev);
    switch (ev->type()) {
    case QEvent::KeyPress:
    case QEvent::KeyRelease:
        if (static_cast<QKeyEvent *>(ev)->key() == Qt::Key_Alt)
            m_alt = ev->type() == QEvent::KeyPress;
        break;
    case QEvent::FocusIn:
        m_alt = false;
        // windows brings a minimized window back as a normal one
        if (m_refull) {
            m_refull = false;
            QTimer::singleShot(0, m_window, [w = m_window] { if (w) w->showFullScreen(); });
        }
        break;
    case QEvent::FocusOut:
#ifndef Q_OS_ANDROID
        if (m_alt && m_window->visibility() == QWindow::FullScreen) {
            m_refull = true;
            QTimer::singleShot(0, m_window, [w = m_window] { if (w) w->showMinimized(); });
        }
#endif
        m_alt = false;
        return true;
    default:
        break;
    }
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
            f.write(QStringLiteral("for (const w of workspace.windowList()) if (w.pid === %1 && w.normalWindow) { w.minimized = false; workspace.activeWindow = w; }\n")
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
    // kwin reads the file in the background: unloaded right away it never runs
    QTimer::singleShot(1000, this, [call] { call(QStringLiteral("unloadScript"), {QStringLiteral("noonix-tv-activate")}); });
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
    const quint32 mark = m_keyFromPointer ? pointerKeyMark : 0;
    QCoreApplication::postEvent(to, new QKeyEvent(QEvent::KeyPress, k, Qt::NoModifier, 0, mark, 0, text));
    QCoreApplication::postEvent(to, new QKeyEvent(QEvent::KeyRelease, k, Qt::NoModifier, 0, mark, 0, text));
}

void Remote::pointerKey(const QString &button)
{
    m_keyFromPointer = true;
    Key(button);
    m_keyFromPointer = false;
}

// dev: the window's own frame, no compositor involved (never hitches what else is on screen)
void Remote::Grab(const QString &path)
{
    auto *w = qobject_cast<QQuickWindow *>(m_window.data());
    if (!w || qgetenv("NOONIX_TEST") != "1")
        return;
    std::thread([img = w->grabWindow(), path] { img.save(path, nullptr, 90); }).detach();
}

// dev: a press that stays
void Remote::Hold(double x, double y, int ms)
{
    if (!m_window || qgetenv("NOONIX_TEST") != "1")
        return;
#ifdef NOONIX_DESKTOP_LINUX
    const QPointF at(x, y);
    const QPointF global = m_window->mapToGlobal(at);
    QWindowSystemInterface::handleMouseEvent(m_window, at, global, Qt::LeftButton, Qt::LeftButton, QEvent::MouseButtonPress);
    QTimer::singleShot(ms, this, [this, at, global] {
        QWindowSystemInterface::handleMouseEvent(m_window, at, global, Qt::NoButton, Qt::LeftButton, QEvent::MouseButtonRelease);
    });
#endif
}

void Remote::Swipe(double x1, double y1, double x2, double y2, int ms, int rest)
{
    if (!m_window || qgetenv("NOONIX_TEST") != "1")
        return;
#ifdef NOONIX_DESKTOP_LINUX
    // a touch screen of our own, so qt treats it like a phone's
    static QPointingDevice *dev = [] {
        auto *d = new QPointingDevice(QStringLiteral("noonix-test-touch"), 0x7e57, QInputDevice::DeviceType::TouchScreen,
                                      QPointingDevice::PointerType::Finger, QInputDevice::Capability::Position | QInputDevice::Capability::Area,
                                      1, 0);
        QWindowSystemInterface::registerInputDevice(d);
        return d;
    }();
    const int steps = qMax(1, ms / 16);
    auto send = [this](QPointF at, QEventPoint::State st) {
        QWindowSystemInterface::TouchPoint p;
        p.id = 1;
        p.state = st;
        const QPointF g = m_window->mapToGlobal(at);
        p.area = QRectF(g.x() - 4, g.y() - 4, 8, 8);
        p.normalPosition = QPointF(at.x() / m_window->width(), at.y() / m_window->height());
        p.pressure = st == QEventPoint::State::Released ? 0 : 1;
        QWindowSystemInterface::handleTouchEvent(m_window, dev, { p });
    };
    send(QPointF(x1, y1), QEventPoint::State::Pressed);
    for (int i = 1; i <= steps; ++i) {
        const double f = double(i) / steps;
        const QPointF at(x1 + (x2 - x1) * f, y1 + (y2 - y1) * f);
        QTimer::singleShot(i * 16, this, [send, at] { send(at, QEventPoint::State::Updated); });
    }
    QTimer::singleShot(steps * 16 + qMax(0, rest), this, [send, x2, y2] { send(QPointF(x2, y2), QEventPoint::State::Released); });
#else
    Q_UNUSED(x1) Q_UNUSED(y1) Q_UNUSED(x2) Q_UNUSED(y2) Q_UNUSED(ms) Q_UNUSED(rest)
#endif
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

// dev (NOONIX_TEST): the other mouse buttons, the wheel and a real keyboard's keys, through qt's own input path
void Remote::Button(double x, double y, int button)
{
    if (!m_window || qgetenv("NOONIX_TEST") != "1")
        return;
#ifdef NOONIX_DESKTOP_LINUX
    const QPointF at(x, y);
    const auto b = Qt::MouseButton(button);
    QWindowSystemInterface::handleMouseEvent(m_window, at, m_window->mapToGlobal(at), b, b, QEvent::MouseButtonPress);
    QWindowSystemInterface::handleMouseEvent(m_window, at, m_window->mapToGlobal(at), Qt::NoButton, b, QEvent::MouseButtonRelease);
#else
    Q_UNUSED(x) Q_UNUSED(y) Q_UNUSED(button)
#endif
}

void Remote::Wheel(double x, double y, int dx, int dy)
{
    if (!m_window || qgetenv("NOONIX_TEST") != "1")
        return;
#ifdef NOONIX_DESKTOP_LINUX
    const QPointF at(x, y);
    QWindowSystemInterface::handleWheelEvent(m_window, at, m_window->mapToGlobal(at), QPoint(), QPoint(dx, dy));
#else
    Q_UNUSED(x) Q_UNUSED(y) Q_UNUSED(dx) Q_UNUSED(dy)
#endif
}

void Remote::Press(int key, const QString &text)
{
    if (!m_window || qgetenv("NOONIX_TEST") != "1")
        return;
#ifdef NOONIX_DESKTOP_LINUX
    // modifiers ride in the key's high bits (ctrl+a = Qt::Key_A | Qt::ControlModifier)
    const auto mods = Qt::KeyboardModifiers(key & int(Qt::KeyboardModifierMask));
    key &= ~int(Qt::KeyboardModifierMask);
    QWindowSystemInterface::handleKeyEvent(m_window, QEvent::KeyPress, key, mods, text);
    QWindowSystemInterface::handleKeyEvent(m_window, QEvent::KeyRelease, key, mods, text);
#else
    Q_UNUSED(key) Q_UNUSED(text)
#endif
}

void Remote::InputKind(const QString &kind)
{
    if (kind == m_kind)
        return;
    m_kind = kind;
    emit inputKindChanged();
}

void Remote::setTitleBar(bool on)
{
    m_titleBar = on;
    emit fullScreenChanged();
    if (!on) {
        m_window->showFullScreen();
        return;
    }
    // three quarters of the screen, in its middle
    const QRect screen = m_window->screen()->geometry();
    QRect r(QPoint(), screen.size() * 3 / 4);
    r.moveCenter(screen.center());
    m_window->setMinimumSize(QSize(960, 540));
    m_window->setGeometry(r);
    m_window->showNormal();
}

bool Remote::fullScreen() const
{
    return m_window && m_window->visibility() == QWindow::FullScreen;
}

void Remote::toggleFullScreen()
{
    if (!m_window)
        return;
    if (!fullScreen()) {
        m_window->showFullScreen();
        return;
    }
    // back to the window it was, or three quarters of the screen the first time
    const QRect screen = m_window->screen()->geometry();
    QRect r(QPoint(), screen.size() * 3 / 4);
    r.moveCenter(screen.center());
    m_window->setMinimumSize(QSize(960, 540));
    m_window->showNormal();
    // a window as big as the screen isn't one you can see as a window
    if (m_window->width() * 10 >= screen.width() * 9 && m_window->height() * 10 >= screen.height() * 9)
        m_window->setGeometry(r);
}

void Remote::Raise()
{
    if (m_window) {
        // show() means "show normal": it would drop fullscreen and the window would resize mid-splash
        if (!m_titleBar)
            m_window->showFullScreen();
        else if (m_window->visibility() == QWindow::Minimized)
            m_window->showNormal();
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

int Desktop::totalRamMb() const
{
    static const int mb = [] {
        // dev: NOONIX_RAM_MB=2048 plays a small machine
        if (qEnvironmentVariableIsSet("NOONIX_RAM_MB"))
            return qEnvironmentVariableIntValue("NOONIX_RAM_MB");
#if defined(Q_OS_WIN)
        MEMORYSTATUSEX m{};
        m.dwLength = sizeof(m);
        return GlobalMemoryStatusEx(&m) ? int(m.ullTotalPhys >> 20) : 0;
#else
        const long pages = sysconf(_SC_PHYS_PAGES), size = sysconf(_SC_PAGE_SIZE);
        return pages > 0 && size > 0 ? int((qint64(pages) * size) >> 20) : 0;
#endif
    }();
    return mb;
}

bool Desktop::lowRam() const
{
    static const bool on = [this] {
        if (qEnvironmentVariableIsSet("NOONIX_LOWRAM"))
            return qEnvironmentVariable("NOONIX_LOWRAM") == QLatin1String("1");
#ifdef Q_OS_ANDROID
        const QJniObject am = QJniObject(QNativeInterface::QAndroidApplication::context())
                                  .callObjectMethod("getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;",
                                                    QJniObject::fromString(QStringLiteral("activity")).object<jstring>());
        if (am.isValid() && am.callMethod<jboolean>("isLowRamDevice"))
            return true;
        // a "2 gb" phone reports a little under 2048 (the kernel keeps some)
        return phone() && totalRamMb() > 0 && totalRamMb() < 2600;
#else
        return false;
#endif
    }();
    return on;
}

bool Desktop::phone() const
{
    static const bool on = [] {
        if (qEnvironmentVariableIsSet("NOONIX_PHONE"))
            return qEnvironmentVariable("NOONIX_PHONE") == QLatin1String("1");
#ifdef Q_OS_ANDROID
        const int sw = QJniObject(QNativeInterface::QAndroidApplication::context())
                           .callObjectMethod("getResources", "()Landroid/content/res/Resources;")
                           .callObjectMethod("getConfiguration", "()Landroid/content/res/Configuration;")
                           .getField<jint>("smallestScreenWidthDp");
        return sw > 0 && sw < 600;
#else
        return false;
#endif
    }();
    return on;
}

bool Desktop::tv() const
{
    static const bool on = [] {
#ifdef Q_OS_ANDROID
        return bool(QJniObject(QNativeInterface::QAndroidApplication::context())
                        .callObjectMethod("getPackageManager", "()Landroid/content/pm/PackageManager;")
                        .callMethod<jboolean>("hasSystemFeature", "(Ljava/lang/String;)Z",
                                              QJniObject::fromString(QStringLiteral("android.software.leanback")).object<jstring>()));
#else
        return false;
#endif
    }();
    return on;
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

void Desktop::askMedia()
{
#ifdef Q_OS_ANDROID
    QNativeInterface::QAndroidApplication::context().callMethod<void>("askMedia");
#endif
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
