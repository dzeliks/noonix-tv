#pragma once
// mpv video. linux: its own wl_subsurface below the qt surface, rendered by libmpv on a
// separate egl thread, with its own colour description (pq for hdr10, gamma 2.2 for sdr).
// windows: VideoView draws it inside qt quick's opengl scene, in sdr (hdr is tone mapped). with
// windows hdr on for the screen, mpv draws in its own d3d11 window right under the app instead
// (native: real hdr10), and the app is see-through while video is up. android: in the scene too
#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QSize>
#include <QString>
#include <QVariantMap>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

// mpv drawn inside qt quick's opengl scene (VideoView) instead of a wayland subsurface
#if defined(Q_OS_WIN) || defined(Q_OS_ANDROID)
#define NOONIX_SCENE_VIDEO
#endif

class QQuickItem;
class QQuickWindow;
class QScreen;
struct mpv_handle;
struct mpv_render_context;
struct wl_display;
struct wl_event_queue;
struct wl_surface;
struct wl_subsurface;
struct wl_compositor;
struct wl_subcompositor;
struct wp_color_manager_v1;
struct wp_color_management_surface_v1;
struct wp_image_description_v1;

class VideoSurface : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantMap colour READ colour NOTIFY colourChanged)
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(bool native READ isNative CONSTANT)
public:
    explicit VideoSurface(QObject *parent = nullptr);
    ~VideoSurface() override;

    // vo=libmpv handle owned by the caller, set before attach()
    void setMpv(mpv_handle *mpv) { m_mpv = mpv; }
    void attach(QQuickWindow *window);
    void detach();

    QVariantMap colour() const { return m_colour; }
    bool active() const { return m_active; }
    bool isNative() const { return m_nativeMode; }
    // windows: mpv in its own window under the app (decided before the player starts: its vo).
    // NOONIX_VIDEO=native|scene overrides what the screen's hdr state says
    static bool nativeWanted(QScreen *screen);
    void setNativeMode(bool on) { m_nativeMode = on; }
    // what this window's screen shows, for the source ranking: hdr (null = unknown) and dolby
    // vision reshaping (only mpv's gpu-next does it)
    QJsonObject displayCaps();
    // the native video window shows while video is up
    Q_INVOKABLE void showNative(bool on);

    // gui thread
    void setVideoParams(const QVariantMap &params);
    // a small copy of the video for the glass, only while something glass sits over it
    void setGlass(bool on);
    void setFps(double fps);
#ifdef NOONIX_SCENE_VIDEO
    // the item that draws the video (one at a time)
    void setView(QQuickItem *view);
#endif

signals:
    void colourChanged();
    void activeChanged();
    void firstFrame();
    void renderReady();   // loadfile before this plays without video
    void glassFrame(const QImage &frame);

#ifndef NOONIX_SCENE_VIDEO
protected:
    bool eventFilter(QObject *o, QEvent *e) override;
#endif

private:
    void applyDescription();

    QQuickWindow *m_window = nullptr;
    mpv_handle *m_mpv = nullptr;
    QVariantMap m_colour;
    QVariantMap m_params;
    bool m_active = false;
    std::atomic<bool> m_frameSeen{false};
    std::atomic<bool> m_glass{false};
    std::atomic<bool> m_grabNow{false};
    std::atomic<int> m_grabEvery{1};

    bool m_nativeMode = false;
#ifdef NOONIX_SCENE_VIDEO
    friend class VideoRenderer;
    QPointer<QQuickItem> m_view;
    void *m_nativeWnd = nullptr;   // HWND
    void restackNative();
#else
    bool bindGlobals();
    bool createSurfaces(wl_surface *parent);
    void destroySurfaces();
    void startThread();
    void stopThread();
    void renderLoop();
    void syncSize();

    static void onMpvUpdate(void *ctx);

    wl_display *m_display = nullptr;
    wl_event_queue *m_queue = nullptr;
    wl_compositor *m_compositor = nullptr;
    wl_subcompositor *m_subcompositor = nullptr;
    wp_color_manager_v1 *m_cm = nullptr;
    wl_surface *m_parent = nullptr;
    wl_surface *m_surface = nullptr;
    wl_subsurface *m_subsurface = nullptr;
    wp_color_management_surface_v1 *m_cmSurface = nullptr;
    wp_image_description_v1 *m_desc = nullptr;

    std::thread m_thread;
    std::mutex m_mutex;
    std::condition_variable m_cv;
    bool m_wake = false;
    bool m_quit = false;
    QSize m_pending;
#endif
};
