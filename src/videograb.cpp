#include "videograb.h"

#ifdef __ANDROID__
#include <GLES3/gl3.h>
#else
#include <GL/glcorearb.h>
#endif

#include <cstring>

namespace {

struct Gl {
    PFNGLGENFRAMEBUFFERSPROC genFramebuffers;
    PFNGLDELETEFRAMEBUFFERSPROC deleteFramebuffers;
    PFNGLBINDFRAMEBUFFERPROC bindFramebuffer;
    PFNGLGENRENDERBUFFERSPROC genRenderbuffers;
    PFNGLDELETERENDERBUFFERSPROC deleteRenderbuffers;
    PFNGLBINDRENDERBUFFERPROC bindRenderbuffer;
    PFNGLRENDERBUFFERSTORAGEPROC renderbufferStorage;
    PFNGLFRAMEBUFFERRENDERBUFFERPROC framebufferRenderbuffer;
    PFNGLBLITFRAMEBUFFERPROC blitFramebuffer;
    PFNGLGENBUFFERSPROC genBuffers;
    PFNGLDELETEBUFFERSPROC deleteBuffers;
    PFNGLBINDBUFFERPROC bindBuffer;
    PFNGLBUFFERDATAPROC bufferData;
    PFNGLMAPBUFFERRANGEPROC mapBufferRange;
    PFNGLUNMAPBUFFERPROC unmapBuffer;
    PFNGLREADPIXELSPROC readPixels;
    PFNGLPIXELSTOREIPROC pixelStorei;
    PFNGLFENCESYNCPROC fenceSync;
    PFNGLCLIENTWAITSYNCPROC clientWaitSync;
    PFNGLDELETESYNCPROC deleteSync;
    PFNGLISENABLEDPROC isEnabled;
    PFNGLENABLEPROC enable;
    PFNGLDISABLEPROC disable;
} gl;

VideoGrab::GetProc getProc = nullptr;

template <typename T>
bool load(T &fn, const char *name)
{
    fn = reinterpret_cast<T>(getProc(name));
    return fn != nullptr;
}

} // namespace

bool VideoGrab::init(GetProc proc)
{
    getProc = proc;
    m_ok = load(gl.genFramebuffers, "glGenFramebuffers") && load(gl.deleteFramebuffers, "glDeleteFramebuffers")
        && load(gl.bindFramebuffer, "glBindFramebuffer") && load(gl.genRenderbuffers, "glGenRenderbuffers")
        && load(gl.deleteRenderbuffers, "glDeleteRenderbuffers") && load(gl.bindRenderbuffer, "glBindRenderbuffer")
        && load(gl.renderbufferStorage, "glRenderbufferStorage")
        && load(gl.framebufferRenderbuffer, "glFramebufferRenderbuffer")
        && load(gl.blitFramebuffer, "glBlitFramebuffer") && load(gl.genBuffers, "glGenBuffers")
        && load(gl.deleteBuffers, "glDeleteBuffers") && load(gl.bindBuffer, "glBindBuffer")
        && load(gl.bufferData, "glBufferData") && load(gl.mapBufferRange, "glMapBufferRange")
        && load(gl.unmapBuffer, "glUnmapBuffer") && load(gl.readPixels, "glReadPixels")
        && load(gl.pixelStorei, "glPixelStorei") && load(gl.fenceSync, "glFenceSync")
        && load(gl.clientWaitSync, "glClientWaitSync") && load(gl.deleteSync, "glDeleteSync")
        && load(gl.isEnabled, "glIsEnabled") && load(gl.enable, "glEnable") && load(gl.disable, "glDisable");
    return m_ok;
}

void VideoGrab::release()
{
    if (!m_ok)
        return;
    for (Level &l : m_levels) {
        gl.deleteFramebuffers(1, &l.fbo);
        gl.deleteRenderbuffers(1, &l.rb);
    }
    m_levels.clear();
    if (m_pbo)
        gl.deleteBuffers(1, &m_pbo);
    m_pbo = 0;
    if (m_fence)
        gl.deleteSync(static_cast<GLsync>(m_fence));
    m_fence = nullptr;
    m_from = m_to = {};
}

void VideoGrab::rebuild(const QSize &from, const QSize &to)
{
    const QSize keepFrom = from, keepTo = to;
    release();
    m_from = keepFrom;
    m_to = keepTo;
    // halve while it stays above twice the target: every step is an exact 2x2 box
    std::vector<QSize> sizes;
    QSize s = from;
    while (s.width() / 2 >= to.width() * 2 && s.height() / 2 >= to.height() * 2) {
        s /= 2;
        sizes.push_back(s);
    }
    if (s.width() / 2 >= to.width() && s.height() / 2 >= to.height() && s / 2 != to) {
        s /= 2;
        sizes.push_back(s);
    }
    sizes.push_back(to);
    for (const QSize &sz : sizes) {
        Level l;
        l.size = sz;
        gl.genRenderbuffers(1, &l.rb);
        gl.bindRenderbuffer(GL_RENDERBUFFER, l.rb);
        gl.renderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, sz.width(), sz.height());
        gl.genFramebuffers(1, &l.fbo);
        gl.bindFramebuffer(GL_FRAMEBUFFER, l.fbo);
        gl.framebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, l.rb);
        m_levels.push_back(l);
    }
    gl.bindRenderbuffer(GL_RENDERBUFFER, 0);
    gl.bindFramebuffer(GL_FRAMEBUFFER, 0);
    gl.genBuffers(1, &m_pbo);
    gl.bindBuffer(GL_PIXEL_PACK_BUFFER, m_pbo);
    gl.bufferData(GL_PIXEL_PACK_BUFFER, GLsizeiptr(to.width()) * to.height() * 4, nullptr, GL_STREAM_READ);
    gl.bindBuffer(GL_PIXEL_PACK_BUFFER, 0);
}

void VideoGrab::read(const QSize &from, const QSize &to, unsigned fbo, bool bottomUp)
{
    if (!m_ok || from.isEmpty() || to.isEmpty())
        return;
    if (from != m_from || to != m_to)
        rebuild(from, to);
    if (m_fence) {
        gl.deleteSync(static_cast<GLsync>(m_fence));
        m_fence = nullptr;
    }
    const bool scissor = gl.isEnabled(GL_SCISSOR_TEST);
    if (scissor)
        gl.disable(GL_SCISSOR_TEST);

    unsigned src = fbo;
    QSize srcSize = from;
    for (size_t i = 0; i < m_levels.size(); ++i) {
        const Level &l = m_levels[i];
        const bool flip = i + 1 == m_levels.size() && bottomUp;
        gl.bindFramebuffer(GL_READ_FRAMEBUFFER, src);
        gl.bindFramebuffer(GL_DRAW_FRAMEBUFFER, l.fbo);
        // bottom-up: the last step flips so row 0 is the top
        gl.blitFramebuffer(0, 0, srcSize.width(), srcSize.height(),
                           0, flip ? l.size.height() : 0, l.size.width(), flip ? 0 : l.size.height(),
                           GL_COLOR_BUFFER_BIT, GL_LINEAR);
        src = l.fbo;
        srcSize = l.size;
    }
    gl.bindFramebuffer(GL_READ_FRAMEBUFFER, src);
    gl.bindBuffer(GL_PIXEL_PACK_BUFFER, m_pbo);
    gl.pixelStorei(GL_PACK_ALIGNMENT, 4);
    gl.readPixels(0, 0, to.width(), to.height(), GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    m_fence = gl.fenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    gl.bindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    gl.bindFramebuffer(GL_FRAMEBUFFER, fbo);
    if (scissor)
        gl.enable(GL_SCISSOR_TEST);
}

QImage VideoGrab::collect(int timeoutMs)
{
    if (!m_fence)
        return {};
    const GLenum r = gl.clientWaitSync(static_cast<GLsync>(m_fence), GL_SYNC_FLUSH_COMMANDS_BIT,
                                       GLuint64(timeoutMs) * 1000000);
    if (r != GL_ALREADY_SIGNALED && r != GL_CONDITION_SATISFIED)
        return {};
    gl.deleteSync(static_cast<GLsync>(m_fence));
    m_fence = nullptr;
    QImage img(m_to, QImage::Format_RGBX8888);
    gl.bindBuffer(GL_PIXEL_PACK_BUFFER, m_pbo);
    const void *p = gl.mapBufferRange(GL_PIXEL_PACK_BUFFER, 0, GLsizeiptr(m_to.width()) * m_to.height() * 4, GL_MAP_READ_BIT);
    if (p) {
        // tightly packed rows, same as the image (width * 4 is 4-aligned)
        std::memcpy(img.bits(), p, size_t(img.sizeInBytes()));
        gl.unmapBuffer(GL_PIXEL_PACK_BUFFER);
    } else {
        img = {};
    }
    gl.bindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    return img;
}
