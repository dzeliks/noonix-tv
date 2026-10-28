#pragma once
// the video surface's small copy as a qml texture, the backdrop for glass over video
#include <QImage>
#include <QPointer>
#include <QQuickItem>

class VideoSurface;

class VideoGlass : public QQuickItem
{
    Q_OBJECT
    Q_PROPERTY(QObject *surface READ surface WRITE setSurface NOTIFY surfaceChanged)
    Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
public:
    explicit VideoGlass(QQuickItem *parent = nullptr);

    QObject *surface() const;
    void setSurface(QObject *s);
    bool running() const { return m_running; }
    void setRunning(bool on);
    bool ready() const { return m_ready; }

signals:
    void surfaceChanged();
    void runningChanged();
    void readyChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    void onFrame(const QImage &frame);
    void setReady(bool r);

    QPointer<VideoSurface> m_surface;
    QMetaObject::Connection m_conn;
    bool m_running = false;
    bool m_ready = false;
    bool m_dirty = false;
    QImage m_frame;
};
