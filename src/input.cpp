#include "input.h"
#include "remote.h"

#ifdef NOONIX_DBUS
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusServiceWatcher>
#endif
#include <QKeyEvent>
#include <QKeySequence>
#include <QMouseEvent>
#include <QQuickItem>
#include <QQuickWindow>
#ifdef Q_OS_ANDROID
#include <QJniEnvironment>
#include <QJniObject>
#endif

#ifdef NOONIX_SDL
#include <SDL3/SDL.h>
#endif

namespace {
constexpr int holdMs = 650;
constexpr int repeatDelayMs = 380;
constexpr int repeatMs = 110;
#ifdef NOONIX_DBUS
const QString tvRemote = QStringLiteral("local.TvRemote");
#endif

#ifdef NOONIX_SDL
// positional names: the same physical button on every pad, whatever its label
QString buttonName(int b)
{
    switch (b) {
    case SDL_GAMEPAD_BUTTON_SOUTH: return QStringLiteral("south");
    case SDL_GAMEPAD_BUTTON_EAST: return QStringLiteral("east");
    case SDL_GAMEPAD_BUTTON_WEST: return QStringLiteral("west");
    case SDL_GAMEPAD_BUTTON_NORTH: return QStringLiteral("north");
    case SDL_GAMEPAD_BUTTON_BACK: return QStringLiteral("back");
    case SDL_GAMEPAD_BUTTON_START: return QStringLiteral("start");
    case SDL_GAMEPAD_BUTTON_GUIDE: return QStringLiteral("guide");
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return QStringLiteral("lb");
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return QStringLiteral("rb");
    case SDL_GAMEPAD_BUTTON_LEFT_STICK: return QStringLiteral("ls");
    case SDL_GAMEPAD_BUTTON_RIGHT_STICK: return QStringLiteral("rs");
    case SDL_GAMEPAD_BUTTON_TOUCHPAD: return QStringLiteral("touchpad");
    case SDL_GAMEPAD_BUTTON_MISC1: return QStringLiteral("misc1");
    // the d-pad is always the arrows
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return QStringLiteral("UP");
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return QStringLiteral("DOWN");
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return QStringLiteral("LEFT");
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return QStringLiteral("RIGHT");
    default: return {};
    }
}

QString kindOf(SDL_GamepadType t)
{
    switch (t) {
    case SDL_GAMEPAD_TYPE_PS3:
    case SDL_GAMEPAD_TYPE_PS4:
    case SDL_GAMEPAD_TYPE_PS5: return QStringLiteral("playstation");
    case SDL_GAMEPAD_TYPE_XBOX360:
    case SDL_GAMEPAD_TYPE_XBOXONE: return QStringLiteral("xbox");
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR: return QStringLiteral("nintendo");
    default: return QStringLiteral("generic");
    }
}

#endif

// the keys that already mean an action without any binding (never turned into it again: a real
// enter submits the key entry, a posted ok presses the key under the focus)
bool isNative(const QString &action, int key)
{
    static const QHash<QString, QList<int>> native = {
        {QStringLiteral("OK"), {Qt::Key_Return}},
        {QStringLiteral("BACK"), {Qt::Key_Escape, Qt::Key_Back}},
        {QStringLiteral("MENU"), {Qt::Key_Menu}},
        {QStringLiteral("PLAYPAUSE"), {Qt::Key_MediaTogglePlayPause, Qt::Key_MediaPlay, Qt::Key_MediaPause}},
        {QStringLiteral("HOME"), {Qt::Key_HomePage}},
        {QStringLiteral("CH_UP"), {Qt::Key_PageUp}},
        {QStringLiteral("CH_DOWN"), {Qt::Key_PageDown}},
    };
    return native.value(action).contains(key);
}

QStringList list(const QVariant &v)
{
    return v.toStringList();
}

bool isArrow(const QString &b)
{
    return b == QLatin1String("UP") || b == QLatin1String("DOWN") || b == QLatin1String("LEFT") || b == QLatin1String("RIGHT");
}
}

#ifdef Q_OS_ANDROID
namespace {
QPointer<Input> padTarget;

void padFromJava(JNIEnv *, jclass, jstring name, jboolean down, jstring kind)
{
    const QString n = QJniObject(name).toString();
    const QString k = QJniObject(kind).toString();
    QMetaObject::invokeMethod(padTarget, [n, k, down] {
        if (padTarget)
            padTarget->androidPad(n, down, k);
    }, Qt::QueuedConnection);
}
}

void Input::androidPad(const QString &name, bool down, const QString &kind)
{
    setPadKind(kind);
    if (m_remote->inputKind() != QLatin1String("pad"))
        m_remote->InputKind(QStringLiteral("pad"));
    const int source = int(qHash(name) % 64);
    if (down)
        padButton(name, source, true);
    else
        release(source);
}
#endif

Input::Input(Remote *remote, QObject *parent)
    : QObject(parent)
    , m_remote(remote)
{
    m_poll.setInterval(10);
    connect(&m_poll, &QTimer::timeout, this, &Input::poll);
    m_repeat.setSingleShot(true);
    connect(&m_repeat, &QTimer::timeout, this, [this] {
        for (const QString &b : std::as_const(m_held))
            m_remote->Key(b);
        if (!m_held.isEmpty())
            m_repeat.start(repeatMs);
    });
    connect(remote, &Remote::padKey, this, &Input::padKey);
    m_hold.setSingleShot(true);
    m_hold.setInterval(holdMs);
    connect(&m_hold, &QTimer::timeout, this, &Input::holdBack);

#ifdef NOONIX_DBUS
    // the remote daemon reads the pads itself and sends them over d-bus: never both
    auto *watch = new QDBusServiceWatcher(tvRemote, QDBusConnection::sessionBus(),
                                          QDBusServiceWatcher::WatchForRegistration | QDBusServiceWatcher::WatchForUnregistration, this);
    connect(watch, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        if (!qEnvironmentVariableIsSet("NOONIX_PADS"))
            stopPads();
    });
    connect(watch, &QDBusServiceWatcher::serviceUnregistered, this, &Input::startPads);
    // dev: NOONIX_PADS=1 reads them anyway
    // no session bus (windows): nobody else reads them
    QDBusConnectionInterface *bus = QDBusConnection::sessionBus().interface();
    if (qEnvironmentVariableIsSet("NOONIX_PADS") || !bus || !bus->isServiceRegistered(tvRemote))
        startPads();
#else
    startPads();
#endif
#ifdef Q_OS_ANDROID
    padTarget = this;
    const JNINativeMethod methods[] = {
        {"padButton", "(Ljava/lang/String;ZLjava/lang/String;)V", reinterpret_cast<void *>(padFromJava)}};
    QJniEnvironment().registerNativeMethods("io/github/dzeliks/noonixtv/NoonixActivity", methods, 1);
#endif
}

Input::~Input()
{
    stopPads();
}

void Input::setWindow(QWindow *w)
{
    m_window = w;
    w->installEventFilter(this);
}

QVariantMap Input::defaults() const
{
    // nintendo confirms with a on the right, everyone else with the bottom button
    const bool nin = m_padKind == QLatin1String("nintendo");
    QVariantMap pad{
        {QStringLiteral("OK"), QStringList{nin ? QStringLiteral("east") : QStringLiteral("south")}},
        {QStringLiteral("BACK"), QStringList{nin ? QStringLiteral("south") : QStringLiteral("east")}},
        {QStringLiteral("MENU"), QStringList{QStringLiteral("north"), QStringLiteral("back")}},
        {QStringLiteral("PLAYPAUSE"), QStringList{QStringLiteral("west"), QStringLiteral("start")}},
        {QStringLiteral("RW"), QStringList{QStringLiteral("lb")}},
        {QStringLiteral("FF"), QStringList{QStringLiteral("rb")}},
        {QStringLiteral("CH_DOWN"), QStringList{QStringLiteral("lt")}},
        {QStringLiteral("CH_UP"), QStringList{QStringLiteral("rt")}},
        {QStringLiteral("HOME"), QStringList{QStringLiteral("guide")}},
    };
    // youtube's keys where the keyboard has no remote keys
    QVariantMap keys{
        {QStringLiteral("OK"), QStringList{QStringLiteral("Return"), QStringLiteral("Enter")}},
        {QStringLiteral("BACK"), QStringList{QStringLiteral("Esc"), QStringLiteral("Backspace")}},
        {QStringLiteral("MENU"), QStringList{QStringLiteral("M")}},
        {QStringLiteral("PLAYPAUSE"), QStringList{QStringLiteral("Space"), QStringLiteral("K")}},
        {QStringLiteral("RW"), QStringList{QStringLiteral("J")}},
        {QStringLiteral("FF"), QStringList{QStringLiteral("L")}},
        {QStringLiteral("CH_DOWN"), QStringList{QStringLiteral("PgDown")}},
        {QStringLiteral("CH_UP"), QStringList{QStringLiteral("PgUp")}},
        {QStringLiteral("HOME"), QStringList{QStringLiteral("H")}},
    };
    return {{QStringLiteral("pad"), pad}, {QStringLiteral("keys"), keys}};
}

QVariantMap Input::bindings() const
{
    QVariantMap out = defaults();
    for (const QString &side : {QStringLiteral("pad"), QStringLiteral("keys")}) {
        QVariantMap m = out.value(side).toMap();
        const QVariantMap c = m_custom.value(side).toMap();
        for (auto it = c.begin(); it != c.end(); ++it)
            m.insert(it.key(), it.value());
        out.insert(side, m);
    }
    return out;
}

void Input::setBindings(const QVariantMap &custom)
{
    m_custom = custom;
    emit bindingsChanged();
}

void Input::capture(const QString &what)
{
    m_capture = what;
}

void Input::setPadKind(const QString &kind)
{
    if (kind == m_padKind)
        return;
    m_padKind = kind;
    emit padKindChanged();
    emit bindingsChanged();   // nintendo's defaults differ
}

QString Input::padAction(const QString &name) const
{
    const QVariantMap pad = bindings().value(QStringLiteral("pad")).toMap();
    for (auto it = pad.begin(); it != pad.end(); ++it)
        if (list(it.value()).contains(name))
            return it.key();
    return {};
}

QString Input::keyAction(const QKeyEvent *k) const
{
    const QString name = QKeySequence(k->key()).toString(QKeySequence::PortableText);
    const QVariantMap keys = bindings().value(QStringLiteral("keys")).toMap();
    for (auto it = keys.begin(); it != keys.end(); ++it)
        if (list(it.value()).contains(name, Qt::CaseInsensitive))
            return it.key();
    return {};
}

void Input::padKey(const QString &button)
{
    if (m_capture == QLatin1String("pad")) {
        m_capture.clear();
        emit captured(QStringLiteral("pad"), button);
        return;
    }
    const QString action = isArrow(button) ? button : padAction(button);
    if (!action.isEmpty())
        m_remote->Key(action);
}

void Input::setPointing(bool on)
{
    if (on == m_pointing)
        return;
    m_pointing = on;
    emit pointingChanged();
}

bool Input::eventFilter(QObject *obj, QEvent *ev)
{
    if (ev->type() == QEvent::MouseMove) {
        const QPointF p = static_cast<QMouseEvent *>(ev)->globalPosition();
        if (p != m_lastPos) {
            m_lastPos = p;
            m_moved.start();
            setPointing(true);
        }
        return false;
    }
    if (ev->type() != QEvent::KeyPress && ev->type() != QEvent::KeyRelease)
        return QObject::eventFilter(obj, ev);
    auto *k = static_cast<QKeyEvent *>(ev);
    if (ev->type() == QEvent::KeyPress) {
        setPointing(false);
#ifdef Q_OS_ANDROID
        // a tv remote's d-pad centre is enter, a keyboard's enter is return
        m_realKey = ev->spontaneous() && k->key() != Qt::Key_Enter;
#else
        m_realKey = ev->spontaneous();
#endif
    }
    // dev: NOONIX_KEYLOG=1 prints what the platform hands over
    static const bool keyLog = qEnvironmentVariableIsSet("NOONIX_KEYLOG");
    if (keyLog && ev->type() == QEvent::KeyPress)
        qInfo("key 0x%x native %u/%u spontaneous %d", k->key(), k->nativeScanCode(), k->nativeVirtualKey(), int(ev->spontaneous()));
#ifdef Q_OS_ANDROID
    // the system's back is ours (posted as escape); left unaccepted, qt would send the app to the
    // background
    if (k->key() == Qt::Key_Back && ev->spontaneous()) {
        if (ev->type() == QEvent::KeyPress) {
            setPointing(false);
            m_keyBack = QString::number(k->key());
            if (!k->isAutoRepeat()) {
                m_remote->Key(QStringLiteral("BACK"));
                m_escDown.start();
                m_escFired = false;
            } else if (!m_escFired && m_escDown.isValid() && m_escDown.elapsed() >= holdMs) {
                m_escFired = true;
                emit holdBack();
            }
        }
        return true;
    }
#endif
    // remote and pad keys arrive posted; only a real keyboard is bound here
    if (ev->spontaneous() && ev->type() == QEvent::KeyPress) {
        const bool modifierOnly = k->key() == Qt::Key_Shift || k->key() == Qt::Key_Control || k->key() == Qt::Key_Alt || k->key() == Qt::Key_Meta;
        if (!m_capture.isEmpty() && m_capture == QLatin1String("key") && !modifierOnly && !k->isAutoRepeat()) {
            m_capture.clear();
            emit captured(QStringLiteral("key"), k->key() == Qt::Key_Escape ? QString() : QKeySequence(k->key()).toString(QKeySequence::PortableText));
            return true;
        }
#ifdef Q_OS_ANDROID
        // a tv remote's keys come this way too (the d-pad, back, menu, media): no text
        const QString kind = k->text().trimmed().isEmpty() ? QStringLiteral("remote") : QStringLiteral("keyboard");
#else
        const QString kind = QStringLiteral("keyboard");
#endif
        if (m_remote->inputKind() != kind)
            m_remote->InputKind(kind);
        // a text field takes the keys as typed (enter, escape and the arrows still work there)
        bool typing = false;
        if (auto *qw = qobject_cast<QQuickWindow *>(m_window.data()))
            for (QQuickItem *i = qw->activeFocusItem(); i && !typing; i = i->parentItem())
                typing = i->property("typing").toBool();
        const QString action = typing ? QString() : keyAction(k);
        if (!action.isEmpty() && !isNative(action, k->key())) {
            if (action == QLatin1String("BACK"))
                m_keyBack = QString::number(k->key());
            // a held key seeks on; anything else acts once
            if (!k->isAutoRepeat() || action == QLatin1String("RW") || action == QLatin1String("FF"))
                m_remote->Key(action);
            else if (action == QLatin1String("BACK") && !m_escFired && m_escDown.isValid() && m_escDown.elapsed() >= holdMs) {
                m_escFired = true;
                emit holdBack();
            }
            if (!k->isAutoRepeat() && action == QLatin1String("BACK")) {
                m_escDown.start();
                m_escFired = false;
            }
            return true;
        }
    }
    if (k->key() != Qt::Key_Escape && k->key() != Qt::Key_Back)
        return false;
    // a held key repeats; the first press is back as usual, the repeats only count the time
    if (ev->type() == QEvent::KeyPress && !k->isAutoRepeat()) {
        m_escDown.start();
        m_escFired = false;
        return false;
    }
    if (!k->isAutoRepeat())
        return false;
    if (ev->type() == QEvent::KeyPress && !m_escFired && m_escDown.isValid() && m_escDown.elapsed() >= holdMs) {
        m_escFired = true;
        emit holdBack();
    }
    return true;
}

void Input::startPads()
{
    if (m_padsOn)
        return;
#ifdef NOONIX_SDL
    // evdev only: sdl's hidapi drivers repaint the dualsense lightbar
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    // sdl would take sigint / sigterm for itself and noonix tv would never quit on them
    SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    if (!SDL_InitSubSystem(SDL_INIT_GAMEPAD)) {
        qWarning("pads: %s", SDL_GetError());
        return;
    }
    m_padsOn = true;
    m_poll.start();
#endif
}

void Input::stopPads()
{
    if (!m_padsOn)
        return;
    m_poll.stop();
    m_held.clear();
    m_repeat.stop();
    m_hold.stop();
    m_stick.clear();
    m_trigger.clear();
#ifdef NOONIX_SDL
    SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
#endif
    m_padsOn = false;
}

void Input::press(const QString &button, int source)
{
    // a pad in someone's hands while another window is in front isn't for us
    if (!m_window || !m_window->isActive())
        return;
    m_remote->InputKind(QStringLiteral("pad"));
    m_remote->Key(button);
    if (isArrow(button)) {
        m_held.insert(source, button);
        m_repeat.start(repeatDelayMs);
    } else if (button == QLatin1String("BACK")) {
        m_holdSource = source;
        m_hold.start();
    }
}

void Input::release(int source)
{
    m_held.remove(source);
    if (m_held.isEmpty())
        m_repeat.stop();
    if (source == m_holdSource) {
        m_hold.stop();
        m_holdSource = -1;
    }
}

void Input::padButton(const QString &name, int source, bool down)
{
    if (!down || name.isEmpty())
        return;
    if (m_capture == QLatin1String("pad") && !isArrow(name)) {
        if (!m_window || !m_window->isActive())
            return;
        m_capture.clear();
        emit captured(QStringLiteral("pad"), name);
        return;
    }
    const QString action = isArrow(name) ? name : padAction(name);
    if (!action.isEmpty())
        press(action, source);
}

void Input::poll()
{
#ifdef NOONIX_SDL
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        switch (e.type) {
        case SDL_EVENT_GAMEPAD_ADDED:
            if (SDL_Gamepad *g = SDL_OpenGamepad(e.gdevice.which)) {
                qInfo("pad: %s", SDL_GetGamepadName(g));
                // its names in settings right away, not after the first press
                setPadKind(kindOf(SDL_GetGamepadTypeForID(e.gdevice.which)));
            }
            break;
        case SDL_EVENT_GAMEPAD_REMOVED:
            if (SDL_Gamepad *g = SDL_GetGamepadFromID(e.gdevice.which))
                SDL_CloseGamepad(g);
            break;
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
            setPadKind(kindOf(SDL_GetGamepadTypeForID(e.gbutton.which)));
            padButton(buttonName(e.gbutton.button), int(e.gbutton.which) * 64 + e.gbutton.button, true);
            break;
        case SDL_EVENT_GAMEPAD_BUTTON_UP:
            release(int(e.gbutton.which) * 64 + e.gbutton.button);
            break;
        case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
            // the triggers as two more buttons
            if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER || e.gaxis.axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) {
                const bool right = e.gaxis.axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER;
                const int key = int(e.gaxis.which) * 2 + int(right);
                const double v = e.gaxis.value / 32767.0;
                const bool was = m_trigger.value(key);
                if (!was && v > 0.5) {
                    m_trigger.insert(key, true);
                    padButton(right ? QStringLiteral("rt") : QStringLiteral("lt"), 200000 + key, true);
                } else if (was && v < 0.3) {
                    m_trigger.insert(key, false);
                    release(200000 + key);
                }
                break;
            }
            if (e.gaxis.axis != SDL_GAMEPAD_AXIS_LEFTX && e.gaxis.axis != SDL_GAMEPAD_AXIS_LEFTY)
                break;
            // the left stick as a d-pad, with some slack so a resting stick never fires
            const int key = int(e.gaxis.which) * 2 + e.gaxis.axis;
            const double v = e.gaxis.value / 32767.0;
            const int was = m_stick.value(key);
            int now = was;
            if (was == 0 && std::abs(v) > 0.6)
                now = v > 0 ? 1 : -1;
            else if (was != 0 && std::abs(v) < 0.35)
                now = 0;
            if (now == was)
                break;
            m_stick.insert(key, now);
            const int source = 100000 + key;
            release(source);
            if (now != 0) {
                const bool x = e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX;
                press(x ? (now > 0 ? QStringLiteral("RIGHT") : QStringLiteral("LEFT"))
                        : (now > 0 ? QStringLiteral("DOWN") : QStringLiteral("UP")), source);
            }
            break;
        }
        default:
            break;
        }
    }
#endif
}
