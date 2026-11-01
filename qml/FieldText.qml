import QtQuick

// a field's line: what's typed (or a dim placeholder) and a blinking caret where typing goes on.
// solid while keys come in, blinking once they stop
Item {
    id: f
    property string text: ""
    property string placeholder: ""
    property bool secret: false
    property bool active: true           // being typed into: the caret shows
    property real size: 26 * Theme.u
    readonly property real u: Theme.u
    implicitHeight: label.implicitHeight

    Text {
        id: label
        // the caret has its place before the first letter: nothing moves when it comes or goes
        anchors { left: parent.left; leftMargin: 9 * f.u; right: parent.right; rightMargin: 9 * f.u; verticalCenter: parent.verticalCenter }
        text: f.text.length ? (f.secret ? "•".repeat(f.text.length) : f.text) : f.placeholder
        color: f.text.length ? Theme.fg : Theme.fg3
        elide: Text.ElideLeft
        font { family: Theme.display; pixelSize: f.size; weight: Font.Medium }
    }
    Rectangle {
        id: caret
        property bool on: true
        visible: f.active && on
        x: f.text.length ? label.x + Math.min(label.contentWidth, label.width) + 3 * f.u : 0
        anchors.verticalCenter: parent.verticalCenter
        width: 3 * f.u
        height: f.size * 1.15
        radius: width / 2
        color: Theme.fg
    }
    Timer {
        id: blink
        interval: 530
        repeat: true
        running: f.active
        onTriggered: caret.on = !caret.on
    }
    onTextChanged: { caret.on = true; blink.restart() }
    onActiveChanged: caret.on = true
}
