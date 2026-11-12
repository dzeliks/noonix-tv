import QtQuick

// the tv wallpaper (screensaver window) live behind a full-screen sheet of glass, like the
// tv terminal. the stream runs only while this is shown
Item {
    id: wg
    property bool running: true
    // the stream stays up while this is merely hidden: closing it tears pipewire down on the gui
    // thread (~30 ms), so it only goes where nobody sees (playback starts under the cover)
    property bool hold: false
    // the stream has to draw to become ready, so only the look fades, never the stream item
    visible: running || look.opacity > 0
    property string wallId: ""
    readonly property bool ready: wall.ready
    onReadyChanged: if (Desktop.debug) console.log("wallglass ready", ready, wallId)
    onWallIdChanged: if (Desktop.debug) console.log("wallglass id", wallId)
    // asked often at first (the daemon starts with us), then rarely: no tv wallpaper on this desktop
    property int asks: 0
    Timer {
        interval: wg.asks < 25 ? 200 : 2000
        running: wg.running && wg.wallId === "" && Qt.platform.os === "linux"
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (Remote.wallpaperId !== "") { wg.wallId = Remote.wallpaperId; return }
            wg.asks++
            Remote.askWallpaper()
        }
    }
    Connections {
        target: Remote
        function onWallpaperIdChanged() { if (wg.wallId === "") wg.wallId = Remote.wallpaperId }
    }
    // no wallpaper (another desktop, or not yet): a quiet gradient
    Rectangle {
        anchors.fill: parent
        opacity: wg.running ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 320 } }
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#1b1630" }
            GradientStop { position: 1.0; color: "#050508" }
        }
    }
    GlassBackdrop {
        id: wall
        width: wg.width; height: wg.height
        uuid: wg.running || wg.hold ? wg.wallId : ""
    }
    // no live tv wallpaper: the desktop's own picture (windows), frosted the same way
    readonly property string stillUrl: wallId === "" ? Desktop.wallpaper() : ""
    readonly property bool still: !wall.ready && pic.status === Image.Ready
    Image {
        id: pic
        width: wg.width; height: wg.height
        visible: false
        source: wg.running ? wg.stillUrl : ""
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(Math.max(1, Math.round(wg.width * Theme.dpr / 2)), Math.max(1, Math.round(wg.height * Theme.dpr / 2)))
        asynchronous: true
    }
    GlassSource {
        id: still
        sourceItem: pic
        hideSource: true
        live: wg.still
    }
    Glass {
        id: look
        anchors.fill: parent
        opacity: wg.running && (wall.ready || wg.still) ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 320 } }
        kind: "panel"
        radius: 0
        refraction: 38 * Theme.u
        dim: 0.58                       // a touch darker than the terminal (0.40): posters sit on it
        backdrop: wall.ready ? wall.tex : still.tex
        frostTex: wall.ready ? wall.frostTex : still.frost
        backdropOn: 1
    }
}
