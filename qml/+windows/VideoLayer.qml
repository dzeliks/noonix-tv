// windows: mpv draws inside the scene, under everything else. always there (hidden under the
// browse scene): its first frame sets up mpv's renderer, playback waits for that. native video
// (windows hdr): mpv has its own window under ours, nothing to draw here
import QtQuick
import Noonix.Video

Loader {
    active: !Video.native
    sourceComponent: VideoView {
        surface: Video
    }
}
