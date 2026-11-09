#pragma once

// the screen stays on while a video plays: the desktop's screensaver inhibit (freedesktop on linux,
// the execution state on windows), the activity's keep screen on flag on android
namespace KeepAwake {
void set(bool on);
}
