#pragma once
// keyboard, mouse and game controllers. pads go through sdl, but only when no remote daemon is on
// the bus (that one feeds us the pads, as PAD:<button> keys) and only while noonix tv is the active
// window. pad buttons and keyboard keys become the remote's actions through bindings settings can change
#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantMap>
#include <QWindow>

class QKeyEvent;

class Remote;

class Input : public QObject
{
    Q_OBJECT
    // the pad used last: playstation | xbox | nintendo | generic (its glyphs)
    Q_PROPERTY(QString padKind READ padKind NOTIFY padKindChanged)
    // {pad: {action: [button]}, keys: {action: [key]}}: what is in use now
    Q_PROPERTY(QVariantMap bindings READ bindings NOTIFY bindingsChanged)
    // the mouse moved the focus last (no key since): lists don't scroll for it, the wheel and keys do
    Q_PROPERTY(bool pointing READ pointing NOTIFY pointingChanged)
public:
    explicit Input(Remote *remote, QObject *parent = nullptr);
    ~Input() override;
    void setWindow(QWindow *w);
    // the mouse really moved just now (qt quick also sends hover when things move under a resting cursor)
    Q_INVOKABLE bool pointerLive() const { return m_moved.isValid() && m_moved.elapsed() < 200; }
    // from pointingChanged: this first key after the mouse only brought the selection back
    Q_INVOKABLE void holdKey() { m_holdKey = true; }
    // the key being handled came from a real keyboard (not a remote's or pad's ok): its enter submits
    Q_INVOKABLE bool realKey() const { return m_realKey; }

    bool pointing() const { return m_pointing; }
    // the wheel moves a page: from now on the mouse is in charge, even if it hasn't moved yet
    Q_INVOKABLE void setPointing(bool on);
    QString padKind() const { return m_padKind; }
    QVariantMap bindings() const;
    // what the user changed ({pad: {...}, keys: {...}}, missing actions keep their defaults)
    Q_INVOKABLE void setBindings(const QVariantMap &custom);
    Q_INVOKABLE QVariantMap defaults() const;
    // "pad" | "key": the next button / key is reported by captured() instead of acting; "" stops
    Q_INVOKABLE void capture(const QString &what);
    // a pad button that the remote daemon forwarded (PAD:<button>): pressed through the bindings
    void padKey(const QString &button);
#ifdef Q_OS_ANDROID
    // a pad button from the activity (android/src/.../NoonixActivity.java)
    void androidPad(const QString &name, bool down, const QString &kind);
#endif

signals:
    // back held for a moment: leave the app
    void holdBack();
    void padKindChanged();
    void bindingsChanged();
    void pointingChanged();
    void captured(const QString &what, const QString &name);

protected:
    bool eventFilter(QObject *obj, QEvent *ev) override;

private:
    void startPads();
    void stopPads();
    void poll();
    void press(const QString &button, int source);
    void release(int source);
    void padButton(const QString &name, int source, bool down);
    QString padAction(const QString &name) const;
    QString keyAction(const QKeyEvent *k) const;
    void setPadKind(const QString &kind);

    Remote *m_remote;
    bool m_realKey = false;
    QPointer<QWindow> m_window;
    QElapsedTimer m_escDown;
    QElapsedTimer m_moved;
    QPointF m_lastPos{-1, -1};
    bool m_escFired = false;
    bool m_pointing = false;
    bool m_holdKey = false;

    bool m_padsOn = false;
    QTimer m_poll;
    // held direction (source id -> button) repeating like the remote does
    QHash<int, QString> m_held;
    QTimer m_repeat;
    QTimer m_hold;
    int m_holdSource = -1;
    QHash<int, int> m_stick;          // pad * 2 + axis -> -1 / 0 / 1
    QHash<int, bool> m_trigger;       // pad * 2 + side -> pressed

    QString m_padKind = QStringLiteral("generic");   // until a pad shows up
    QVariantMap m_custom;
    QString m_capture;
    QString m_keyBack;                // the key bound to back that is down (its hold leaves the app)
};
