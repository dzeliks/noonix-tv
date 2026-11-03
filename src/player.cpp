#include "player.h"
#ifdef Q_OS_ANDROID
#include <sys/system_properties.h>
#endif
#include "remote.h"
#include "videosurface.h"
#include "noonix_core/src/bridge.cxxqt.h"

#include <QEventLoop>
#include <cmath>
#include <QCoreApplication>
#include <QJsonArray>
#include <QLocale>
#include <QJsonDocument>
#include <QMetaObject>
#include <QPointer>
#include <QQuickWindow>
#include <QScreen>
#include <QVariant>
#include <mpv/client.h>

#include <chrono>
#include <clocale>
#include <thread>

namespace {

enum Prop : uint64_t { TimePos = 1, Duration, Pause, VideoParams, CacheWait, Seeking, CacheDur, EofReached, TrackList, ChapterList, Sid };

QVariant fromNode(const mpv_node &n)
{
    switch (n.format) {
    case MPV_FORMAT_STRING: return QString::fromUtf8(n.u.string);
    case MPV_FORMAT_FLAG: return bool(n.u.flag);
    case MPV_FORMAT_INT64: return qlonglong(n.u.int64);
    case MPV_FORMAT_DOUBLE: return n.u.double_;
    case MPV_FORMAT_NODE_MAP: {
        QVariantMap m;
        for (int i = 0; i < n.u.list->num; ++i)
            m.insert(QString::fromUtf8(n.u.list->keys[i]), fromNode(n.u.list->values[i]));
        return m;
    }
    case MPV_FORMAT_NODE_ARRAY: {
        QVariantList l;
        for (int i = 0; i < n.u.list->num; ++i)
            l << fromNode(n.u.list->values[i]);
        return l;
    }
    default: return {};
    }
}

double asDouble(const mpv_event_property *p)
{
    return p->format == MPV_FORMAT_DOUBLE ? *static_cast<double *>(p->data) : 0.0;
}

bool asFlag(const mpv_event_property *p)
{
    return p->format == MPV_FORMAT_FLAG && *static_cast<int *>(p->data);
}

QString toJson(const QJsonObject &o)
{
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

} // namespace

Player::Player(bool nativeVideo, QObject *parent)
    : QObject(parent)
{
    std::setlocale(LC_NUMERIC, "C"); // libmpv needs it
    m_mpv = mpv_create();
    auto opt = [this](const char *k, const char *v) { mpv_set_option_string(m_mpv, k, v); };
#ifdef Q_OS_WIN
    if (nativeVideo) {
        // its own window (wid comes with the window): d3d11 swapchain, and windows learns the
        // video's colour space, so hdr10 reaches the tv as hdr10
        opt("vo", "gpu-next");
        opt("gpu-api", "d3d11");
        opt("gpu-context", "d3d11");
        opt("target-colorspace-hint", "yes");
        opt("force-window", "no");
    } else {
        opt("vo", "libmpv");
    }
    // d3d11va / dxva2, copied back where the opengl interop is missing
    opt("hwdec", "auto-safe");
#elif defined(Q_OS_ANDROID)
    Q_UNUSED(nativeVideo)
    opt("vo", "libmpv");
    // mediacodec's frames copied back for the gl render (the direct one wants its own surface);
    // phones and tv boxes keep the default scalers, high-quality is too much for most of them
    // the emulator's decoder hangs inside android and takes mpv's core with it
    char qemu[PROP_VALUE_MAX] = {}, oldQemu[PROP_VALUE_MAX] = {};
    __system_property_get("ro.boot.qemu", qemu);
    __system_property_get("ro.kernel.qemu", oldQemu);
    opt("hwdec", qemu[0] == '1' || oldQemu[0] == '1' ? "no" : "mediacodec-copy");
    // the decoder on its own thread: a stuck mediacodec must not hold mpv's core, the ui's property
    // reads wait for the core and android kills an app that stops answering
    opt("vd-queue-enable", "yes");
#else
    Q_UNUSED(nativeVideo)
    opt("vo", "libmpv");
    opt("hwdec", "vaapi");
#endif
#ifndef Q_OS_ANDROID
    opt("profile", "high-quality");
#endif
    opt("video-sync", "display-resample");
    opt("keep-open", "yes");
    opt("volume", "95");   // remote volume is the pc's, mpv stays at 95 like the other players
    opt("ytdl", "no");
    opt("osc", "no");
    opt("osd-level", "0");
    opt("input-default-bindings", "no");
    opt("input-vo-keyboard", "no");
    opt("load-scripts", "no");   // never the user's mpv scripts (no second scrobbler)
    opt("config", "no");
    opt("sub-auto", "fuzzy");
    opt("cache", "yes");
    opt("demuxer-max-bytes", "512MiB");
    opt("demuxer-readahead-secs", "60");
    opt("network-timeout", "30");
    opt("terminal", "yes");
    opt("msg-level", "all=warn");
#ifdef NOONIX_DEFAULT_MUTE
    const bool mute = qEnvironmentVariable("NOONIX_MUTE") != QLatin1String("0");
#else
    const bool mute = qEnvironmentVariable("NOONIX_MUTE") == QLatin1String("1");
#endif
    opt("mute", mute ? "yes" : "no");
    // dev knob: NOONIX_MPV_OPTS="start=5,pause=yes"
    for (const QString &kv : qEnvironmentVariable("NOONIX_MPV_OPTS").split(QLatin1Char(','), Qt::SkipEmptyParts)) {
        const qsizetype eq = kv.indexOf(QLatin1Char('='));
        if (eq > 0)
            mpv_set_option_string(m_mpv, kv.left(eq).toUtf8().constData(), kv.mid(eq + 1).toUtf8().constData());
    }
    mpv_initialize(m_mpv);
    mpv_observe_property(m_mpv, TimePos, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, Duration, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, Pause, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, VideoParams, "video-params", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, CacheWait, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, Seeking, "seeking", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, CacheDur, "demuxer-cache-duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, EofReached, "eof-reached", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, TrackList, "track-list/count", MPV_FORMAT_INT64);
    mpv_observe_property(m_mpv, ChapterList, "chapter-list/count", MPV_FORMAT_INT64);
    mpv_observe_property(m_mpv, Sid, "sid", MPV_FORMAT_STRING);
    mpv_set_wakeup_callback(m_mpv, [](void *ctx) {
        QMetaObject::invokeMethod(static_cast<Player *>(ctx), &Player::drain, Qt::QueuedConnection);
    }, this);

    m_tickTimer.setInterval(10000);
    m_tickTimer.setTimerType(Qt::VeryCoarseTimer);
    connect(&m_tickTimer, &QTimer::timeout, this, [this] { tick(QStringLiteral("tick")); });
#ifdef Q_OS_ANDROID
    // no picture although packets wait for the decoder: a mediacodec that never answers, software
    // from here on. a slow network doesn't count, the cache is empty then
    m_firstFrame.setSingleShot(true);
    m_firstFrame.setInterval(6000);
    connect(&m_firstFrame, &QTimer::timeout, this, [this] {
        if (getNode("demuxer-cache-duration").toDouble() < 2) {
            m_firstFrame.start();
            return;
        }
        qWarning("no frame from mediacodec, decoding in software");
        // not the waiting kind: the old decoder has to let go first
        const char *no = "no";
        mpv_set_property_async(m_mpv, 0, "hwdec", MPV_FORMAT_STRING, &no);
    });
#endif
    m_posEmit.start();
}

Player::~Player()
{
    mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
    mpv_terminate_destroy(m_mpv);
}

void Player::setCore(Core *core)
{
    m_core = core;
    connect(core, &Core::result, this, [this](quint64 id, bool ok, const QString &json) { onCoreResult(id, ok, json); });
    connect(core, &Core::push, this, [this](const QString &name, const QString &json) { onCorePush(name, json); });
}

void Player::reportDisplay()
{
    if (m_video)
        call(QStringLiteral("display.caps"), m_video->displayCaps(), nullptr);
}

void Player::setRenderReady()
{
    m_renderReady = true;
    if (m_pendingLoad)
        std::exchange(m_pendingLoad, {})();
}

void Player::call(const QString &method, const QJsonObject &args, std::function<void(bool, const QJsonObject &)> done)
{
    if (!m_core)
        return;
    const quint64 id = m_core->call(method, toJson(args));
    if (done)
        m_pending.insert(id, std::move(done));
}

void Player::onCoreResult(quint64 id, bool ok, const QString &json)
{
    auto it = m_pending.find(id);
    if (it == m_pending.end())
        return;
    auto done = std::move(it.value());
    m_pending.erase(it);
    done(ok, QJsonDocument::fromJson(json.toUtf8()).object());
}

void Player::onCorePush(const QString &name, const QString &json)
{
    if (!name.startsWith(QLatin1String("playback.")))
        return;
    const QJsonObject o = QJsonDocument::fromJson(json.toUtf8()).object();
    if (o.value(QLatin1String("session")).toInteger() != m_session)
        return;
    if (name == QLatin1String("playback.skip")) {
        m_segments = o.value(QLatin1String("segments")).toArray().toVariantList();
        emit segmentsChanged();
    } else if (name == QLatin1String("playback.next")) {
        m_next = o.value(QLatin1String("next")).toObject().toVariantMap();
        emit nextChanged();
    } else if (name == QLatin1String("playback.subs")) {
        // the best one goes on only when the file had nothing for the preferences, or when the
        // core says so (liked before, or the file's own track was reported)
        const bool take = o.value(QLatin1String("take")).toBool();
        bool on = false;
        for (const QVariant &t : m_subs)
            on = on || t.toMap().value(QStringLiteral("selected")).toBool();
        const QJsonArray subs = o.value(QLatin1String("subs")).toArray();
        bool first = true;
        for (qsizetype i = 0; i < subs.size(); ++i) {
            const QJsonObject sub = subs.at(i).toObject();
            const QString path = sub.value(QLatin1String("path")).toString();
            // the picker's search finds the automatic ones again
            if (m_addedSubs.contains(path))
                continue;
            m_addedSubs.insert(path);
            addSubtitle(path, sub.value(QLatin1String("title")).toString(), sub.value(QLatin1String("lang")).toString(), (take || !on) && first);
            first = false;
        }
    }
}

void Player::setState(const QString &s, const QString &error)
{
    if (s == m_state && error == m_error)
        return;
    m_state = s;
    m_error = error;
    emit stateChanged();
}

void Player::setOpt(const char *name, const QString &value)
{
    mpv_set_property_string(m_mpv, name, value.toUtf8().constData());
}

void Player::loadFile(const QString &url, double start)
{
    auto go = [this, url, start] {
        // starts paused: the tv's refresh rate is matched before the first frame moves
        setOpt("pause", QStringLiteral("yes"));
        setOpt("start", start > 0 ? QString::number(start, 'f', 1) : QStringLiteral("none"));
        const QByteArray u = url.toUtf8();
        m_markFrame = true;
        m_addedSubs.clear();
        m_subSig.clear();
        setSubDelay(0);
        Desktop::devMark(QStringLiteral("play: loadfile"));
        const char *cmd[] = {"loadfile", u.constData(), "replace", nullptr};
        mpv_command_async(m_mpv, 0, cmd);
    };
    if (m_renderReady)
        go();
    else
        m_pendingLoad = go;
}

void Player::play(const QVariantMap &request)
{
    // the core closes the previous session itself when it opens the new one
    m_tickTimer.stop();
    m_session = 0;
    m_next.clear();
    m_segments.clear();
    emit nextChanged();
    emit segmentsChanged();
    setState(QStringLiteral("opening"));
    Desktop::devMark(QStringLiteral("play: open"));
    call(QStringLiteral("playback.open"), QJsonObject::fromVariantMap(request), [this](bool ok, const QJsonObject &r) {
        if (!ok) {
            setState(QStringLiteral("error"), r.value(QLatin1String("error")).toString());
            return;
        }
        m_session = r.value(QLatin1String("session")).toInteger();
        m_item = r.value(QLatin1String("item")).toObject().toVariantMap();
        m_source = r.value(QLatin1String("stream")).toObject().toVariantMap();
        emit itemChanged();
        QStringList headers;
        for (const QJsonValue &h : r.value(QLatin1String("headers")).toArray())
            headers << h.toString().replace(QLatin1Char(','), QLatin1String("\\,"));
        setOpt("http-header-fields", headers.join(QLatin1Char(',')));
        setOpt("alang", r.value(QLatin1String("alang")).toString());
        setOpt("slang", r.value(QLatin1String("slang")).toString());
        setOpt("force-media-title", m_item.value(QStringLiteral("title")).toString());
        m_ending = false;
        setState(QStringLiteral("loading"));
        loadFile(r.value(QLatin1String("url")).toString(), r.value(QLatin1String("start")).toDouble());
    });
}

void Player::playUrl(const QString &url)
{
    m_session = 0;
    m_ending = false;
    m_item = {{QStringLiteral("title"), url.section(QLatin1Char('/'), -1)}};
    emit itemChanged();
    setState(QStringLiteral("loading"));
    loadFile(url, 0);
}

void Player::playNext()
{
    if (m_next.isEmpty())
        return;
    QVariantMap req = m_next;
    req.insert(QStringLiteral("start"), 0);
    play(req);
}

void Player::onFileLoaded()
{
    m_dur = getNode("duration").toDouble();
    emit durationChanged();
    refreshTracks();
    double fps = getNode("container-fps").toDouble();
    if (fps <= 0)
        fps = getNode("estimated-vf-fps").toDouble();
    if (m_video)
        m_video->setFps(fps);
    if (!m_session) {
        setPaused(false);
        setState(QStringLiteral("playing"));
        return;
    }
    QJsonArray chapters;
    for (const QVariant &c : m_chapters) {
        const QVariantMap m = c.toMap();
        chapters.append(QJsonObject{{QStringLiteral("title"), m.value(QStringLiteral("title")).toString()},
                                    {QStringLiteral("time"), m.value(QStringLiteral("time")).toDouble()}});
    }
    const QString output = m_window && m_window->screen() ? m_window->screen()->name() : QString();
    const bool windowed = m_window && m_window->visibility() != QWindow::FullScreen;
    // the file's own subtitles: extra ones are only fetched for languages missing here, and the
    // core may pick another track (liked before, or this one was reported)
    QJsonArray embedded;
    for (const QVariant &t : m_subs) {
        const QVariantMap m = t.toMap();
        if (!m.value(QStringLiteral("external")).toBool())
            embedded.append(QJsonObject::fromVariantMap(m));
    }
    // dolby vision as the container declares it (0 = none): profile 5 has no hdr10 base to fall back to
    int dvProfile = 0;
    for (const QVariant &t : getNode("track-list").toList()) {
        const QVariantMap m = t.toMap();
        if (m.value(QStringLiteral("type")).toString() == QLatin1String("video") && m.value(QStringLiteral("selected")).toBool())
            dvProfile = m.value(QStringLiteral("dolby-vision-profile")).toInt();
    }
    const qint64 session = m_session;
    call(QStringLiteral("playback.loaded"),
         QJsonObject{{QStringLiteral("duration"), m_dur}, {QStringLiteral("fps"), fps}, {QStringLiteral("output"), output},
                     {QStringLiteral("refresh"), !windowed}, {QStringLiteral("chapters"), chapters},
                     {QStringLiteral("tracks"), embedded}, {QStringLiteral("dvProfile"), dvProfile}},
         [this, session](bool ok, const QJsonObject &r) {
             if (session != m_session)
                 return;
             if (ok) {
                 setOpt("video-sync", r.value(QLatin1String("sync")).toString(QStringLiteral("display-resample")));
                 m_refresh = r.value(QLatin1String("refresh")).toBool();
                 emit refreshMatchChanged();
                 m_segments = r.value(QLatin1String("segments")).toArray().toVariantList();
                 emit segmentsChanged();
                 const int pick = r.value(QLatin1String("subPick")).toInt();
                 if (pick > 0)
                     setSubtitleTrack(pick);
                 else if (pick == -1)
                     setSubtitleTrack(0);
             }
             setPaused(false);
             // the unpause lands later: the first report must already say playing
             m_paused = false;
             emit pausedChanged();
             setState(QStringLiteral("playing"));
             subChanged();
             tick(QStringLiteral("start"));
             m_tickTimer.start();
         });
}

void Player::tick(const QString &reason)
{
    if (!m_session)
        return;
    call(QStringLiteral("playback.tick"), QJsonObject{{QStringLiteral("position"), m_pos}, {QStringLiteral("duration"), m_dur},
                                                      {QStringLiteral("paused"), m_paused}, {QStringLiteral("reason"), reason}});
}

void Player::shutdown()
{
    m_tickTimer.stop();
    if (!m_session || !m_core)
        return;
    // the final save + scrobble must land before the process goes
    QEventLoop loop;
    QTimer::singleShot(3000, &loop, &QEventLoop::quit);
    call(QStringLiteral("playback.stop"),
         QJsonObject{{QStringLiteral("position"), m_pos}, {QStringLiteral("duration"), m_dur}, {QStringLiteral("reason"), QStringLiteral("quit")}},
         [&loop](bool, const QJsonObject &) { loop.quit(); });
    loop.exec();
    m_session = 0;
}

void Player::onEnd(const QString &reason, const QString &error)
{
    if (m_ending)
        return;
    m_ending = true;
    m_tickTimer.stop();
    if (reason == QLatin1String("error"))
        setState(QStringLiteral("error"), error);
    else
        setState(reason == QLatin1String("eof") ? QStringLiteral("ended") : QStringLiteral("idle"));
    if (!m_session) {
        emit ended(reason == QLatin1String("eof"));
        return;
    }
    const qint64 session = m_session;
    call(QStringLiteral("playback.stop"),
         QJsonObject{{QStringLiteral("position"), m_pos}, {QStringLiteral("duration"), m_dur}, {QStringLiteral("reason"), reason}},
         [this, session](bool ok, const QJsonObject &r) {
             if (session != m_session)
                 return;
             m_session = 0;
             const QVariantMap next = r.value(QLatin1String("next")).toObject().toVariantMap();
             if (!next.isEmpty()) {
                 m_next = next;
                 emit nextChanged();
             }
             emit ended(ok && r.value(QLatin1String("completed")).toBool());
         });
}

QVariant Player::getNode(const char *name)
{
    mpv_node n;
    if (mpv_get_property(m_mpv, name, MPV_FORMAT_NODE, &n) < 0)
        return {};
    QVariant v = fromNode(n);
    mpv_free_node_contents(&n);
    return v;
}

void Player::refreshTracks()
{
    m_audio.clear();
    m_subs.clear();
    for (const QVariant &t : getNode("track-list").toList()) {
        QVariantMap m = t.toMap();
        const QString type = m.value(QStringLiteral("type")).toString();
        QVariantMap out{{QStringLiteral("id"), m.value(QStringLiteral("id"))},
                        {QStringLiteral("lang"), m.value(QStringLiteral("lang"))},
                        {QStringLiteral("title"), m.value(QStringLiteral("title"))},
                        {QStringLiteral("codec"), m.value(QStringLiteral("codec"))},
                        {QStringLiteral("channels"), m.value(QStringLiteral("demux-channel-count"))},
                        {QStringLiteral("selected"), m.value(QStringLiteral("selected"))},
                        {QStringLiteral("forced"), m.value(QStringLiteral("forced"))},
                        {QStringLiteral("sdh"), m.value(QStringLiteral("hearing-impaired"))},
                        {QStringLiteral("external"), m.value(QStringLiteral("external"))},
                        {QStringLiteral("file"), m.value(QStringLiteral("external-filename"))}};
        if (type == QLatin1String("audio"))
            m_audio << out;
        else if (type == QLatin1String("sub"))
            m_subs << out;
    }
    m_chapters = getNode("chapter-list").toList();
    emit tracksChanged();
    subChanged();
}

void Player::subChanged()
{
    if (!m_session || m_state != QLatin1String("playing"))
        return;
    QVariantMap on;
    for (const QVariant &t : m_subs)
        if (t.toMap().value(QStringLiteral("selected")).toBool())
            on = t.toMap();
    const QString sig = on.isEmpty() ? QStringLiteral("off")
                                     : on.value(QStringLiteral("id")).toString() + QLatin1Char('|') + on.value(QStringLiteral("file")).toString();
    if (sig == m_subSig)
        return;
    m_subSig = sig;
    const qint64 session = m_session;
    call(QStringLiteral("playback.sub"), QJsonObject{{QStringLiteral("track"), on.isEmpty() ? QJsonValue() : QJsonValue(QJsonObject::fromVariantMap(on))}},
         [this, session, sig](bool ok, const QJsonObject &r) {
             if (!ok || session != m_session || sig != m_subSig)
                 return;
             setSubDelay(r.value(QLatin1String("delayMs")).toDouble() / 1000.0);
             const QByteArray note = r.value(QLatin1String("note")).toString().toUtf8();
             if (note.isEmpty())
                 return;
             QString text = QCoreApplication::translate("core", note.constData());
             for (const QJsonValue &a : r.value(QLatin1String("noteArgs")).toArray()) {
                 QString v = a.toString();
                 // "+0.8 s" -> "+0,8 s" where the locale says so
                 if (QLocale().decimalPoint() != QLatin1String("."))
                     v.replace(QLatin1Char('.'), QLocale().decimalPoint());
                 text = text.arg(v);
             }
             emit notice(text);
         });
}

void Player::setSubDelay(double secs)
{
    secs = std::round(secs * 10) / 10;
    const QByteArray v = QByteArray::number(secs, 'f', 1);
    mpv_set_property_string(m_mpv, "sub-delay", v.constData());
    if (qFuzzyCompare(1 + secs, 1 + m_subDelay))
        return;
    m_subDelay = secs;
    emit subDelayChanged();
}

void Player::drain()
{
    while (mpv_event *ev = mpv_wait_event(m_mpv, 0)) {
        switch (ev->event_id) {
        case MPV_EVENT_NONE:
            return;
        case MPV_EVENT_FILE_LOADED:
#ifdef Q_OS_ANDROID
            m_firstFrame.start();
#endif
            onFileLoaded();
            break;
        case MPV_EVENT_END_FILE: {
            auto *e = static_cast<mpv_event_end_file *>(ev->data);
            if (e->reason == MPV_END_FILE_REASON_REDIRECT)
                break;
#ifdef Q_OS_ANDROID
            m_firstFrame.stop();
#endif
            if (e->reason == MPV_END_FILE_REASON_ERROR)
                onEnd(QStringLiteral("error"), QString::fromUtf8(mpv_error_string(e->error)));
            else if (e->reason == MPV_END_FILE_REASON_EOF)
                onEnd(QStringLiteral("eof"), {});
            else if (e->reason == MPV_END_FILE_REASON_STOP && m_state != QLatin1String("opening") && m_state != QLatin1String("loading"))
                onEnd(QStringLiteral("user"), {});
            break;
        }
        case MPV_EVENT_PLAYBACK_RESTART:
#ifdef Q_OS_ANDROID
            m_firstFrame.stop();
#endif
            if (m_markFrame) {
                m_markFrame = false;
                Desktop::devMark(QStringLiteral("play: first frame"));
            }
            if (m_state == QLatin1String("playing"))
                tick(QStringLiteral("seek"));
            break;
        case MPV_EVENT_PROPERTY_CHANGE: {
            auto *p = static_cast<mpv_event_property *>(ev->data);
            switch (ev->reply_userdata) {
            case TimePos:
                m_pos = asDouble(p);
                // ~4 hz is plenty for the bar and the clock; keeps qml idle while playing.
                // a seek invalidates the timer so the new spot shows at once
                if (!m_posEmit.isValid() || m_posEmit.elapsed() >= 250) {
                    m_posEmit.start();
                    emit positionChanged();
                }
                break;
            case Duration:
                m_dur = asDouble(p);
                emit durationChanged();
                break;
            case Pause: {
                const bool was = m_paused;
                m_paused = asFlag(p);
                emit pausedChanged();
                if (was != m_paused && m_state == QLatin1String("playing"))
                    tick(m_paused ? QStringLiteral("pause") : QStringLiteral("resume"));
                break;
            }
            case CacheWait:
            case Seeking: {
                const bool b = getNode("paused-for-cache").toBool() || getNode("seeking").toBool();
                if (b != m_buffering) {
                    m_buffering = b;
                    emit bufferingChanged();
                }
                break;
            }
            case CacheDur:
                m_cache = asDouble(p);
                break;
            case EofReached:
                // keep-open holds the last frame; that is the end for us
                if (asFlag(p) && m_state == QLatin1String("playing")) {
                    m_pos = m_dur;
                    emit positionChanged();
                    onEnd(QStringLiteral("eof"), {});
                }
                break;
            case TrackList:
            case ChapterList:
            case Sid:
                if (m_state == QLatin1String("playing"))
                    refreshTracks();
                break;
            case VideoParams:
                m_vp = p->format == MPV_FORMAT_NODE ? fromNode(*static_cast<mpv_node *>(p->data)).toMap() : QVariantMap();
                if (m_video && !m_vp.isEmpty())
                    m_video->setVideoParams(m_vp);
                emit videoParamsChanged();
                break;
            }
            break;
        }
        default:
            break;
        }
    }
}

void Player::setRefreshMatch(bool on)
{
    m_refresh = on;
    emit refreshMatchChanged();
    if (!m_session)
        return;
    const qint64 session = m_session;
    call(QStringLiteral("playback.refresh"), QJsonObject{{QStringLiteral("on"), on}}, [this, session](bool ok, const QJsonObject &r) {
        if (!ok || session != m_session)
            return;
        setOpt("video-sync", r.value(QLatin1String("sync")).toString(QStringLiteral("display-resample")));
        // the tv just resynced: an exact seek to here lines sound and picture up again
        seekTo(m_pos);
    });
}

void Player::togglePause()
{
    // while it loads the file sits paused on purpose and unpauses itself
    if (m_state != QLatin1String("playing") && m_state != QLatin1String("ended"))
        return;
    setPaused(!m_paused);
}

void Player::setPaused(bool p)
{
    int flag = p;
    mpv_set_property_async(m_mpv, 0, "pause", MPV_FORMAT_FLAG, &flag);
}

void Player::seek(double secs)
{
    const QByteArray s = QByteArray::number(secs);
    const char *cmd[] = {"seek", s.constData(), "relative+exact", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
    m_posEmit.invalidate();
}

void Player::seekTo(double secs)
{
    const QByteArray s = QByteArray::number(secs);
    const char *cmd[] = {"seek", s.constData(), "absolute+exact", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
    m_posEmit.invalidate();
}

void Player::seekPreview(double secs)
{
    const QByteArray s = QByteArray::number(secs);
    const char *cmd[] = {"seek", s.constData(), "absolute+keyframes", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
    m_posEmit.invalidate();
}

void Player::setAudioTrack(int id)
{
    setOpt("aid", QString::number(id));
    refreshTracks();
}

void Player::setSubtitleTrack(int id)
{
    setOpt("sid", id > 0 ? QString::number(id) : QStringLiteral("no"));
    refreshTracks();
}

void Player::setSubtitleLift(bool on)
{
    mpv_set_property_string(m_mpv, "sub-pos", on ? "77" : "100");
}

void Player::addSubtitle(const QString &url, const QString &title, const QString &lang, bool select)
{
    const QByteArray u = url.toUtf8(), t = title.toUtf8(), l = lang.toUtf8();
    // "auto" adds the track without switching to it
    const char *cmd[] = {"sub-add", u.constData(), select ? "select" : "auto", t.constData(), l.constData(), nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void Player::stop()
{
    if (m_state == QLatin1String("idle"))
        return;
    if (m_state == QLatin1String("ended") || m_state == QLatin1String("error")) {
        const char *cmd[] = {"stop", nullptr};
        mpv_command_async(m_mpv, 0, cmd);
        setState(QStringLiteral("idle"));
        return;
    }
    onEnd(QStringLiteral("user"), {});
    const char *cmd[] = {"stop", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void Player::benchDecode(const QString &path)
{
    QPointer<Player> self(this);
    std::thread([self, file = path.toStdString()] {
        const auto report = [self](double fps, bool done) {
            QMetaObject::invokeMethod(qApp, [self, fps, done] { if (self) emit self->benchDecoded(fps, done); }, Qt::QueuedConnection);
        };
        mpv_handle *m = mpv_create();
        if (!m) {
            report(0, true);
            return;
        }
        const auto opt = [m](const char *k, const char *v) { mpv_set_option_string(m, k, v); };
        static const std::pair<const char *, const char *> quiet[] = { { "config", "no" }, { "terminal", "no" }, { "load-scripts", "no" },
            { "ytdl", "no" }, { "vo", "null" }, { "ao", "null" }, { "audio", "no" }, { "untimed", "yes" }, { "loop-file", "inf" } };
        for (const auto &[k, v] : quiet)
            opt(k, v);
#if defined(Q_OS_ANDROID)
        char qemu[PROP_VALUE_MAX] = {}, oldQemu[PROP_VALUE_MAX] = {};
        __system_property_get("ro.boot.qemu", qemu);
        __system_property_get("ro.kernel.qemu", oldQemu);
        opt("hwdec", qemu[0] == '1' || oldQemu[0] == '1' ? "no" : "mediacodec-copy");
#else
        // the copy variants work without a video output; they fall back to software by themselves
        opt("hwdec", "auto-copy-safe");
#endif
        const char *load[] = { "loadfile", file.c_str(), nullptr };
        double fps = 0;
        if (mpv_initialize(m) >= 0 && mpv_command(m, load) >= 0) {
            const auto now = [] { return std::chrono::steady_clock::now(); };
            const auto secs = [](auto d) { return std::chrono::duration<double>(d).count(); };
            const auto get = [m](const char *p) {
                double v = -1;
                return mpv_get_property(m, p, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : -1;
            };
            // the first frame (a hardware decoder takes a moment to open), then a short warm-up
            auto t0 = now();
            while (get("time-pos") < 0.2 && secs(now() - t0) < 10)
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            const double rate = get("container-fps") > 0 ? get("container-fps") : 24;
            const double length = get("duration") > 0 ? get("duration") : 1;
            double last = get("time-pos"), played = 0;
            if (last >= 0) {
                t0 = now();
                auto shown = t0;
                while (secs(now() - t0) < 2.5) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    const double t = get("time-pos");
                    if (t < 0)
                        continue;
                    played += t >= last ? t - last : length - last + t;   // looped
                    last = t;
                    fps = played * rate / secs(now() - t0);
                    if (secs(now() - shown) > 0.2) {
                        shown = now();
                        report(fps, false);
                    }
                }
            }
        }
        mpv_terminate_destroy(m);
        report(fps, true);
    }).detach();
}
