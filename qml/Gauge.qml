import QtQuick
import QtQuick.Shapes

// a small white speedometer cut into the quality zones. the needle glides after the readings and the
// zone under it takes its colour; once both are in, only the weaker one keeps it
Item {
    id: g
    readonly property real u: Theme.u
    property string title: ""
    property var zones: []               // { label, from, to, color }
    property real value: 0
    property bool measuring: false
    property bool measured: false
    property bool waiting: false         // the other one goes first
    property bool decided: false         // both are in: colour only where `chosen`
    property bool chosen: false          // the weaker one (both when they match)
    property string number: ""
    property string unit: ""
    property string note: ""             // no reading: why
    property string extra: ""            // a small line under the result
    readonly property int count: zones.length
    function fraction(v) {
        if (!count) return 0
        for (var i = count - 1; i >= 0; --i) {
            var z = zones[i]
            if (v >= z.from) return Math.min(1, (i + Math.min(1, (v - z.from) / Math.max(0.001, z.to - z.from))) / count)
        }
        return 0
    }
    // where the needle is drawn, eased: readings come a few times a second
    property real pos: fraction(measuring || measured ? value : 0)
    Behavior on pos { SmoothedAnimation { velocity: 0.5; maximumEasingTime: 450 } }
    readonly property int under: (measuring || measured) && pos > 0.002 ? Math.min(count - 1, Math.floor(pos * count)) : -1
    readonly property int zone: {
        var z = -1
        if (measured) for (var i = 0; i < count; ++i) if (value >= zones[i].from) z = i
        return z
    }
    readonly property bool lit: decided ? chosen : true
    readonly property color accent: zone >= 0 ? zones[zone].color : Theme.fg

    readonly property real startAngle: -210
    readonly property real sweep: 240
    readonly property real gap: 2.4
    readonly property real r: 104 * u
    readonly property real stroke: 9 * u
    readonly property real cx: width / 2
    readonly property real cy: 48 * u + r
    implicitHeight: readout.y + readout.height
    opacity: waiting ? 0.5 : 1
    Behavior on opacity { NumberAnimation { duration: 300 } }

    Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: g.title
        color: Theme.fg2
        font { family: Theme.display; pixelSize: 23 * g.u; weight: Font.DemiBold }
    }

    Repeater {
        model: g.count
        Shape {
            id: section
            required property int index
            readonly property color tint: g.zones[index] ? g.zones[index].color : "white"
            // the zone under the needle in colour; after the verdict only the weaker one's
            readonly property bool on: g.under === index && g.lit
            readonly property bool marked: g.under === index
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: section.on ? section.tint : section.marked ? Qt.rgba(1, 1, 1, 0.85) : Qt.rgba(1, 1, 1, 0.16)
                Behavior on strokeColor { ColorAnimation { duration: 420; easing.type: Easing.InOutQuad } }
                strokeWidth: g.stroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: g.cx; centerY: g.cy; radiusX: g.r; radiusY: g.r
                    startAngle: g.startAngle + section.index * g.sweep / g.count + g.gap * 2
                    sweepAngle: g.sweep / g.count - g.gap * 4
                }
            }
        }
    }

    Item {
        x: g.cx; y: g.cy
        rotation: g.startAngle + g.sweep * g.pos + 90
        opacity: g.measuring || g.measured ? 1 : 0.4
        Behavior on opacity { NumberAnimation { duration: 300 } }
        Rectangle {
            x: -2 * g.u; y: -(g.r - 22 * g.u)
            width: 4 * g.u
            height: g.r - 22 * g.u
            radius: width / 2
            color: "white"
            antialiasing: true
        }
    }
    Rectangle {
        x: g.cx - width / 2; y: g.cy - height / 2
        width: 14 * g.u; height: width; radius: width / 2
        color: "white"
    }

    // the reading sits in the opening at the bottom of the dial
    Column {
        id: readout
        y: g.cy + 26 * g.u
        width: parent.width
        spacing: 0
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: g.number || "–"
            color: g.number ? Theme.fg : Theme.fg3
            font { family: Theme.display; pixelSize: 44 * g.u; weight: Font.Bold; features: { "tnum": 1 } }
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: g.unit
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 19 * g.u }
        }
        Item {
            width: parent.width
            height: 48 * g.u
            Text {
                anchors.centerIn: parent
                text: g.note ? g.note : g.zone >= 0 ? g.zones[g.zone].label : g.waiting ? qsTr("Waiting") : g.measuring ? qsTr("Measuring…") : ""
                color: g.zone >= 0 && g.lit && !g.note ? g.accent : g.zone >= 0 && !g.note ? Theme.fg : Theme.fg3
                font { family: Theme.display; pixelSize: 24 * g.u; weight: g.zone >= 0 ? Font.Bold : Font.Medium }
                // the chosen one reads a touch larger
                scale: g.decided && g.chosen ? 1.2 : 1
                Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 420 } }
            }
        }
        Text {
            width: parent.width
            visible: text !== ""
            horizontalAlignment: Text.AlignHCenter
            text: g.extra
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 17 * g.u }
        }
    }
}
