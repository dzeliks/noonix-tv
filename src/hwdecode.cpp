// does this device have a hardware hevc main10 decoder? that's what carries 4k, the speed check
// lifts the device to the top level with one. each platform asks its own video api, loaded at
// runtime so nothing new is linked; anything that fails answers no and the cpu test decides
#include "player.h"

#include <QMetaObject>
#include <thread>

#if defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#include <sys/system_properties.h>
#elif defined(Q_OS_WIN)
#include <d3d11.h>
#include <windows.h>
#elif defined(Q_OS_LINUX)
#include <dlfcn.h>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <vector>
#endif

namespace {

#if defined(Q_OS_ANDROID)
bool probe()
{
    // the emulator plays in software (player.cpp)
    char qemu[PROP_VALUE_MAX] = {}, oldQemu[PROP_VALUE_MAX] = {};
    __system_property_get("ro.boot.qemu", qemu);
    __system_property_get("ro.kernel.qemu", oldQemu);
    if (qemu[0] == '1' || oldQemu[0] == '1')
        return false;
    QJniEnvironment env;
    const int sdk = QNativeInterface::QAndroidApplication::sdkVersion();
    QJniObject list("android/media/MediaCodecList", "(I)V", jint(0));   // REGULAR_CODECS
    QJniObject infos = list.callObjectMethod("getCodecInfos", "()[Landroid/media/MediaCodecInfo;");
    if (!infos.isValid())
        return false;
    const auto arr = infos.object<jobjectArray>();
    const QJniObject hevc = QJniObject::fromString(QStringLiteral("video/hevc"));
    for (jsize i = 0, n = env->GetArrayLength(arr); i < n; ++i) {
        QJniObject info = QJniObject::fromLocalRef(env->GetObjectArrayElement(arr, i));
        if (!info.isValid() || info.callMethod<jboolean>("isEncoder"))
            continue;
        const QString name = info.callObjectMethod("getName", "()Ljava/lang/String;").toString();
        const bool hw = sdk >= 29 ? info.callMethod<jboolean>("isHardwareAccelerated")
                                  : !name.startsWith(QLatin1String("OMX.google.")) && !name.startsWith(QLatin1String("c2.android."));
        if (!hw)
            continue;
        QJniObject caps = info.callObjectMethod("getCapabilitiesForType",
            "(Ljava/lang/String;)Landroid/media/MediaCodecInfo$CodecCapabilities;", hevc.object<jstring>());
        if (!caps.isValid())
            continue;   // not an hevc decoder (the call threw)
        QJniObject video = caps.callObjectMethod("getVideoCapabilities", "()Landroid/media/MediaCodecInfo$VideoCapabilities;");
        if (!video.isValid() || !video.callMethod<jboolean>("isSizeSupported", "(II)Z", jint(3840), jint(2160)))
            continue;
        QJniObject levels = caps.getObjectField("profileLevels", "[Landroid/media/MediaCodecInfo$CodecProfileLevel;");
        const auto la = levels.object<jobjectArray>();
        for (jsize j = 0, m = la ? env->GetArrayLength(la) : 0; j < m; ++j) {
            QJniObject pl = QJniObject::fromLocalRef(env->GetObjectArrayElement(la, j));
            const jint p = pl.getField<jint>("profile");
            if (p == 2 || p == 0x1000 || p == 0x2000)   // main10, main10 hdr10, hdr10+
                return true;
        }
    }
    return false;
}
#elif defined(Q_OS_WIN)
bool probe()
{
    HMODULE lib = LoadLibraryW(L"d3d11.dll");
    if (!lib)
        return false;
    auto create = reinterpret_cast<PFN_D3D11_CREATE_DEVICE>(reinterpret_cast<void *>(GetProcAddress(lib, "D3D11CreateDevice")));
    ID3D11Device *dev = nullptr;
    if (!create || FAILED(create(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT, nullptr, 0,
                                 D3D11_SDK_VERSION, &dev, nullptr, nullptr))) {
        FreeLibrary(lib);
        return false;
    }
    // D3D11_DECODER_PROFILE_HEVC_VLD_MAIN10, spelled out: the header's constant wants dxguid
    static const GUID main10 = { 0x107af0e0, 0xef1a, 0x4d19, { 0xab, 0xa8, 0x67, 0xa1, 0x63, 0x07, 0x3d, 0x13 } };
    bool found = false;
    ID3D11VideoDevice *video = nullptr;
    if (SUCCEEDED(dev->QueryInterface(__uuidof(ID3D11VideoDevice), reinterpret_cast<void **>(&video)))) {
        for (UINT i = 0, n = video->GetVideoDecoderProfileCount(); i < n && !found; ++i) {
            GUID g;
            BOOL ok = FALSE;
            found = SUCCEEDED(video->GetVideoDecoderProfile(i, &g)) && IsEqualGUID(g, main10)
                    && SUCCEEDED(video->CheckVideoDecoderFormat(&g, DXGI_FORMAT_P010, &ok)) && ok;
        }
        video->Release();
    }
    dev->Release();
    FreeLibrary(lib);
    return found;
}
#elif defined(Q_OS_LINUX)
// libva by hand: mpv decodes through it (hwdec=vaapi), so it's there wherever that works
bool probe()
{
    void *va = dlopen("libva.so.2", RTLD_NOW | RTLD_LOCAL);
    void *drm = va ? dlopen("libva-drm.so.2", RTLD_NOW | RTLD_LOCAL) : nullptr;
    if (!drm) {
        if (va)
            dlclose(va);
        return false;
    }
    using Display = void *;
    using Callback = void (*)(void *, const char *);
    auto getDisplay = reinterpret_cast<Display (*)(int)>(dlsym(drm, "vaGetDisplayDRM"));
    auto quiet = reinterpret_cast<Callback (*)(Display, Callback, void *)>(dlsym(va, "vaSetInfoCallback"));
    auto init = reinterpret_cast<int (*)(Display, int *, int *)>(dlsym(va, "vaInitialize"));
    auto terminate = reinterpret_cast<int (*)(Display)>(dlsym(va, "vaTerminate"));
    auto maxProfiles = reinterpret_cast<int (*)(Display)>(dlsym(va, "vaMaxNumProfiles"));
    auto maxEntries = reinterpret_cast<int (*)(Display)>(dlsym(va, "vaMaxNumEntrypoints"));
    auto profiles = reinterpret_cast<int (*)(Display, int *, int *)>(dlsym(va, "vaQueryConfigProfiles"));
    auto entries = reinterpret_cast<int (*)(Display, int, int *, int *)>(dlsym(va, "vaQueryConfigEntrypoints"));
    bool found = false;
    if (getDisplay && init && terminate && maxProfiles && maxEntries && profiles && entries) {
        constexpr int HEVCMain10 = 18, VLD = 1;   // VAProfileHEVCMain10, VAEntrypointVLD (va/va.h)
        for (int node = 128; node < 136 && !found; ++node) {
            const int fd = open(("/dev/dri/renderD" + std::to_string(node)).c_str(), O_RDWR | O_CLOEXEC);
            if (fd < 0)
                continue;
            Display d = getDisplay(fd);
            int major = 0, minor = 0;
            if (d && quiet)
                quiet(d, nullptr, nullptr);
            if (d && init(d, &major, &minor) == 0) {
                std::vector<int> ps(std::max(1, maxProfiles(d)));
                int n = 0;
                if (profiles(d, ps.data(), &n) == 0) {
                    for (int i = 0; i < n && !found; ++i) {
                        if (ps[i] != HEVCMain10)
                            continue;
                        std::vector<int> es(std::max(1, maxEntries(d)));
                        int m = 0;
                        if (entries(d, HEVCMain10, es.data(), &m) == 0)
                            for (int j = 0; j < m; ++j)
                                found = found || es[j] == VLD;
                    }
                }
                terminate(d);
            }
            close(fd);
        }
    }
    dlclose(drm);
    dlclose(va);
    return found;
}
#else
bool probe() { return false; }
#endif

} // namespace

void Player::probeHevc10()
{
    if (m_hevc10 >= 0 || m_probing)
        return;
    m_probing = true;
    std::thread([this] {
        const bool yes = probe();
        QMetaObject::invokeMethod(this, [this, yes] {
            m_hevc10 = yes ? 1 : 0;
            m_probing = false;
            emit hevc10Changed();
        }, Qt::QueuedConnection);
    }).detach();
}
