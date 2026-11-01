import QtQuick

// the floor under a sheet: the mouse stops here, nothing behind it hovers or clicks. outside() is a
// left click on it; right click stays back (Main's handler), or it would close twice
MouseArea {
    signal outside()
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.AllButtons
    onClicked: function (m) { if (m.button === Qt.LeftButton) outside() }
}
