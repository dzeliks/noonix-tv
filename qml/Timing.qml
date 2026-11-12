import QtQuick

// subtitle timing by hand: a small capsule at the top while the subtitles stay where they are.
// left / right 0.1 s, up / down 1 s, ok keeps it for this release + subtitle, back puts it back.
// the mouse or a finger: the arrows and keep / undo are buttons, a tap outside keeps it
FocusScope {
    id: tm
    readonly property real u: Theme.u
    visible: false
    property real before: 0
    signal closed(bool saved)

    function open() {
        before = Player.subDelay
        visible = true
        forceActiveFocus()
    }
    function nudge(d) { Player.setSubDelay(Math.max(-60, Math.min(60, Math.round((Player.subDelay + d) * 10) / 10))) }
    function finish(save) {
        visible = false
        if (!save) Player.setSubDelay(before)
        closed(save && Player.subDelay !== before)
    }

    Keys.onPressed: function (e) {
        var k = e.key
        e.accepted = true
        if (k === Qt.Key_Left) nudge(-0.1)
        else if (k === Qt.Key_Right) nudge(0.1)
        else if (k === Qt.Key_Up) nudge(1)
        else if (k === Qt.Key_Down) nudge(-1)
        else if (k === Qt.Key_Return || k === Qt.Key_Enter) finish(true)
        else if (k === Qt.Key_Escape || k === Qt.Key_Back) finish(false)
        else if (k === Qt.Key_MediaTogglePlayPause || k === Qt.Key_MediaPlay || k === Qt.Key_MediaPause || k === Qt.Key_Space) Player.togglePause()
        else e.accepted = false
    }

    Shield { visible: tm.visible; onOutside: tm.finish(true) }
    Item {
        id: cap
        anchors.horizontalCenter: parent.horizontalCenter
        y: 64 * tm.u
        width: 720 * tm.u
        height: (Theme.pointing ? 262 : 168) * tm.u
        opacity: tm.visible ? 1 : 0
        Glass { anchors.fill: parent; kind: "panel"; radius: 44 * tm.u }
        Repeater {
            model: [-1, 1]
            Item {
                required property int modelData
                x: modelData < 0 ? 28 * tm.u : cap.width - width - 28 * tm.u
                y: 28 * tm.u
                width: 64 * tm.u; height: width
                Symbol {
                    visible: !Theme.pointing
                    anchors.centerIn: parent
                    width: 40 * tm.u; height: width
                    name: parent.modelData < 0 ? "chevronleft" : "chevronright"; weight: 2.2
                    color: Theme.fg2
                }
                RoundButton {
                    visible: Theme.pointing
                    icon: parent.modelData < 0 ? "chevronleft" : "chevronright"
                    onClicked: tm.nudge(parent.modelData * 0.1)
                }
            }
        }
        Column {
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 22 * tm.u }
            spacing: 2 * tm.u
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Theme.signedSecs(Player.subDelay)
                color: Theme.fg
                font { family: Theme.rounded; pixelSize: 50 * tm.u; weight: Font.Bold; features: { "tnum": 1 } }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Player.subDelay > 0 ? qsTr("Subtitles later") : Player.subDelay < 0 ? qsTr("Subtitles earlier") : qsTr("Subtitle timing")
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 23 * tm.u; weight: Font.Medium }
            }
        }
        Text {
            visible: !Theme.pointing
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 20 * tm.u }
            text: qsTr("◀ ▶  0.1 s     ▲ ▼  1 s     OK  keep     Back  undo")
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 19 * tm.u; weight: Font.Medium }
        }
        Row {
            visible: Theme.pointing
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 * tm.u }
            spacing: 20 * tm.u
            GlassButton { u: tm.u * 0.85; pointerFocus: false; text: qsTr("Undo"); onClicked: tm.finish(false) }
            GlassButton { u: tm.u * 0.85; pointerFocus: false; primary: true; text: qsTr("Keep"); onClicked: tm.finish(true) }
        }
    }
}
