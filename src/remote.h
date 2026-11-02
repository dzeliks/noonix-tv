#pragma once
// d-bus local.NoonixTV: the remote daemon sends Key(button) / InputKind(kind) here like it does for
// tv-terminal; buttons become ordinary key events so qml focus handles remote, pad and keyboard alike.
// the remote works while another app has the keyboard: keys go straight in, nothing is activated
#include <QKeyEvent>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QTranslator>
#include <QWindow>

class QQmlEngine;

// on a posted key event: the mouse stands behind it (Remote::pointerKey)
inline constexpr quint32 pointerKeyMark = 0x4e58;

class Remote : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "local.NoonixTV")
    Q_PROPERTY(QString inputKind READ inputKind NOTIFY inputKindChanged)
public:
    explicit Remote(QObject *parent = nullptr);
    void setWindow(QWindow *w);
    // a normal window with its title bar, or fullscreen; shows the window that way
    Q_INVOKABLE void setTitleBar(bool on);
    bool registerService();
    QString inputKind() const { return m_kind; }
    // kwin id of the tv wallpaper window, from the remote daemon's state ("" when there is none)
    Q_INVOKABLE QString wallpaperId();
    // tell the screensaver whether we hide its wallpaper (paused) or show it through glass
    Q_INVOKABLE void setCovered(bool covered);
    // tell it our glass shows the wallpaper (its clock fades away meanwhile)
    Q_INVOKABLE void setGlass(bool on);
    void release();

protected:
    bool eventFilter(QObject *obj, QEvent *ev) override;

private:
    // raise() on purpose (a second start, the quick menu): take the keyboard too. keys never do
    void activate();

public slots:
    Q_SCRIPTABLE void Key(const QString &button);
    // a key the mouse stands for (a click is ok, right click is back): the mouse stays in charge
    Q_INVOKABLE void pointerKey(const QString &button);
    Q_SCRIPTABLE void InputKind(const QString &kind);
    // the remote daemon: ok is down / up (key() alone says nothing about a hold)
    Q_SCRIPTABLE void OkHeld(bool down) { emit okHeld(down); }
    Q_SCRIPTABLE void Raise();
    // test runs only (NOONIX_TEST=1): the mouse moves to x, y in the window, a left click there
    Q_SCRIPTABLE void Pointer(double x, double y);
    Q_SCRIPTABLE void Click(double x, double y);
    Q_SCRIPTABLE void Button(double x, double y, int button);
    Q_SCRIPTABLE void Wheel(double x, double y, int dx, int dy);
    Q_SCRIPTABLE void Press(int key, const QString &text);
    Q_SCRIPTABLE void Grab(const QString &path);
    // the overlay: its launch card has dissolved over our splash, the splash can play
    Q_SCRIPTABLE void Revealed() { emit revealed(); }

signals:
    void inputKindChanged();
    void revealed();
    void padKey(const QString &button);
    void okHeld(bool down);

private:
    bool m_covered = false;
    bool m_glass = false;
    bool m_alt = false;
    bool m_refull = false;
    bool m_titleBar = false;
    bool m_keyFromPointer = false;
    QPointer<QWindow> m_window;
    QString m_kind = QStringLiteral("remote");
};

class Desktop : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool debug READ debug CONSTANT)
    // dev: NOONIX_PLAY='{"kind":"show","tmdb":85552,"season":1,"episode":3}' plays it at start
    // (with "stream": {...} that exact source)
    Q_PROPERTY(QString devPlay READ devPlay CONSTANT)
    // dev: NOONIX_SPLASH=0 starts without the launch splash
    Q_PROPERTY(bool splash READ splash CONSTANT)
    Q_PROPERTY(double splashSlow READ splashSlow CONSTANT)
    // NOONIX_SPLASH_FAST=1: no intro, the splash starts on the pink with the name in place
    Q_PROPERTY(bool splashFast READ splashFast CONSTANT)
    // ui language: "en" | "sr" (serbian, latin). systemLanguage = what the pc's locale suggests
    Q_PROPERTY(QString language READ language NOTIFY languageChanged)
    Q_PROPERTY(QString systemLanguage READ systemLanguage CONSTANT)
public:
    using QObject::QObject;
    void setEngine(QQmlEngine *e) { m_engine = e; }
    QString language() const { return m_language; }
    QString systemLanguage() const;
    // swaps the translation and re-reads every qsTr() on screen
    Q_INVOKABLE void setLanguage(const QString &code);
    bool debug() const { return qEnvironmentVariableIsSet("NOONIX_DEBUG"); }
    QString devPlay() const { return qEnvironmentVariable("NOONIX_PLAY"); }
    bool splash() const { return qEnvironmentVariable("NOONIX_SPLASH") != QLatin1String("0"); }
    bool splashFast() const { return qEnvironmentVariable("NOONIX_SPLASH_FAST") == QLatin1String("1"); }
    double splashSlow() const { return qEnvironmentVariableIsSet("NOONIX_SPLASH_SLOW") ? qEnvironmentVariable("NOONIX_SPLASH_SLOW").toDouble() : 1.0; }
    Q_INVOKABLE void copy(const QString &text);
    Q_INVOKABLE QString paste() const;
    // android: asks once for the videos on shared storage (the library's folders); elsewhere nothing
    Q_INVOKABLE void askMedia();
    // the desktop's wallpaper picture as a url, "" when there's none (windows only for now)
    Q_INVOKABLE QString wallpaper() const;
    // dev (NOONIX_FPS): "mark <name> at <ms since the process started>" on stderr
    Q_INVOKABLE void mark(const QString &name) { devMark(name); }
    static void devMark(const QString &name);
    // the monotonic clock in ms (CLOCK_MONOTONIC on linux), what driver scripts line shots up with
    static qint64 monoMs();
signals:
    void languageChanged();
private:
    QQmlEngine *m_engine = nullptr;
    QTranslator m_translator;
    QString m_language = QStringLiteral("en");
};
