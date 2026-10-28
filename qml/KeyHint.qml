// a key hint ("OK  Select") in whatever was used last: the remote's key as a cap, the keyboard's
// key, or the pad's own button (playstation shapes, xbox / nintendo letters, a position for others),
// following the bindings in settings › controls
import QtQuick
import "Pads.js" as Pads

Row {
    id: h
    property string key: "OK"
    property string label: ""
    property bool pad: false                 // unused: the hint follows Remote.inputKind itself
    property real u: 1
    property real labelSize: 33 * u
    property color labelColor: Qt.rgba(1, 1, 1, 0.62)
    spacing: 14 * u

    readonly property string mode: Remote.inputKind
    readonly property var capText: ({ OK: "OK", BACK: "BACK", MENU: "MENU", ARROWS: "‹ ›" })
    // the first button or key bound to the action
    readonly property string bound: {
        var side = mode === "pad" ? "pad" : mode === "keyboard" ? "keys" : ""
        var l = side ? (Input.bindings[side] || {})[key] : null
        return l && l.length ? l[0] : ""
    }
    readonly property var look: mode === "pad" && bound ? Pads.look(Input.padKind, bound)
                              : mode === "pad" && key === "ARROWS" ? { type: "symbol", value: "dpad" }
                              : { type: "pill", value: mode === "keyboard" && bound ? Pads.keyText(bound) : h.capText[h.key] || h.key }
    readonly property bool round: look.type !== "pill"
    readonly property color line: Qt.rgba(1, 1, 1, 0.45)

    Item {
        anchors.verticalCenter: parent.verticalCenter
        width: h.round ? 50 * h.u : cap.width; height: 46 * h.u
        // a cap: the remote's square-ish key, a keyboard key, or a pad's named button as a pill
        Rectangle {
            id: cap
            visible: !h.round
            anchors.verticalCenter: parent.verticalCenter
            width: capLabel.implicitWidth + 28 * h.u; height: 46 * h.u
            radius: h.mode === "pad" ? height / 2 : 11 * h.u
            color: "transparent"
            border.width: 1.6 * h.u; border.color: h.line
            Text {
                id: capLabel
                anchors.centerIn: parent
                text: h.mode === "pad" ? String(h.look.value).toUpperCase() : h.look.value
                font.family: Theme.display; font.pixelSize: 24 * h.u; font.weight: Font.Bold
                font.letterSpacing: 0.8 * h.u
                color: Qt.rgba(1, 1, 1, 0.85)
            }
        }
        // a face button: round, with its shape or letter
        Rectangle {
            visible: h.round
            anchors.centerIn: parent
            width: 50 * h.u; height: width; radius: width / 2
            color: "transparent"
            border.width: 1.8 * h.u; border.color: h.line
            Symbol {
                visible: h.look.type === "symbol"
                anchors.centerIn: parent
                width: 34 * h.u; height: width
                name: h.look.type === "symbol" ? h.look.value : ""
                weight: 2.4
                color: Qt.rgba(1, 1, 1, 0.9)
            }
            Text {
                visible: h.look.type === "letter"
                anchors.centerIn: parent
                text: h.look.type === "letter" ? h.look.value : ""
                font.family: Theme.rounded; font.pixelSize: 26 * h.u; font.weight: Font.Bold
                color: Qt.rgba(1, 1, 1, 0.9)
            }
            // a pad without its own labels: four dots, the one to press filled
            Item {
                visible: h.look.type === "dots"
                anchors.centerIn: parent
                width: 30 * h.u; height: width
                Repeater {
                    model: [{ p: "north", x: 0.5, y: 0.17 }, { p: "east", x: 0.83, y: 0.5 }, { p: "south", x: 0.5, y: 0.83 }, { p: "west", x: 0.17, y: 0.5 }]
                    Rectangle {
                        required property var modelData
                        readonly property bool on: h.look.value === modelData.p
                        width: 9 * h.u; height: width; radius: width / 2
                        x: modelData.x * parent.width - width / 2; y: modelData.y * parent.height - height / 2
                        color: on ? Qt.rgba(1, 1, 1, 0.95) : "transparent"
                        border.width: on ? 0 : 1.4 * h.u; border.color: Qt.rgba(1, 1, 1, 0.55)
                    }
                }
            }
        }
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: h.label
        font.family: Theme.display; font.pixelSize: h.labelSize
        color: h.labelColor
    }
}
