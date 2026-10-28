import QtQuick

// apple's activity indicator: eight rounded spokes, the lit one steps round with a fading tail
Item {
    id: sp
    property color color: "white"
    property bool running: visible
    implicitWidth: 56 * Theme.u
    implicitHeight: implicitWidth
    property int step: 0

    Timer {
        // 8 steps a turn, a turn in ~0.8 s like ios
        interval: 100
        repeat: true
        running: sp.running
        onTriggered: sp.step = (sp.step + 1) % 8
    }
    Repeater {
        model: 8
        Rectangle {
            required property int index
            readonly property int age: (sp.step - index + 8) % 8
            width: sp.width * 0.09
            height: sp.height * 0.28
            radius: width / 2
            color: sp.color
            opacity: 1 - age * 0.11
            x: (sp.width - width) / 2
            y: 0
            transform: Rotation { origin.x: width / 2; origin.y: sp.height / 2; angle: index * 45 }
        }
    }
}
