#include "videosurface.h"
#include "videograb.h"
#include "color-management-v1-client-protocol.h"

#include <QEvent>
#include <QGuiApplication>
#include <QLoggingCategory>
#include <QQuickWindow>
#include <QScreen>
#include <QtGui/qscreen_platform.h>
#include <QTimer>
#include <qpa/qplatformnativeinterface.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <wayland-client.h>
#include <wayland-egl.h>

#include <cmath>
#include <cstring>
#include <unistd.h>
#include <utility>

Q_LOGGING_CATEGORY(lcVideo, "noonix-tv.video")

namespace {

struct Globals {
    wl_compositor *compositor = nullptr;
    wl_subcompositor *subcompositor = nullptr;
    wp_color_manager_v1 *cm = nullptr;
};

const wl_registry_listener kRegistry = {
    [](void *data, wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
        auto *g = static_cast<Globals *>(data);
        if (strcmp(iface, wl_compositor_interface.name) == 0)
            g->compositor = static_cast<wl_compositor *>(
                wl_registry_bind(reg, name, &wl_compositor_interface, qMin(version, 4u)));
        else if (strcmp(iface, wl_subcompositor_interface.name) == 0)
            g->subcompositor = static_cast<wl_subcompositor *>(
                wl_registry_bind(reg, name, &wl_subcompositor_interface, 1));
        else if (strcmp(iface, wp_color_manager_v1_interface.name) == 0)
            g->cm = static_cast<wp_color_manager_v1 *>(
                wl_registry_bind(reg, name, &wp_color_manager_v1_interface, 1));
    },
    [](void *, wl_registry *, uint32_t) {},
};

struct Pending {
    bool done = false;
    bool ok = false;
};

const wp_image_description_v1_listener kDescription = {
    [](void *data, wp_image_description_v1 *, uint32_t cause, const char *msg) {
        static_cast<Pending *>(data)->done = true;
        qCWarning(lcVideo, "image description refused (%u): %s", cause, msg);
    },
    [](void *data, wp_image_description_v1 *, uint32_t) {
        auto *p = static_cast<Pending *>(data);
        p->done = p->ok = true;
    },
    [](void *data, wp_image_description_v1 *, uint32_t, uint32_t) {
        auto *p = static_cast<Pending *>(data);
        p->done = p->ok = true;
    },
};

// an output's own description: kwin keeps gamma 2.2 for hdr outputs and says it with the
// luminances (peak above the reference white)
struct OutputInfo {
    bool done = false;
    uint32_t tf = 0;
    uint32_t peak = 0;
    uint32_t white = 0;
};

const wp_image_description_info_v1_listener kInfo = {
    [](void *data, wp_image_description_info_v1 *) { static_cast<OutputInfo *>(data)->done = true; },
    [](void *, wp_image_description_info_v1 *, int32_t fd, uint32_t) { close(fd); },
    [](void *, wp_image_description_info_v1 *, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t) {},
    [](void *, wp_image_description_info_v1 *, uint32_t) {},
    [](void *, wp_image_description_info_v1 *, uint32_t) {},
    [](void *data, wp_image_description_info_v1 *, uint32_t tf) { static_cast<OutputInfo *>(data)->tf = tf; },
    [](void *data, wp_image_description_info_v1 *, uint32_t, uint32_t peak, uint32_t white) {
        auto *i = static_cast<OutputInfo *>(data);
        i->peak = peak;
        i->white = white;
    },
    [](void *, wp_image_description_info_v1 *, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t) {},
    [](void *, wp_image_description_info_v1 *, uint32_t, uint32_t) {},
    [](void *, wp_image_description_info_v1 *, uint32_t) {},
    [](void *, wp_image_description_info_v1 *, uint32_t) {},
};

void *getProcAddress(void *, const char *name)
{
    return reinterpret_cast<void *>(eglGetProcAddress(name));
}

bool isPq(const QString &gamma) { return gamma == QLatin1String("pq"); }
bool isHlg(const QString &gamma) { return gamma == QLatin1String("hlg"); }

} // namespace

VideoSurface::VideoSurface(QObject *parent)
    : QObject(parent)
{
}

VideoSurface::~VideoSurface()
{
    detach();
    if (m_cm)
        wp_color_manager_v1_destroy(m_cm);
    if (m_subcompositor)
        wl_subcompositor_destroy(m_subcompositor);
    if (m_compositor)
        wl_compositor_destroy(m_compositor);
    if (m_queue)
        wl_event_queue_destroy(m_queue);
}

bool VideoSurface::bindGlobals()
{
    if (m_compositor)
        return true;
    auto *wl = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
    if (!wl) {
        qCWarning(lcVideo, "not a Wayland session; embedded video needs Wayland");
        return false;
    }
    m_display = wl->display();
    // own queue so qt's event thread never dispatches our objects
    m_queue = wl_display_create_queue(m_display);
    auto *wrapped = static_cast<wl_display *>(wl_proxy_create_wrapper(m_display));
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(wrapped), m_queue);
    wl_registry *registry = wl_display_get_registry(wrapped);
    Globals g;
    wl_registry_add_listener(registry, &kRegistry, &g);
    wl_display_roundtrip_queue(m_display, m_queue);
    wl_registry_destroy(registry);
    wl_proxy_wrapper_destroy(wrapped);
    m_compositor = g.compositor;
    m_subcompositor = g.subcompositor;
    m_cm = g.cm;
    if (!m_compositor || !m_subcompositor) {
        qCWarning(lcVideo, "compositor lacks wl_compositor/wl_subcompositor");
        return false;
    }
    if (!m_cm)
        qCWarning(lcVideo, "no wp_color_manager_v1: video stays SDR-tagged");
    return true;
}

void VideoSurface::attach(QQuickWindow *window)
{
    m_window = window;
    if (!bindGlobals())
        return;
    // qt recreates the wl_surface on hide/show
    window->installEventFilter(this);
    connect(window, &QWindow::widthChanged, this, &VideoSurface::syncSize);
    connect(window, &QWindow::heightChanged, this, &VideoSurface::syncSize);
    QTimer::singleShot(0, this, [this] {
        auto *s = static_cast<wl_surface *>(
            QGuiApplication::platformNativeInterface()->nativeResourceForWindow("surface", m_window));
        if (s)
            createSurfaces(s);
    });
}

bool VideoSurface::eventFilter(QObject *o, QEvent *e)
{
    if (o == m_window && (e->type() == QEvent::Expose || e->type() == QEvent::PlatformSurface))
        QTimer::singleShot(0, this, [this] {
            if (!m_window)
                return;
            auto *s = static_cast<wl_surface *>(
                QGuiApplication::platformNativeInterface()->nativeResourceForWindow("surface", m_window));
            if (s && s != m_parent) {
                destroySurfaces();
                createSurfaces(s);
            } else if (!s && m_parent) {
                destroySurfaces();
            }
        });
    return false;
}

bool VideoSurface::createSurfaces(wl_surface *parent)
{
    if (!m_mpv || m_surface)
        return false;
    m_parent = parent;
    auto *compositor = static_cast<wl_compositor *>(wl_proxy_create_wrapper(m_compositor));
    m_surface = wl_compositor_create_surface(compositor);
    wl_proxy_wrapper_destroy(compositor);
    wl_region *empty = wl_compositor_create_region(m_compositor);
    wl_surface_set_input_region(m_surface, empty);
    wl_region_destroy(empty);
    m_subsurface = wl_subcompositor_get_subsurface(m_subcompositor, m_surface, parent);
    wl_subsurface_place_below(m_subsurface, parent);
    wl_subsurface_set_position(m_subsurface, 0, 0);
    wl_subsurface_set_desync(m_subsurface);
    if (m_cm)
        m_cmSurface = wp_color_manager_v1_get_surface(m_cm, m_surface);
    applyDescription();
    // place_below applies on the parent's next commit
    m_window->update();
    wl_display_flush(m_display);
    syncSize();
    startThread();
    m_active = true;
    emit activeChanged();
    return true;
}

void VideoSurface::destroySurfaces()
{
    stopThread();
    if (m_desc) {
        wp_image_description_v1_destroy(m_desc);
        m_desc = nullptr;
    }
    if (m_cmSurface) {
        wp_color_management_surface_v1_destroy(m_cmSurface);
        m_cmSurface = nullptr;
    }
    if (m_subsurface) {
        wl_subsurface_destroy(m_subsurface);
        m_subsurface = nullptr;
    }
    if (m_surface) {
        wl_surface_destroy(m_surface);
        m_surface = nullptr;
    }
    m_parent = nullptr;
    if (m_display)
        wl_display_flush(m_display);
    if (m_active) {
        m_active = false;
        emit activeChanged();
    }
}

void VideoSurface::detach()
{
    if (m_window)
        m_window->removeEventFilter(this);
    destroySurfaces();
    m_window = nullptr;
}

void VideoSurface::syncSize()
{
    if (!m_window)
        return;
    const qreal dpr = m_window->devicePixelRatio();
    const QSize px(qRound(m_window->width() * dpr), qRound(m_window->height() * dpr));
    if (m_surface && dpr == qRound(dpr))
        wl_surface_set_buffer_scale(m_surface, int(dpr));
    {
        std::lock_guard lock(m_mutex);
        m_pending = px;
        m_wake = true;
    }
    m_cv.notify_one();
}

void VideoSurface::setVideoParams(const QVariantMap &params)
{
    if (params == m_params)
        return;
    m_params = params;
    applyDescription();
}

void VideoSurface::applyDescription()
{
    const QString gamma = m_params.value(QStringLiteral("gamma")).toString();
    const bool pq = isPq(gamma), hlg = isHlg(gamma);
    const QString prim = m_params.value(QStringLiteral("primaries")).toString();
    const bool wide = prim == QLatin1String("bt.2020") || pq || hlg;

    // no tone mapping in mpv, kwin maps to the output
    if (m_mpv) {
        mpv_set_property_string(m_mpv, "target-trc", pq ? "pq" : hlg ? "hlg" : "gamma2.2");
        mpv_set_property_string(m_mpv, "target-prim", wide ? "bt.2020" : "bt.709");
    }

    QVariantMap c;
    c[QStringLiteral("hdr")] = pq || hlg;
    c[QStringLiteral("transfer")] = pq ? "pq" : hlg ? "hlg" : "gamma2.2";
    c[QStringLiteral("primaries")] = wide ? "bt.2020" : "bt.709";

    if (m_cmSurface) {
        auto *params = wp_color_manager_v1_create_parametric_creator(m_cm);
        wp_image_description_creator_params_v1_set_tf_named(params,
            pq ? WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ
               : hlg ? WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_HLG
                     : WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22);
        wp_image_description_creator_params_v1_set_primaries_named(params,
            wide ? WP_COLOR_MANAGER_V1_PRIMARIES_BT2020 : WP_COLOR_MANAGER_V1_PRIMARIES_SRGB);
        if (pq) {
            // no mastering sei -> mpv reports 10000, assume the usual 1000 nit grade
            int maxLuma = m_params.value(QStringLiteral("max-luma"), 0).toInt();
            if (maxLuma <= 0 || maxLuma >= 10000)
                maxLuma = 1000;
            const int minLuma = qRound(m_params.value(QStringLiteral("min-luma"), 0.005).toDouble() * 10000);
            const int cll = m_params.value(QStringLiteral("max-cll"), 0).toInt();
            const int fall = m_params.value(QStringLiteral("max-fall"), 0).toInt();
            wp_image_description_creator_params_v1_set_mastering_display_primaries(
                params, 680000, 320000, 265000, 690000, 150000, 60000, 312700, 329000);
            wp_image_description_creator_params_v1_set_mastering_luminance(
                params, qMax(1, minLuma), qMax(100, maxLuma));
            if (cll > 0) {
                wp_image_description_creator_params_v1_set_max_cll(params, cll);
                wp_image_description_creator_params_v1_set_max_fall(params, qBound(1, fall > 0 ? fall : cll, cll));
            }
            c[QStringLiteral("maxCll")] = cll;
            c[QStringLiteral("maxFall")] = fall;
            c[QStringLiteral("masteringPeak")] = maxLuma;
        }
        auto *desc = wp_image_description_creator_params_v1_create(params);
        Pending pending;
        wp_image_description_v1_add_listener(desc, &kDescription, &pending);
        while (!pending.done && wl_display_roundtrip_queue(m_display, m_queue) >= 0) { }
        if (pending.ok) {
            wp_color_management_surface_v1_set_image_description(
                m_cmSurface, desc, WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
            if (m_desc)
                wp_image_description_v1_destroy(m_desc);
            m_desc = desc;
        } else {
            wp_image_description_v1_destroy(desc);
            c[QStringLiteral("error")] = "description refused";
        }
    }
    if (c != m_colour) {
        m_colour = c;
        qCInfo(lcVideo) << "colour" << c;
        emit colourChanged();
    }
}

QJsonObject VideoSurface::displayCaps()
{
    // vo_libmpv draws with vo_gpu's renderer: no dolby vision reshaping
    QJsonObject caps{{QStringLiteral("hdr"), QJsonValue::Null}, {QStringLiteral("dv"), false}};
    QScreen *screen = m_window ? m_window->screen() : nullptr;
    auto *ws = screen ? screen->nativeInterface<QNativeInterface::QWaylandScreen>() : nullptr;
    if (!m_cm || !ws || !ws->output())
        return caps;
    // new objects land on m_cm's own queue
    auto *cmOutput = wp_color_manager_v1_get_output(m_cm, ws->output());
    auto *desc = wp_color_management_output_v1_get_image_description(cmOutput);
    Pending pending;
    wp_image_description_v1_add_listener(desc, &kDescription, &pending);
    while (!pending.done && wl_display_roundtrip_queue(m_display, m_queue) >= 0) { }
    if (pending.ok) {
        OutputInfo info;
        auto *i = wp_image_description_v1_get_information(desc);
        wp_image_description_info_v1_add_listener(i, &kInfo, &info);
        while (!info.done && wl_display_roundtrip_queue(m_display, m_queue) >= 0) { }
        wp_image_description_info_v1_destroy(i);
        const bool hdr = info.tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ
            || info.tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_HLG
            || (info.white > 0 && info.peak > info.white * 3 / 2);
        caps[QStringLiteral("hdr")] = hdr;
        qCInfo(lcVideo) << "screen" << screen->name() << "peak" << info.peak << "white" << info.white << "hdr" << hdr;
    }
    wp_image_description_v1_destroy(desc);
    wp_color_management_output_v1_destroy(cmOutput);
    return caps;
}

void VideoSurface::setGlass(bool on)
{
    if (m_glass.exchange(on) == on || !on)
        return;
    // grab the frame on screen now, paused video never renders another one
    m_grabNow = true;
    {
        std::lock_guard lock(m_mutex);
        m_wake = true;
    }
    m_cv.notify_one();
}

void VideoSurface::setFps(double fps)
{
    // the glass follows the video up to 30 updates a second: every frame up to 30 fps,
    // every other one at 50/60 (never under 23.976)
    m_grabEvery = fps > 30.5 ? int(std::ceil(fps / 30.0 - 0.01)) : 1;
}

void VideoSurface::onMpvUpdate(void *ctx)
{
    auto *self = static_cast<VideoSurface *>(ctx);
    {
        std::lock_guard lock(self->m_mutex);
        self->m_wake = true;
    }
    self->m_cv.notify_one();
}

void VideoSurface::startThread()
{
    if (m_thread.joinable())
        return;
    m_quit = false;
    m_thread = std::thread([this] { renderLoop(); });
}

void VideoSurface::stopThread()
{
    if (!m_thread.joinable())
        return;
    {
        std::lock_guard lock(m_mutex);
        m_quit = true;
        m_wake = true;
    }
    m_cv.notify_one();
    m_thread.join();
}

void VideoSurface::renderLoop()
{
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, m_display, nullptr);
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr)) {
        qCWarning(lcVideo, "EGL init failed");
        return;
    }
    eglBindAPI(EGL_OPENGL_API);
    const EGLint want[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 10, EGL_GREEN_SIZE, 10, EGL_BLUE_SIZE, 10,
        EGL_NONE,
    };
    EGLConfig configs[64];
    EGLint n = 0;
    eglChooseConfig(dpy, want, configs, 64, &n);
    EGLConfig config = nullptr;
    for (int i = 0; i < n && !config; ++i) {
        EGLint r = 0, a = 0;
        eglGetConfigAttrib(dpy, configs[i], EGL_RED_SIZE, &r);
        eglGetConfigAttrib(dpy, configs[i], EGL_ALPHA_SIZE, &a);
        if (r == 10 && a <= 2)
            config = configs[i];
    }
    if (!config) {
        // never eglTerminate, the egl display is shared with qt
        qCWarning(lcVideo, "no 10-bit EGL config");
        return;
    }
    const EGLint ctxAttr[] = {
        EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE,
    };
    EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctxAttr);
    QSize size;
    {
        std::lock_guard lock(m_mutex);
        size = m_pending.isEmpty() ? QSize(1920, 1080) : m_pending;
    }
    wl_egl_window *native = wl_egl_window_create(m_surface, size.width(), size.height());
    EGLSurface surf = eglCreatePlatformWindowSurface(dpy, config, native, nullptr);
    if (ctx == EGL_NO_CONTEXT || surf == EGL_NO_SURFACE || !eglMakeCurrent(dpy, surf, surf, ctx)) {
        qCWarning(lcVideo, "EGL context/surface failed (0x%x)", eglGetError());
        return;
    }
    eglSwapInterval(dpy, 1);

    mpv_opengl_init_params gl{getProcAddress, nullptr};
    int advanced = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
        {MPV_RENDER_PARAM_WL_DISPLAY, m_display},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    mpv_render_context *rc = nullptr;
    if (mpv_render_context_create(&rc, m_mpv, params) < 0) {
        qCWarning(lcVideo, "mpv_render_context_create failed");
        return;
    }
    mpv_render_context_set_update_callback(rc, &VideoSurface::onMpvUpdate, this);
    VideoGrab grab;
    if (!grab.init([](const char *name) { return reinterpret_cast<void *>(eglGetProcAddress(name)); }))
        qCWarning(lcVideo, "glass grab unavailable");
    int sinceGrab = 0;
    bool glassLogged = false;
    qCInfo(lcVideo, "render thread up: %dx%d 10-bit", size.width(), size.height());
    QMetaObject::invokeMethod(this, &VideoSurface::renderReady, Qt::QueuedConnection);

    for (;;) {
        QSize want;
        {
            std::unique_lock lock(m_mutex);
            m_cv.wait(lock, [this] { return m_wake; });
            m_wake = false;
            if (m_quit)
                break;
            want = m_pending;
        }
        if (!want.isEmpty() && want != size) {
            size = want;
            wl_egl_window_resize(native, size.width(), size.height(), 0, 0);
        }
        const uint64_t flags = mpv_render_context_update(rc);
        const bool forced = m_grabNow.exchange(false);
        if ((flags & MPV_RENDER_UPDATE_FRAME) || forced) {
            mpv_opengl_fbo fbo{0, size.width(), size.height(), 0};
            int flip = 1;
            mpv_render_param rp[] = {
                {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
                {MPV_RENDER_PARAM_FLIP_Y, &flip},
                {MPV_RENDER_PARAM_INVALID, nullptr},
            };
            mpv_render_context_render(rc, rp);
            const bool grabbing = m_glass && (forced || ++sinceGrab >= m_grabEvery);
            if (grabbing) {
                sinceGrab = 0;
                // a quarter of the window: 960x540 at 4k
                grab.read(size, QSize(qMax(16, size.width() / 4), qMax(9, size.height() / 4)));
            }
            eglSwapBuffers(dpy, surf);
            mpv_render_context_report_swap(rc);
            if (grabbing) {
                const QImage img = grab.collect(30);
                if (img.isNull())
                    qCWarning(lcVideo, "glass frame not ready in time");
                else if (!std::exchange(glassLogged, true))
                    qCInfo(lcVideo, "glass frames %dx%d, every %d video frame(s)", img.width(), img.height(), int(m_grabEvery));
                if (!img.isNull())
                    QMetaObject::invokeMethod(this, [this, img] { emit glassFrame(img); }, Qt::QueuedConnection);
            }
            if (!m_frameSeen.exchange(true))
                QMetaObject::invokeMethod(this, &VideoSurface::firstFrame, Qt::QueuedConnection);
        }
    }

    grab.release();
    mpv_render_context_set_update_callback(rc, nullptr, nullptr);
    mpv_render_context_free(rc);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(dpy, surf);
    eglDestroyContext(dpy, ctx);
    wl_egl_window_destroy(native);
    eglReleaseThread();
    m_frameSeen = false;
}

// linux: the video is always a subsurface with its own colour description
bool VideoSurface::nativeWanted(QScreen *)
{
    return false;
}

void VideoSurface::showNative(bool)
{
}
