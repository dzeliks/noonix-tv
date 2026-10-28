#pragma once
// small copy of the video frame for the glass over video (render thread only):
// box-filtered by halving blits, flipped to top-down, read back through a pbo
#include <QImage>
#include <QSize>
#include <vector>

class VideoGrab
{
public:
    using GetProc = void *(*)(const char *name);
    // needs the current gl context and its loader
    bool init(GetProc getProc);
    void release();
    // call after mpv rendered into `fbo` and before the swap. bottomUp: rows as gl draws to the
    // screen (mpv with flip_y); an fbo mpv drew without it is already top-down
    void read(const QSize &from, const QSize &to, unsigned fbo = 0, bool bottomUp = true);
    // waits at most timeoutMs for the last read, null image if not ready
    QImage collect(int timeoutMs);

private:
    struct Level { unsigned fbo = 0, rb = 0; QSize size; };
    void rebuild(const QSize &from, const QSize &to);

    bool m_ok = false;
    std::vector<Level> m_levels;
    QSize m_from, m_to;
    unsigned m_pbo = 0;
    void *m_fence = nullptr;
};
