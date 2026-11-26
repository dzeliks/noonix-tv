import QtQuick

// a thin white line round what the remote, a pad or the keyboard has selected, with its zoom.
// not for the mouse or a finger: the pointer is on it already
Rectangle {
    property bool on: false
    color: "transparent"
    border { width: 2.5 * Theme.u; color: "white" }
    // the same pointing the lift reads (Theme's follows it a step later): a switch fades, never blinks
    opacity: on && Input.pointing !== true ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
}
