#include "player.h"
#include "input.h"
#include "remote.h"
#include "videoglass.h"
#include "videosurface.h"
#ifdef NOONIX_SCENE_VIDEO
#include "videoview.h"
#endif
#include "noonix_core/src/bridge.cxxqt.h"

#include <QDir>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlFileSelector>
#include <QtQml/qqml.h>
#include <QQuickWindow>
#include <QScreen>
#include <QSslConfiguration>
#include <QStyleHints>
#include <QSurfaceFormat>
#include <QTimer>
#include <QElapsedTimer>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <thread>
#ifdef Q_OS_ANDROID
#include <QJniEnvironment>
#elif defined(Q_OS_LINUX)
#include <csignal>
#include <ctime>
#include <execinfo.h>
#include <pthread.h>
#include <unistd.h>
#endif

#ifdef Q_OS_ANDROID
extern "C" int av_jni_set_java_vm(void *vm, void *log_ctx);   // libavcodec/jni.h
#endif

namespace {

QScreen *pickScreen()
{
    const QString want = qEnvironmentVariable("NOONIX_OUTPUT", QStringLiteral("HDMI-A-1"));
    for (QScreen *s : QGuiApplication::screens())
        if (s->name() == want)
            return s;
    return QGuiApplication::primaryScreen();
}

} // namespace

// dev: NOONIX_STALL=1 prints the gui thread's stack when it stops answering for 15 ms
#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
namespace {
pthread_t guiThread;
std::atomic<qint64> guiBeat{0};

void dumpStack(int)
{
    void *frames[64];
    const int n = backtrace(frames, 64);
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    char head[64];
    const int len = snprintf(head, sizeof head, "---- gui stall at mono %ld.%03ld\n", long(ts.tv_sec), ts.tv_nsec / 1000000);
    write(2, head, len);
    backtrace_symbols_fd(frames, n, 2);
}

void watchStalls()
{
    guiThread = pthread_self();
    signal(SIGPROF, dumpStack);
    auto *beat = new QTimer;
    auto *clock = new QElapsedTimer;
    clock->start();
    QObject::connect(beat, &QTimer::timeout, [clock] { guiBeat = clock->nsecsElapsed(); });
    beat->start(2);
    std::thread([clock] {
        qint64 reported = -1;
        for (;;) {
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
            const qint64 b = guiBeat;
            if (b && clock->nsecsElapsed() - b > 15'000'000 && b != reported) {
                reported = b;
                pthread_kill(guiThread, SIGPROF);
            }
            // the beat is back: how long the stall was
            if (reported > 0 && b != reported) {
                fprintf(stderr, "---- gui stall lasted %lld ms\n", (long long)((b - reported) / 1'000'000));
                reported = -1;
            }
        }
    }).detach();
}
} // namespace
#endif

int main(int argc, char *argv[])
{
    QGuiApplication::setDesktopFileName(QStringLiteral("noonix-tv"));   // Wayland app_id
    QGuiApplication app(argc, argv);
    // the desktop entry's icon too (Icon=noonix-tv); the grey one while the desktop is dark
    const auto setIcon = [&app] {
        const bool dark = QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
        app.setWindowIcon(QIcon(dark ? QStringLiteral(":/noonix-tv-dark.svg") : QStringLiteral(":/noonix-tv.svg")));
    };
    setIcon();
    QObject::connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, &app, setIcon);
    // the image loaders' threads would each load the ca store lazily, and openssl's first-time
    // setup is not safe to race (crashed in OSSL_DECODER on the first https posters)
    (void)QSslConfiguration::defaultConfiguration().caCertificates();
    app.setApplicationName(QStringLiteral("noonix-tv"));
    app.setApplicationDisplayName(QStringLiteral("Noonix TV"));

#ifdef NOONIX_SCENE_VIDEO
    // mpv renders with opengl inside the scene (VideoView), so qt quick draws with it too. with
    // windows hdr on, mpv gets its own window under ours and ours turns see-through over it
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
#ifdef Q_OS_ANDROID
    // ffmpeg's mediacodec decoders find java through it
    av_jni_set_java_vm(QJniEnvironment::javaVM(), nullptr);
#endif
    const bool nativeVideo = VideoSurface::nativeWanted(pickScreen());
    if (nativeVideo) {
        QSurfaceFormat fmt = QSurfaceFormat::defaultFormat();
        fmt.setAlphaBufferSize(8);
        QSurfaceFormat::setDefaultFormat(fmt);
        QQuickWindow::setDefaultAlphaBuffer(true);
    }
#else
    const bool nativeVideo = false;
    // transparent where the video subsurface shows through
    QSurfaceFormat fmt = QSurfaceFormat::defaultFormat();
    fmt.setAlphaBufferSize(8);
    QSurfaceFormat::setDefaultFormat(fmt);
    QQuickWindow::setDefaultAlphaBuffer(true);
#endif

    Player player(nativeVideo);
    VideoSurface video;
    video.setNativeMode(nativeVideo);
    video.setMpv(player.handle());
    player.setVideo(&video);

    Remote remote;
    Desktop desktop;
    remote.registerService();
    Input input(&remote);

    qmlRegisterType<VideoGlass>("Noonix.Video", 1, 0, "VideoGlass");
#ifdef NOONIX_SCENE_VIDEO
    qmlRegisterType<VideoView>("Noonix.Video", 1, 0, "VideoView");
#endif
    QQmlApplicationEngine engine;
#ifdef NOONIX_SCENE_VIDEO
    // +scene/: the qml for video inside the scene
    (new QQmlFileSelector(&engine, &engine))->setExtraSelectors({QStringLiteral("scene")});
#endif
    desktop.setEngine(&engine);
    engine.rootContext()->setContextProperty(QStringLiteral("Player"), &player);
    engine.rootContext()->setContextProperty(QStringLiteral("Video"), &video);
    engine.rootContext()->setContextProperty(QStringLiteral("Remote"), &remote);
    engine.rootContext()->setContextProperty(QStringLiteral("Desktop"), &desktop);
    engine.rootContext()->setContextProperty(QStringLiteral("Input"), &input);
    engine.rootContext()->setContextProperty(QStringLiteral("Windowed"), qEnvironmentVariableIsSet("NOONIX_WINDOWED"));

    // NOONIX_QML_DIR = live qml from the source tree
    const QString qmlDir = qEnvironmentVariable("NOONIX_QML_DIR");
    const QUrl main = qmlDir.isEmpty() ? QUrl(QStringLiteral("qrc:/qml/Main.qml"))
                                       : QUrl::fromLocalFile(QDir(qmlDir).filePath(QStringLiteral("Main.qml")));
    engine.load(main);
    if (engine.rootObjects().isEmpty())
        return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    window->setScreen(pickScreen());
    window->setGeometry(window->screen()->geometry());
    if (qEnvironmentVariableIsSet("NOONIX_WINDOWED"))
        window->show();
    else
        window->showFullScreen();
    player.setWindow(window);
    remote.setWindow(window);
    input.setWindow(window);
    if (auto *core = engine.singletonInstance<Core *>(QStringLiteral("Noonix.Core"), QStringLiteral("Core")))
        player.setCore(core);
    QObject::connect(&video, &VideoSurface::renderReady, &player, &Player::setRenderReady, Qt::SingleShotConnection);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &player, &Player::shutdown);
    // the wallpaper runs again once we're gone (the kwin reporter skips noonix tv)
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &remote, &Remote::release);
    video.attach(window);
    // now, on another screen and back in focus (hdr may have been switched meanwhile)
    player.reportDisplay();
    QObject::connect(window, &QWindow::screenChanged, &player, &Player::reportDisplay);
    QObject::connect(window, &QWindow::activeChanged, &player, [&player, window] {
        if (window->isActive())
            player.reportDisplay();
    });

    // dev: NOONIX_GRAB="/path/a.png@4000,/path/b.png@9000" saves the window's own frames (works
    // under the screensaver or any other window)
    for (const QString &spec : qEnvironmentVariable("NOONIX_GRAB").split(QLatin1Char(','), Qt::SkipEmptyParts)) {
        const QString path = spec.section(QLatin1Char('@'), 0, 0);
        QString at = spec.section(QLatin1Char('@'), 1, 1);
        int ms = at.toInt();
        // "m<ms>": an absolute monotonic time, so a driver script can line shots up with its keys
        if (at.startsWith(QLatin1Char('m')))
            ms = int(std::max<qint64>(0, at.mid(1).toLongLong() - Desktop::monoMs()));
        QTimer::singleShot(ms, window, [window, path] {
            // the png encode of a 4k frame takes ~0.7 s: keep it off the gui thread
            std::thread([img = window->grabWindow(), path] { img.save(path, nullptr, 100); }).detach();
        });
    }

    QObject::connect(window, &QQuickWindow::frameSwapped, window, [] {
        static bool once = false;
        if (!once) {
            once = true;
            Desktop::devMark(QStringLiteral("first frame"));
        }
    });

#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
    if (qEnvironmentVariableIsSet("NOONIX_STALL"))
        watchStalls();
#endif
    if (qEnvironmentVariableIsSet("NOONIX_STALL"))
        QTimer::singleShot(3000, window, [window] {
            for (QWindow *w : window->findChildren<QWindow *>(Qt::FindDirectChildrenOnly))
                fprintf(stderr, "child window %s %s\n", w->metaObject()->className(), qPrintable(w->objectName()));
        });

    // dev: NOONIX_FPS=1 logs frames per second and the slowest frame of each second
    if (qEnvironmentVariableIsSet("NOONIX_FPS")) {
        auto *clock = new QElapsedTimer;
        auto *frames = new int(0);
        auto *worst = new qint64(0);
        auto *last = new qint64(0);
        auto *slow = new int(0);
        clock->start();
        QObject::connect(window, &QQuickWindow::frameSwapped, window, [=] {
            const qint64 now = clock->nsecsElapsed();
            if (*last) {
                *worst = std::max(*worst, now - *last);
                if (now - *last > 20'000'000) {
                    ++*slow;
                    fprintf(stderr, "gap %.1f ms at mono %.3f\n", (now - *last) / 1e6, Desktop::monoMs() / 1e3);
                }
            }
            *last = now;
            ++*frames;
        }, Qt::DirectConnection);
        auto *t = new QTimer(window);
        QObject::connect(t, &QTimer::timeout, window, [=] {
            if (*frames > 1)
                fprintf(stderr, "fps %d worst %.1f ms slow %d at %.1f s\n", *frames, *worst / 1e6, *slow, clock->elapsed() / 1e3);
            *frames = 0;
            *slow = 0;
            *worst = 0;
        });
        t->start(1000);
    }

    // dev: noonix-tv <file or url> plays it without bookkeeping
    const QStringList args = app.arguments();
    if (args.size() > 1)
        player.playUrl(args.at(1));
    return app.exec();
}
