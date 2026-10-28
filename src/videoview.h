#pragma once
// windows: the mpv picture as a qt quick item, drawn into an fbo on qt's render thread
#include <QPointer>
#include <QQuickFramebufferObject>

class VideoSurface;

class VideoView : public QQuickFramebufferObject
{
    Q_OBJECT
    Q_PROPERTY(QObject *surface READ surface WRITE setSurface NOTIFY surfaceChanged)
public:
    explicit VideoView(QQuickItem *parent = nullptr);
    ~VideoView() override;

    Renderer *createRenderer() const override;
    QObject *surface() const;
    void setSurface(QObject *s);
    VideoSurface *videoSurface() const { return m_surface; }

signals:
    void surfaceChanged();

private:
    QPointer<VideoSurface> m_surface;
};
