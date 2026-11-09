// android: mpv in the activity's own surface view under qt's (NoonixActivity.videoShown), drawn
// on an egl thread like the linux subsurface, 10 bits, sdr. hdr on an hdr panel: the decoder
// writes into the surface view itself (vo=mediacodec_embed), the composer shows it in the panel's
// hdr mode. a gl-drawn pq layer doesn't get that: qualcomm's composer hands it to the gpu, which
// tone maps it worse than mpv does (OnePlus 6, 2026-11-06)
#include "videograb.h"
#include "videosurface.h"

#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#include <QLoggingCategory>

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <android/data_space.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <cstring>

Q_DECLARE_LOGGING_CATEGORY(lcVideo)

namespace {

VideoSurface *g_surface = nullptr;

QJniObject activity()
{
    return QJniObject(QNativeInterface::QAndroidApplication::context());
}

void surfaceFromJava(JNIEnv *env, jobject, jobject surface, jint w, jint h)
{
    ANativeWindow *anw = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    if (g_surface)
        g_surface->androidWindow(anw, w, h);
    else if (anw)
        ANativeWindow_release(anw);
}

} // namespace

// the panel's hdr10 peak in nits (0: no hdr10, or hdr is off for it)
float androidHdrPeak()
{
    return activity().callMethod<jfloat>("hdrPeak", "()F");
}

// the core's refresh rate matching (core/src/system.rs, android): the modes as text, a switch
extern "C" size_t noonix_android_display_modes(char *buf, size_t len)
{
    const QByteArray t = activity().callObjectMethod("displayModes", "()Ljava/lang/String;").toString().toUtf8();
    const size_t n = qMin(size_t(t.size()), len > 0 ? len - 1 : 0);
    memcpy(buf, t.constData(), n);
    if (len > 0)
        buf[n] = 0;
    return n;
}

extern "C" void noonix_android_display_set(int id)
{
    activity().callMethod<void>("displayMode", "(I)V", jint(id));
}

void androidVideoShown(bool on)
{
    activity().callMethod<void>("videoShown", "(Z)V", jboolean(on));
}

void androidRegisterVideo(VideoSurface *s)
{
    g_surface = s;
    static bool once = false;
    if (std::exchange(once, true))
        return;
    const JNINativeMethod methods[] = {
        {"videoSurface", "(Landroid/view/Surface;II)V", reinterpret_cast<void *>(surfaceFromJava)}};
    QJniEnvironment().registerNativeMethods("io/github/dzeliks/noonixtv/NoonixActivity", methods, 1);
}

void VideoSurface::androidWindow(void *window, int w, int h)
{
    // the surface goes (app in the background, video hidden): the decoder must let go of it first
    if (!window && m_embed) {
        std::lock_guard embedLock(m_embedMutex);
        if (m_embed) {
            qCInfo(lcVideo, "video surface gone while the decoder drew in it: back to gl");
            mpv_set_property_string(m_mpv, "vo", "libmpv");
            m_embed = false;
            QMetaObject::invokeMethod(this, &VideoSurface::syncEmbed, Qt::QueuedConnection);
        }
    }
    // a new surface: the decoder may draw in it again
    if (window && window != m_anw)
        QMetaObject::invokeMethod(this, &VideoSurface::syncEmbed, Qt::QueuedConnection);
    std::unique_lock lock(m_mutex);
    if (window == m_anw) {
        // same window, new size
        if (window)
            ANativeWindow_release(static_cast<ANativeWindow *>(window));
        m_anwSize = QSize(w, h);
        m_wake = true;
        m_cv.notify_all();
        return;
    }
    if (m_anw)
        ANativeWindow_release(static_cast<ANativeWindow *>(m_anw));
    m_anw = window;
    m_anwSize = QSize(w, h);
    m_anwNew = true;
    m_anwTaken = false;
    m_wake = true;
    m_cv.notify_all();
    // a destroyed surface must not be drawn to after surfaceDestroyed returns
    if (!window && m_thread.joinable())
        m_cv.wait_for(lock, std::chrono::seconds(2), [this] { return m_anwTaken || m_quit; });
}

void VideoSurface::holdWindow(bool hold)
{
    std::unique_lock lock(m_mutex);
    m_hold = hold;
    m_held = false;
    m_wake = true;
    m_cv.notify_all();
    if (hold && m_thread.joinable())
        m_cv.wait_for(lock, std::chrono::seconds(2), [this] { return m_held || m_quit; });
}

void VideoSurface::setEmbedAllowed(bool on)
{
    if (on == m_embedAllowed)
        return;
    m_embedAllowed = on;
    qCInfo(lcVideo) << "decoder hdr output" << (on ? "allowed" : "off (picture subtitles / dolby vision 5)");
    applyDescription();
}

// gui thread: the decoder takes the surface view while hdr plays (and the view is there)
bool VideoSurface::enterEmbed()
{
    std::lock_guard embedLock(m_embedMutex);
    if (m_embed)
        return true;
    QJniObject surface = activity().callObjectMethod("videoSurfaceObject", "()Landroid/view/Surface;");
    if (!surface.isValid())
        return false;
    qCInfo(lcVideo, "decoder output: taking the surface");
    holdWindow(true);
    QJniEnvironment env;
    jobject ref = env->NewGlobalRef(surface.object());
    int64_t wid = reinterpret_cast<intptr_t>(ref);
    mpv_set_property(m_mpv, "wid", MPV_FORMAT_INT64, &wid);
    qCInfo(lcVideo, "decoder output: switching the vo");
    if (mpv_set_property_string(m_mpv, "vo", "mediacodec_embed") < 0) {
        qCWarning(lcVideo, "vo=mediacodec_embed failed, staying on gl");
        mpv_set_property_string(m_mpv, "vo", "libmpv");
        env->DeleteGlobalRef(ref);
        holdWindow(false);
        return false;
    }
    if (m_surfaceRef)
        env->DeleteGlobalRef(static_cast<jobject>(m_surfaceRef));
    m_surfaceRef = ref;
    m_embed = true;
    const int dw = m_params.value(QStringLiteral("dw")).toInt(), dh = m_params.value(QStringLiteral("dh")).toInt();
    activity().callMethod<void>("videoFit", "(II)V", jint(dw), jint(dh));
    qCInfo(lcVideo, "hdr straight from the decoder (%dx%d)", dw, dh);
    return true;
}

void VideoSurface::leaveEmbed()
{
    std::lock_guard embedLock(m_embedMutex);
    if (!m_embed && !m_surfaceRef)
        return;
    if (m_embed) {
        mpv_set_property_string(m_mpv, "vo", "libmpv");
        m_embed = false;
        qCInfo(lcVideo, "back to the gl path");
    }
    if (m_surfaceRef) {
        QJniEnvironment env;
        env->DeleteGlobalRef(static_cast<jobject>(m_surfaceRef));
        m_surfaceRef = nullptr;
    }
    activity().callMethod<void>("videoFit", "(II)V", jint(0), jint(0));
    holdWindow(false);
}

void VideoSurface::syncEmbed()
{
    applyDescription();
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
    m_cv.notify_all();
    m_thread.join();
}

void VideoSurface::renderLoop()
{
    EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr)) {
        qCWarning(lcVideo, "egl display failed");
        return;
    }
    eglBindAPI(EGL_OPENGL_ES_API);
    // 10 bits: pq needs them (and sdr gradients band less); the surface view asked for 1010102
    const EGLint want[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 10, EGL_GREEN_SIZE, 10, EGL_BLUE_SIZE, 10, EGL_ALPHA_SIZE, 2,
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
        if (r == 10 && a == 2)
            config = configs[i];
    }
    if (!config) {
        qCWarning(lcVideo, "no 10-bit egl config");
        return;
    }
    const EGLint ctxAttr[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctxAttr);
    // mpv keeps a context while no window is there (app in the background, video hidden)
    const EGLint pbAttr[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    EGLSurface pbuffer = eglCreatePbufferSurface(dpy, config, pbAttr);
    if (ctx == EGL_NO_CONTEXT || pbuffer == EGL_NO_SURFACE || !eglMakeCurrent(dpy, pbuffer, pbuffer, ctx)) {
        qCWarning(lcVideo, "egl context failed (0x%x)", eglGetError());
        return;
    }

    mpv_opengl_init_params gl{[](void *, const char *name) { return reinterpret_cast<void *>(eglGetProcAddress(name)); }, nullptr};
    int advanced = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    mpv_render_context *rc = nullptr;
    if (mpv_render_context_create(&rc, m_mpv, params) < 0) {
        qCWarning(lcVideo, "mpv_render_context_create failed");
        return;
    }
    mpv_render_context_set_update_callback(rc, [](void *c) {
        auto *self = static_cast<VideoSurface *>(c);
        {
            std::lock_guard lock(self->m_mutex);
            self->m_wake = true;
        }
        self->m_cv.notify_all();
    }, this);
    VideoGrab grab;
    if (!grab.init([](const char *name) { return reinterpret_cast<void *>(eglGetProcAddress(name)); }))
        qCWarning(lcVideo, "glass grab unavailable");
    qCInfo(lcVideo, "render thread up: %s", reinterpret_cast<const char *>(glGetString(GL_RENDERER)));
    QMetaObject::invokeMethod(this, &VideoSurface::renderReady, Qt::QueuedConnection);

    ANativeWindow *anw = nullptr;
    EGLSurface surf = EGL_NO_SURFACE;
    QSize size(16, 16);
    int sinceGrab = 0;
    bool glassLogged = false;

    const auto dropSurface = [&] {
        eglMakeCurrent(dpy, pbuffer, pbuffer, ctx);
        if (surf != EGL_NO_SURFACE)
            eglDestroySurface(dpy, surf);
        surf = EGL_NO_SURFACE;
    };
    const auto makeSurface = [&] {
        dropSurface();
        if (!anw)
            return;
        ANativeWindow_setBuffersGeometry(anw, 0, 0, AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM);
        surf = eglCreateWindowSurface(dpy, config, anw, nullptr);
        if (surf == EGL_NO_SURFACE) {
            qCWarning(lcVideo, "egl window surface failed (0x%x)", eglGetError());
            return;
        }
        ANativeWindow_setBuffersDataSpace(anw, ADATASPACE_SRGB);
        eglMakeCurrent(dpy, surf, surf, ctx);
        eglSwapInterval(dpy, 1);
        qCInfo(lcVideo, "video surface %dx%d", size.width(), size.height());
    };

    for (;;) {
        bool redraw = false;
        {
            std::unique_lock lock(m_mutex);
            m_cv.wait(lock, [this] { return m_wake; });
            m_wake = false;
            if (m_quit)
                break;
            if (m_anwNew) {
                m_anwNew = false;
                dropSurface();
                if (anw)
                    ANativeWindow_release(anw);
                anw = static_cast<ANativeWindow *>(m_anw);
                if (anw)
                    ANativeWindow_acquire(anw);
                m_anwTaken = true;
                m_cv.notify_all();
                if (anw)
                    size = m_anwSize;
            } else if (anw && m_anwSize != size) {
                size = m_anwSize;
                redraw = true;
            }
            // the decoder draws in the window meanwhile (an egl surface would keep it connected)
            if (m_hold && surf != EGL_NO_SURFACE)
                dropSurface();
            if (!m_held) {
                m_held = true;
                m_cv.notify_all();
            }
            if (!m_hold && anw && surf == EGL_NO_SURFACE) {
                makeSurface();
                redraw = true;
            }
        }
        const uint64_t flags = mpv_render_context_update(rc);
        const bool forced = m_grabNow.exchange(false);
        if (!(flags & MPV_RENDER_UPDATE_FRAME) && !forced && !redraw)
            continue;
        const bool onWindow = surf != EGL_NO_SURFACE;
        const QSize target = onWindow ? size : QSize(16, 16);
        mpv_opengl_fbo fbo{0, target.width(), target.height(), 0};
        int flip = 1;
        mpv_render_param rp[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        mpv_render_context_render(rc, rp);
        const bool grabbing = onWindow && m_glass && (forced || ++sinceGrab >= m_grabEvery);
        if (grabbing) {
            sinceGrab = 0;
            grab.read(size, QSize(qMax(16, size.width() / 4), qMax(9, size.height() / 4)));
        }
        eglSwapBuffers(dpy, onWindow ? surf : pbuffer);
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
        if (flags & MPV_RENDER_UPDATE_FRAME && !m_frameSeen.exchange(true))
            QMetaObject::invokeMethod(this, &VideoSurface::firstFrame, Qt::QueuedConnection);
    }

    grab.release();
    mpv_render_context_set_update_callback(rc, nullptr, nullptr);
    mpv_render_context_free(rc);
    dropSurface();
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(dpy, pbuffer);
    eglDestroyContext(dpy, ctx);
    if (anw)
        ANativeWindow_release(anw);
    eglReleaseThread();
    {
        std::lock_guard lock(m_mutex);
        m_anwTaken = true;
    }
    m_cv.notify_all();
    m_frameSeen = false;
}
