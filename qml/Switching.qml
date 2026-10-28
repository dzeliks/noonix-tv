import QtQuick

// mid-screen while a reroll runs (other subtitles, another source). shows after a beat, so an
// instant switch doesn't flash it
Item {
    id: hud
    readonly property real u: Theme.u
    property string text: ""
    property bool busy: false
    readonly property bool up: opacity > 0
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    function start(t) { text = t; busy = true; delay.restart() }
    function stop() { busy = false; delay.stop(); opacity = 0 }
    Timer { id: delay; interval: 250; onTriggered: if (hud.busy) hud.opacity = 1 }

    width: Math.max(320 * u, label.implicitWidth + 96 * u)
    height: 232 * u
    scale: opacity > 0.5 ? 1 : 0.94
    Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
    Glass { anchors.fill: parent; kind: "panel"; radius: 44 * hud.u }
    Spinner {
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 54 * hud.u }
        width: 64 * hud.u; height: width
        running: hud.visible
    }
    Text {
        id: label
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 46 * hud.u }
        text: hud.text
        color: Theme.fg
        font { family: Theme.text; pixelSize: 27 * hud.u; weight: Font.Medium }
    }
}
