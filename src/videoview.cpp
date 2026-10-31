#include "videoview.h"
#include "videograb.h"
#include "videosurface.h"

#include <QLoggingCategory>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QQuickOpenGLUtils>
#include <QQuickWindow>

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <utility>

Q_DECLARE_LOGGING_CATEGORY(lcVideo)

// opengl es 3 has it too; qt's es headers stop at es 2
#ifndef GL_RGB10_A2
#define GL_RGB10_A2 0x8059
#endif

namespace {

void *getProc(const char *name)
{
    QOpenGLContext *ctx = QOpenGLContext::currentContext();
    return ctx ? reinterpret_cast<void *>(ctx->getProcAddress(name)) : nullptr;
}

} // namespace

// render thread; the gui thread waits while synchronize() runs
class VideoRenderer : public QQuickFramebufferObject::Renderer
{
public:
    ~VideoRenderer() override
    {
        m_grab.release();
        if (m_rc) {
            mpv_render_context_set_update_callback(m_rc, nullptr, nullptr);
            mpv_render_context_free(m_rc);
        }
    }

protected:
    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        // 10 bits like the linux surface: no banding in dark gradients
        QOpenGLFramebufferObjectFormat f;
        f.setInternalTextureFormat(GL_RGB10_A2);
        return new QOpenGLFramebufferObject(size, f);
    }

    void synchronize(QQuickFramebufferObject *item) override
    {
        m_surface = static_cast<VideoView *>(item)->videoSurface();
    }

    void render() override
    {
        QOpenGLFramebufferObject *fbo = framebufferObject();
        if (!m_rc && !m_failed)
            m_failed = !init();
        if (!m_rc) {
            QOpenGLFunctions *f = QOpenGLContext::currentContext()->functions();
            f->glClearColor(0, 0, 0, 1);
            f->glClear(GL_COLOR_BUFFER_BIT);
            return;
        }
        VideoSurface *s = m_surface;
        const bool forced = s->m_grabNow.exchange(false);
        mpv_render_context_update(m_rc);
        mpv_opengl_fbo target{int(fbo->handle()), fbo->width(), fbo->height(), 0};
        int flip = 0;
        mpv_render_param rp[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &target},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        mpv_render_context_render(m_rc, rp);
        if (s->m_glass && (forced || ++m_sinceGrab >= s->m_grabEvery)) {
            m_sinceGrab = 0;
            // a quarter of the window: 960x540 at 4k
            const QSize size = fbo->size();
            m_grab.read(size, QSize(qMax(16, size.width() / 4), qMax(9, size.height() / 4)), fbo->handle(), false);
            const QImage img = m_grab.collect(30);
            if (img.isNull())
                qCWarning(lcVideo, "glass frame not ready in time");
            else if (!std::exchange(m_glassLogged, true))
                qCInfo(lcVideo, "glass frames %dx%d, every %d video frame(s)", img.width(), img.height(), int(s->m_grabEvery));
            if (!img.isNull())
                QMetaObject::invokeMethod(s, [s, img] { emit s->glassFrame(img); }, Qt::QueuedConnection);
        }
        if (!s->m_frameSeen.exchange(true))
            QMetaObject::invokeMethod(s, &VideoSurface::firstFrame, Qt::QueuedConnection);
        mpv_render_context_report_swap(m_rc);
        // mpv leaves its own gl state behind
        QQuickOpenGLUtils::resetOpenGLState();
    }

private:
    bool init()
    {
        VideoSurface *s = m_surface;
        if (!s || !s->m_mpv)
            return false;
        mpv_opengl_init_params gl{[](void *, const char *name) { return getProc(name); }, nullptr};
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        if (mpv_render_context_create(&m_rc, s->m_mpv, params) < 0) {
            qCWarning(lcVideo, "mpv_render_context_create failed");
            m_rc = nullptr;
            return false;
        }
        // mpv's threads ask for a frame; the item repaints on the gui thread
        mpv_render_context_set_update_callback(m_rc, [](void *ctx) {
            auto *s = static_cast<VideoSurface *>(ctx);
            QMetaObject::invokeMethod(s, [s] {
                if (s->m_view)
                    s->m_view->update();
            }, Qt::QueuedConnection);
        }, s);
        if (!m_grab.init(getProc))
            qCWarning(lcVideo, "glass grab unavailable");
        const auto *renderer = reinterpret_cast<const char *>(QOpenGLContext::currentContext()->functions()->glGetString(GL_RENDERER));
        qCInfo(lcVideo, "render context up on %s", renderer ? renderer : "?");
        QMetaObject::invokeMethod(s, &VideoSurface::renderReady, Qt::QueuedConnection);
        return true;
    }

    VideoSurface *m_surface = nullptr;
    mpv_render_context *m_rc = nullptr;
    bool m_failed = false;
    VideoGrab m_grab;
    int m_sinceGrab = 0;
    bool m_glassLogged = false;
};

VideoView::VideoView(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
}

VideoView::~VideoView()
{
    if (m_surface)
        m_surface->setView(nullptr);
}

QQuickFramebufferObject::Renderer *VideoView::createRenderer() const
{
    return new VideoRenderer;
}

QObject *VideoView::surface() const
{
    return m_surface;
}

void VideoView::setSurface(QObject *s)
{
    auto *v = qobject_cast<VideoSurface *>(s);
    if (v == m_surface)
        return;
    m_surface = v;
    if (v)
        v->setView(this);
    update();
    emit surfaceChanged();
}
