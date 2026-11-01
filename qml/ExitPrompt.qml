import QtQuick

// back at the top of the app: leave noonix tv? (no stays focused, so a stray back is harmless)
FocusScope {
    id: ep
    readonly property real u: Theme.u
    property int choice: 1               // 0 exit, 1 stay
    signal stay()
    signal leave()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    function open() { choice = 1; opacity = 1; forceActiveFocus() }
    function close() { opacity = 0 }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: ep.stay() }

    Column {
        anchors.centerIn: parent
        spacing: 56 * ep.u
        scale: ep.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Exit Noonix TV?")
            color: Theme.fg
            font { family: Theme.display; pixelSize: 64 * ep.u; weight: Font.Bold }
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 28 * ep.u
            GlassButton {
                width: 300 * ep.u
                text: qsTr("Exit")
                focused: ep.activeFocus && ep.choice === 0
                pointerFocus: false
                onPointed: ep.choice = 0
                onClicked: ep.leave()
            }
            GlassButton {
                width: 300 * ep.u
                text: qsTr("Stay")
                focused: ep.activeFocus && ep.choice === 1
                pointerFocus: false
                onPointed: ep.choice = 1
                onClicked: ep.stay()
            }
        }
    }

    Keys.onLeftPressed: choice = 0
    Keys.onRightPressed: choice = 1
    Keys.onReturnPressed: choice === 0 ? leave() : stay()
    Keys.onEnterPressed: choice === 0 ? leave() : stay()
    Keys.onEscapePressed: stay()
    Keys.onBackPressed: stay()
    Keys.onPressed: function (e) { e.accepted = true }
}
