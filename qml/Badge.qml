import QtQuick

// small spec tag: 4K, HDR10, DV, Atmos
Rectangle {
    id: badge
    property string text: ""
    property bool strong: false
    property color tint: "white"
    property bool onLight: false        // sits on a focused (white) row
    readonly property real u: Theme.u
    width: label.implicitWidth + 18 * u
    height: 34 * u
    radius: 8 * u
    color: strong ? tint : "transparent"
    border.width: strong ? 0 : 1.6 * u
    border.color: onLight ? Qt.rgba(0, 0, 0, 0.45) : Qt.rgba(1, 1, 1, 0.5)
    Text {
        id: label
        anchors.centerIn: parent
        text: badge.text
        color: badge.strong ? (badge.onLight ? "white" : Theme.focusFg) : (badge.onLight ? Theme.focusFg : Theme.fg)
        font { family: Theme.text; pixelSize: 19 * badge.u; weight: Font.Bold; letterSpacing: 0.4 * badge.u }
    }
}
