// one on-screen keyboard key: dark glass at rest, white and lifted when focused,
// a short squash on press
import QtQuick
import QtQuick.Effects

Item {
    id: k
    property real u: 1
    property string label: ""          // text, or
    property string symbol: ""         // a Symbol name
    property bool fn: false            // function key: darker glass, smaller label
    property bool focused: false
    property bool lit: false           // a modifier that is on (shift / ctrl): tinted
    property real radius: 26 * u
    property real labelSize: (fn ? 40 : 64) * u
    property real symbolSize: 56 * u
    property real grow: 1.14           // focus lift; wide caps want less

    // anything declared inside a KeyCap rides on the key (scales with it)
    default property alias content: extra.data

    function pop() { squash.restart() }

    Item {
        id: cap
        anchors.fill: parent
        scale: k.focused ? k.grow : 1.0
        Behavior on scale { SpringAnimation { spring: 5.0; damping: 0.6; epsilon: 0.0005 } }
        transform: Scale {
            id: press
            origin.x: cap.width / 2; origin.y: cap.height / 2
            xScale: 1; yScale: 1
        }

        RectangularShadow {
            anchors.fill: body
            radius: k.radius
            offset.y: 14 * k.u
            blur: 40 * k.u
            color: Qt.rgba(0, 0, 0, 0.45)
            opacity: k.focused ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }
        }
        Rectangle {
            id: body
            anchors.fill: parent
            radius: k.radius
            color: k.focused ? Qt.rgba(1, 1, 1, 0.97)
                 : k.lit ? Qt.rgba(0.04, 0.52, 1.0, 0.85)
                 : Qt.rgba(1, 1, 1, k.fn ? 0.10 : 0.21)
            Behavior on color { ColorAnimation { duration: 160 } }
        }
        Text {
            anchors.centerIn: parent
            visible: k.symbol === ""
            text: k.label
            font.family: Theme.display
            font.pixelSize: k.labelSize
            font.weight: k.fn ? Font.Medium : Font.Normal
            color: k.focused ? "#1C1C1E" : "white"
        }
        Symbol {
            anchors.centerIn: parent
            visible: k.symbol !== ""
            width: k.symbolSize; height: width
            name: k.symbol
            weight: 1.9
            color: k.focused ? "#1C1C1E" : "white"
        }
        Item { id: extra; anchors.fill: parent }
    }

    SequentialAnimation {
        id: squash
        NumberAnimation { target: press; properties: "xScale,yScale"; to: 0.88; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: press; properties: "xScale,yScale"; to: 1.0; duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
    }
}
