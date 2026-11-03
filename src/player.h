#pragma once
// owns mpv; reports open -> loaded -> tick -> stop to the rust core (playback.*)
#include <QElapsedTimer>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QPointer>
#include <QQuickWindow>
#include <QTimer>
#include <QVariantMap>
#include <functional>

struct mpv_handle;
class Core;
class VideoSurface;

class Player : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
    Q_PROPERTY(bool buffering READ buffering NOTIFY bufferingChanged)
    Q_PROPERTY(double cacheAhead READ cacheAhead NOTIFY positionChanged)
    Q_PROPERTY(QVariantMap item READ item NOTIFY itemChanged)
    Q_PROPERTY(QVariantMap source READ source NOTIFY itemChanged)
    Q_PROPERTY(QVariantList segments READ segments NOTIFY segmentsChanged)
    Q_PROPERTY(QVariantMap next READ next NOTIFY nextChanged)
    Q_PROPERTY(QVariantList chapters READ chapters NOTIFY tracksChanged)
    Q_PROPERTY(QVariantList audioTracks READ audioTracks NOTIFY tracksChanged)
    Q_PROPERTY(QVariantList subtitleTracks READ subtitleTracks NOTIFY tracksChanged)
    Q_PROPERTY(QVariantMap videoParams READ videoParams NOTIFY videoParamsChanged)
    // the tv follows the video's frame rate (setting, switchable while playing)
    Q_PROPERTY(bool refreshMatch READ refreshMatch NOTIFY refreshMatchChanged)
    // subtitle timing in seconds (+ = later); follows what was set for this release + subtitle
    Q_PROPERTY(double subDelay READ subDelay NOTIFY subDelayChanged)
    // a hardware hevc main10 decoder (what carries 4k): -1 not known yet, 0 no, 1 yes
    Q_PROPERTY(int hevc10 READ hevc10 NOTIFY hevc10Changed)

public:
    // nativeVideo (windows hdr): mpv draws in its own d3d11 window instead of the qt scene
    explicit Player(bool nativeVideo = false, QObject *parent = nullptr);
    ~Player() override;

    mpv_handle *handle() const { return m_mpv; }
    void setVideo(VideoSurface *v) { m_video = v; }
    void setWindow(QQuickWindow *w) { m_window = w; }
    // what the screen can show, for the source ranking
    void reportDisplay();
    void setCore(Core *core);
    void setRenderReady();
    void shutdown();

    QString state() const { return m_state; }
    QString errorText() const { return m_error; }
    double position() const { return m_pos; }
    double duration() const { return m_dur; }
    bool paused() const { return m_paused; }
    bool buffering() const { return m_buffering; }
    double cacheAhead() const { return m_cache; }
    QVariantMap item() const { return m_item; }
    QVariantMap source() const { return m_source; }
    QVariantList segments() const { return m_segments; }
    QVariantMap next() const { return m_next; }
    QVariantList chapters() const { return m_chapters; }
    QVariantList audioTracks() const { return m_audio; }
    QVariantList subtitleTracks() const { return m_subs; }
    QVariantMap videoParams() const { return m_vp; }
    bool refreshMatch() const { return m_refresh; }
    double subDelay() const { return m_subDelay; }
    Q_INVOKABLE void setSubDelay(double secs);
    Q_INVOKABLE void setRefreshMatch(bool on);

    // {kind, tmdb, season?, episode?, stream, start?}
    Q_INVOKABLE void play(const QVariantMap &request);
    // a local file or url without bookkeeping (tests, trailers)
    Q_INVOKABLE void playUrl(const QString &url);
    Q_INVOKABLE void playNext();
    Q_INVOKABLE void togglePause();
    Q_INVOKABLE void setPaused(bool p);
    Q_INVOKABLE void seek(double secs);
    Q_INVOKABLE void seekTo(double secs);
    // quick keyframe seek for scrub previews
    Q_INVOKABLE void seekPreview(double secs);
    Q_INVOKABLE void setAudioTrack(int id);
    Q_INVOKABLE void setSubtitleTrack(int id); // 0 = off
    Q_INVOKABLE void addSubtitle(const QString &url, const QString &title, const QString &lang, bool select = true);
    // subtitles move above the controls while they're up
    Q_INVOKABLE void setSubtitleLift(bool on);
    Q_INVOKABLE void stop();
    int hevc10() const { return m_hevc10; }
    // looks once, off the ui thread (drivers take a moment to load): hwdecode.cpp
    Q_INVOKABLE void probeHevc10();

signals:
    void hevc10Changed();
    void stateChanged();
    void positionChanged();
    void durationChanged();
    void pausedChanged();
    void bufferingChanged();
    void itemChanged();
    void segmentsChanged();
    void nextChanged();
    void tracksChanged();
    void videoParamsChanged();
    void refreshMatchChanged();
    void subDelayChanged();
    void notice(const QString &text);
    void ended(bool completed);

private:
    int m_hevc10 = -1;
    bool m_probing = false;
    void drain();
    void onFileLoaded();
    void onEnd(const QString &reason, const QString &error);
    void tick(const QString &reason);
    void setState(const QString &s, const QString &error = {});
    void refreshTracks();
    void subChanged();
    void call(const QString &method, const QJsonObject &args, std::function<void(bool, const QJsonObject &)> done = {});
    void onCoreResult(quint64 id, bool ok, const QString &json);
    void onCorePush(const QString &name, const QString &json);
    void setOpt(const char *name, const QString &value);
    void loadFile(const QString &url, double start);
    QVariant getNode(const char *name);

    mpv_handle *m_mpv = nullptr;
    VideoSurface *m_video = nullptr;
    QPointer<QQuickWindow> m_window;
    Core *m_core = nullptr;
    QHash<quint64, std::function<void(bool, const QJsonObject &)>> m_pending;

    QString m_state = QStringLiteral("idle");
    QString m_error;
    qint64 m_session = 0;     // rust session id, 0 = no bookkeeping
    bool m_ending = false;
    bool m_renderReady = false;
    std::function<void()> m_pendingLoad;
    double m_pos = 0, m_dur = 0, m_cache = 0;
    bool m_paused = false, m_buffering = false;
    QElapsedTimer m_posEmit;
    QTimer m_tickTimer;
#ifdef Q_OS_ANDROID
    QTimer m_firstFrame;
#endif
    QVariantMap m_item, m_source, m_next, m_vp;
    QVariantList m_segments, m_chapters, m_audio, m_subs;
    bool m_markFrame = false;
    bool m_refresh = false;
    QSet<QString> m_addedSubs;
    QString m_subSig;             // the subtitle on screen as last told to the core
    double m_subDelay = 0;
};
