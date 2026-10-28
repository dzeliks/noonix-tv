import QtQuick

// one line of text: elided at rest, scrolls through once it's focused and doesn't fit (like tvos)
Item {
    id: m
    property alias text: label.text
    property alias font: label.font
    property alias color: label.color
    property bool active: false
    readonly property bool overflows: label.implicitWidth > width
    readonly property real gap: 60 * Theme.u
    implicitHeight: label.implicitHeight
    clip: running.running || shift.x !== 0

    Text {
        id: label
        width: m.active && m.overflows ? implicitWidth : m.width
        elide: m.active && m.overflows ? Text.ElideNone : Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
        transform: Translate { id: shift }
    }
    // the second copy follows the first round, so the loop has no jump
    Text {
        visible: m.active && m.overflows
        anchors.verticalCenter: parent.verticalCenter
        x: label.implicitWidth + m.gap
        text: label.text
        font: label.font
        color: label.color
        transform: shift
    }

    onActiveChanged: if (!active) { running.stop(); shift.x = 0 }
    SequentialAnimation {
        id: running
        running: m.active && m.overflows && m.visible
        loops: Animation.Infinite
        PauseAnimation { duration: 1200 }
        NumberAnimation {
            target: shift; property: "x"
            from: 0; to: -(label.implicitWidth + m.gap)
            // a steady reading pace, not a fixed time
            duration: (label.implicitWidth + m.gap) / (90 * Theme.u) * 1000
        }
        ScriptAction { script: shift.x = 0 }
    }
}
