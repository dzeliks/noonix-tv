#include "videoglass.h"
#include "videosurface.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>

VideoGlass::VideoGlass(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents);
}

QObject *VideoGlass::surface() const
{
    return m_surface;
}

void VideoGlass::setSurface(QObject *s)
{
    auto *v = qobject_cast<VideoSurface *>(s);
    if (v == m_surface)
        return;
    disconnect(m_conn);
    if (m_surface && m_running)
        m_surface->setGlass(false);
    m_surface = v;
    if (v) {
        m_conn = connect(v, &VideoSurface::glassFrame, this, &VideoGlass::onFrame);
        v->setGlass(m_running);
    }
    emit surfaceChanged();
}

void VideoGlass::setRunning(bool on)
{
    if (on == m_running)
        return;
    m_running = on;
    // a stale frame from an earlier scene would flash, wait for the fresh one
    if (on)
        setReady(false);
    if (m_surface)
        m_surface->setGlass(on);
    emit runningChanged();
}

void VideoGlass::setReady(bool r)
{
    if (r == m_ready)
        return;
    m_ready = r;
    emit readyChanged();
}

void VideoGlass::onFrame(const QImage &frame)
{
    if (!m_running)
        return;
    m_frame = frame;
    m_dirty = true;
    update();
    setReady(true);
}

namespace {

// owns one texture at a time, the old one goes as soon as a new frame replaces it
struct FrameNode : QSGSimpleTextureNode {
    ~FrameNode() override { delete texture(); }
    void replace(QSGTexture *t)
    {
        QSGTexture *old = texture();
        setTexture(t);
        delete old;
    }
};

} // namespace

QSGNode *VideoGlass::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    auto *node = static_cast<FrameNode *>(old);
    if (m_frame.isNull()) {
        delete node;
        return nullptr;
    }
    if (!node) {
        node = new FrameNode;
        node->setFiltering(QSGTexture::Linear);
    }
    if (m_dirty || !node->texture()) {
        m_dirty = false;
        node->replace(window()->createTextureFromImage(m_frame));
    }
    node->setRect(boundingRect());
    return node;
}
