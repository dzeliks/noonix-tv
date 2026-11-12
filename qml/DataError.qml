import QtQuick

// the db file didn't open: the core runs on an empty one in memory, so the app would look like a
// first start and keep nothing. this instead of everything else, one way out
FocusScope {
    id: de
    readonly property real u: Theme.u
    property string error: ""            // the file and what sqlite said
    signal leave()
    visible: error !== ""
    onVisibleChanged: if (visible) forceActiveFocus()
    // home still builds underneath and asks for the focus when it's ready: the keys stay here
    onActiveFocusChanged: if (visible && !activeFocus) forceActiveFocus()

    Rectangle { anchors.fill: parent; color: "#000000" }
    Shield {}

    Column {
        anchors.centerIn: parent
        width: Math.min(de.width - 2 * Theme.margin, 1100 * de.u)
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: qsTr("Noonix TV can't open its data")
            color: Theme.fg
            font { family: Theme.display; pixelSize: 64 * de.u; weight: Font.Bold }
        }
        Item { width: 1; height: 26 * de.u }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, 900 * de.u)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: qsTr("Your profiles and settings are still on this device, they just couldn't be read. Close Noonix TV and open it again. If this comes back, the storage may be full or the file damaged.")
            color: Theme.fg2
            lineHeight: 1.15
            font { family: Theme.text; pixelSize: 28 * de.u }
        }
        Item { width: 1; height: 22 * de.u }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, 900 * de.u)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WrapAnywhere
            text: de.error
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 22 * de.u }
        }
        Item { width: 1; height: 56 * de.u }
        GlassButton {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 300 * de.u
            text: qsTr("Close")
            focused: de.activeFocus
            primary: true
            pointerFocus: false
            onClicked: de.leave()
        }
    }

    Keys.onReturnPressed: leave()
    Keys.onEnterPressed: leave()
    Keys.onEscapePressed: leave()
    Keys.onBackPressed: leave()
    Keys.onPressed: function (e) { e.accepted = true }
}
