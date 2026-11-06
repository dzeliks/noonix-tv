#include "videosurface.h"

#include <QLoggingCategory>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScreen>

#include <mpv/client.h>

#include <cmath>

#ifdef Q_OS_WIN
#include <windows.h>
#include <dxgi1_6.h>
#endif

Q_LOGGING_CATEGORY(lcVideo, "noonix-tv.video")

#ifdef Q_OS_ANDROID
float androidHdrPeak();
void androidVideoShown(bool on);
void androidRegisterVideo(VideoSurface *s);
#endif

VideoSurface::VideoSurface(QObject *parent)
    : QObject(parent)
{
}

VideoSurface::~VideoSurface() = default;

#ifdef Q_OS_WIN
namespace {

// is windows hdr on for this screen's output (dxgi: the output's colour space is pq / bt.2020)
bool hdrOn(QScreen *screen)
{
    if (!screen)
        return false;
    IDXGIFactory1 *factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void **>(&factory))))
        return false;
    bool on = false;
    IDXGIAdapter1 *adapter = nullptr;
    for (UINT a = 0; !on && factory->EnumAdapters1(a, &adapter) != DXGI_ERROR_NOT_FOUND; ++a) {
        IDXGIOutput *output = nullptr;
        for (UINT o = 0; !on && adapter->EnumOutputs(o, &output) != DXGI_ERROR_NOT_FOUND; ++o) {
            IDXGIOutput6 *output6 = nullptr;
            DXGI_OUTPUT_DESC1 desc{};
            // qt names a screen by its gdi device name, as dxgi does
            if (SUCCEEDED(output->QueryInterface(__uuidof(IDXGIOutput6), reinterpret_cast<void **>(&output6)))
                && SUCCEEDED(output6->GetDesc1(&desc))
                && QString::fromWCharArray(desc.DeviceName) == screen->name())
                on = desc.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
            if (output6)
                output6->Release();
            output->Release();
        }
        adapter->Release();
    }
    factory->Release();
    return on;
}

LRESULT CALLBACK videoWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    // never takes the focus from the app above it
    if (msg == WM_MOUSEACTIVATE)
        return MA_NOACTIVATE;
    return DefWindowProcW(hwnd, msg, wp, lp);
}

} // namespace
#endif

bool VideoSurface::nativeWanted(QScreen *screen)
{
    const QString want = qEnvironmentVariable("NOONIX_VIDEO");
    if (want == QLatin1String("native"))
        return true;
    if (want == QLatin1String("scene"))
        return false;
#ifdef Q_OS_WIN
    const bool on = hdrOn(screen);
    qCInfo(lcVideo) << "windows hdr on" << (screen ? screen->name() : QString()) << on;
    return on;
#elif defined(Q_OS_ANDROID)
    // the own surface view: hdr when the panel has it, and no c2d copy per frame either way
    Q_UNUSED(screen)
    return true;
#else
    Q_UNUSED(screen)
    return false;
#endif
}

QJsonObject VideoSurface::displayCaps()
{
#ifdef Q_OS_ANDROID
    if (m_nativeMode) {
        if (m_hdrPeak < 0)
            m_hdrPeak = androidHdrPeak();
        // dolby vision: gpu-next reshapes it on android too, but only in the own surface
        return QJsonObject{{QStringLiteral("hdr"), m_hdrPeak > 0}, {QStringLiteral("dv"), true}};
    }
#endif
    // hdr reaches the screen only through mpv's own window (gpu-next, which reshapes dolby vision
    // too); the qt scene tone maps it
    return QJsonObject{{QStringLiteral("hdr"), m_nativeMode}, {QStringLiteral("dv"), m_nativeMode}};
}

void VideoSurface::attach(QQuickWindow *window)
{
    m_window = window;
    applyDescription();
#ifdef Q_OS_WIN
    if (m_nativeMode) {
        static const wchar_t *cls = L"NoonixTvVideo";
        WNDCLASSW wc{};
        wc.lpfnWndProc = videoWndProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
        wc.lpszClassName = cls;
        RegisterClassW(&wc);
        // a plain popup without a taskbar button, made to sit right under the app's window
        HWND hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, cls, L"Noonix TV video", WS_POPUP,
                                    0, 0, 16, 16, nullptr, nullptr, wc.hInstance, nullptr);
        m_nativeWnd = hwnd;
        if (m_mpv && hwnd) {
            int64_t wid = reinterpret_cast<intptr_t>(hwnd);
            mpv_set_option(m_mpv, "wid", MPV_FORMAT_INT64, &wid);
        }
        connect(window, &QWindow::activeChanged, this, &VideoSurface::restackNative);
        connect(window, &QWindow::screenChanged, this, &VideoSurface::restackNative);
        qCInfo(lcVideo) << "native video window" << hwnd;
        // nothing on the qt side has to come up first
        QMetaObject::invokeMethod(this, &VideoSurface::renderReady, Qt::QueuedConnection);
    }
#endif
#ifdef Q_OS_ANDROID
    if (m_nativeMode) {
        if (m_hdrPeak < 0)
            m_hdrPeak = androidHdrPeak();
        qCInfo(lcVideo) << "android video surface, hdr10 peak" << m_hdrPeak;
        androidRegisterVideo(this);
        startThread();
    }
#endif
    m_active = true;
    emit activeChanged();
}

void VideoSurface::detach()
{
#ifdef Q_OS_ANDROID
    stopThread();
#endif
#ifdef Q_OS_WIN
    if (m_nativeWnd)
        DestroyWindow(static_cast<HWND>(m_nativeWnd));
#endif
    m_nativeWnd = nullptr;
    m_window = nullptr;
}

void VideoSurface::showNative(bool on)
{
#ifdef Q_OS_WIN
    if (!m_nativeWnd)
        return;
    if (!on) {
        ShowWindow(static_cast<HWND>(m_nativeWnd), SW_HIDE);
        return;
    }
    restackNative();
    ShowWindow(static_cast<HWND>(m_nativeWnd), SW_SHOWNOACTIVATE);
#elif defined(Q_OS_ANDROID)
    if (m_nativeMode)
        androidVideoShown(on);
#else
    Q_UNUSED(on)
#endif
}

void VideoSurface::restackNative()
{
#ifdef Q_OS_WIN
    if (!m_nativeWnd || !m_window)
        return;
    // the app's own rectangle (physical pixels), the video window just below it
    HWND top = reinterpret_cast<HWND>(m_window->winId());
    RECT r;
    GetWindowRect(top, &r);
    SetWindowPos(static_cast<HWND>(m_nativeWnd), top, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOACTIVATE);
#endif
}

void VideoSurface::setView(QQuickItem *view)
{
    m_view = view;
    if (view)
        view->update();
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
    const bool hdr = gamma == QLatin1String("pq") || gamma == QLatin1String("hlg");
#ifdef Q_OS_ANDROID
    if (m_nativeMode) {
        // a decoder reopening (vo switch) reports params without a transfer for a moment
        if (gamma.isEmpty() && !m_colour.isEmpty())
            return;
        // hdr on an hdr panel: the decoder's own output (once the surface view is up). otherwise
        // mpv tone maps to sdr
        if (hdr && m_hdrPeak > 0 && m_embedAllowed)
            enterEmbed();
        else
            leaveEmbed();
        const bool embed = m_embed;
        if (m_mpv && !embed) {
            mpv_set_property_string(m_mpv, "target-trc", "gamma2.2");
            mpv_set_property_string(m_mpv, "target-prim", "bt.709");
        }
        QVariantMap c;
        c[QStringLiteral("hdr")] = embed;
        c[QStringLiteral("transfer")] = embed ? gamma : QStringLiteral("gamma2.2");
        c[QStringLiteral("primaries")] = embed ? QStringLiteral("bt.2020") : QStringLiteral("bt.709");
        c[QStringLiteral("toneMapped")] = hdr && !embed;
        c[QStringLiteral("decoder")] = embed;   // no frames for the glass, qt draws the subtitles
        if (c != m_colour) {
            m_colour = c;
            qCInfo(lcVideo) << "colour" << c;
            emit colourChanged();
        }
        return;
    }
#endif
    if (m_nativeMode) {
        // mpv's own d3d11 window: it tells windows the video's colour space (target-colorspace-hint)
        QVariantMap c;
        c[QStringLiteral("hdr")] = hdr;
        c[QStringLiteral("transfer")] = hdr ? gamma : QStringLiteral("gamma2.2");
        c[QStringLiteral("primaries")] = hdr ? QStringLiteral("bt.2020") : QStringLiteral("bt.709");
        c[QStringLiteral("toneMapped")] = false;
        if (c != m_colour) {
            m_colour = c;
            qCInfo(lcVideo) << "colour" << c;
            emit colourChanged();
        }
        return;
    }
    // the qt scene is sdr: mpv tone maps hdr down to the desktop
    if (m_mpv) {
        mpv_set_property_string(m_mpv, "target-trc", "gamma2.2");
        mpv_set_property_string(m_mpv, "target-prim", "bt.709");
    }
    QVariantMap c;
    c[QStringLiteral("hdr")] = false;
    c[QStringLiteral("transfer")] = "gamma2.2";
    c[QStringLiteral("primaries")] = "bt.709";
    c[QStringLiteral("toneMapped")] = hdr;
    if (c != m_colour) {
        m_colour = c;
        qCInfo(lcVideo) << "colour" << c;
        emit colourChanged();
    }
}

void VideoSurface::setGlass(bool on)
{
    if (m_glass.exchange(on) == on || !on)
        return;
    // grab the frame on screen now, paused video never renders another one
    m_grabNow = true;
    if (m_view)
        m_view->update();
#ifdef Q_OS_ANDROID
    if (m_nativeMode) {
        {
            std::lock_guard lock(m_mutex);
            m_wake = true;
        }
        m_cv.notify_all();
    }
#endif
}

void VideoSurface::setFps(double fps)
{
    // the glass follows the video up to 30 updates a second (see the linux surface)
    m_grabEvery = fps > 30.5 ? int(std::ceil(fps / 30.0 - 0.01)) : 1;
}
