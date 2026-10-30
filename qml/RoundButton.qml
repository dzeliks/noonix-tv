import QtQuick

// a round glass button for the pointer: a row's page arrows. white under the mouse like any focus
Item {
    id: rb
    property string icon: "chevronleft"
    property real size: 64                // across, on the 1920 grid
    signal clicked()
    readonly property bool hovered: pt.containsMouse
    readonly property real u: Theme.u
    width: size * u; height: width
    scale: pt.containsMouse ? 1.08 : 1
    Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
    Glass { anchors.fill: parent; kind: "chip"; radius: width / 2; visible: !pt.containsMouse }
    Rectangle { anchors.fill: parent; radius: width / 2; color: "white"; visible: pt.containsMouse }
    Symbol {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: (rb.icon === "chevronleft" ? -2 : rb.icon === "chevronright" ? 2 : 0) * rb.u
        width: 34 * rb.size / 64 * rb.u; height: width
        name: rb.icon
        weight: 2.4
        color: pt.containsMouse ? Theme.focusFg : Theme.fg
    }
    // a pointer like a card's: the row around it takes the focus, a click is the button's
    Pointer { id: pt; okKey: false; onTapped: rb.clicked() }
}
