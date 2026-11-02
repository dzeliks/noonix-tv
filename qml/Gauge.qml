import QtQuick
import QtQuick.Shapes

// a speedometer: one arc section per zone, the needle runs over them. the arc never moves, only the
// needle does, on the render thread
Item {
    id: g
    readonly property real u: Theme.u
    property string title: ""
    property var zones: []               // { label, from, to, color }
    property real value: 0
    property bool measured: false
    property bool busy: false            // no live number: the needle sweeps
    property bool waiting: false         // the other one goes first
    property bool weakest: false
    property string number: ""
    property string unit: ""
    property string note: ""             // an error instead of the reading
    readonly property int zone: {
        var z = -1
        for (var i = 0; i < zones.length; ++i) if (value >= zones[i].from) z = i
        return z
    }
    readonly property real startAngle: -210
    readonly property real sweep: 240
    readonly property real seg: zones.length ? sweep / zones.length : sweep
    readonly property real cx: width / 2
    readonly property real cy: 306 * u
    readonly property real r: 170 * u
    function fraction(v) {
        var n = zones.length
        if (!n) return 0
        for (var i = n - 1; i >= 0; --i) {
            if (v >= zones[i].from)
                return Math.min(1, (i + Math.min(1, (v - zones[i].from) / (zones[i].to - zones[i].from))) / n)
        }
        return 0
    }
    implicitHeight: 560 * u

    Rectangle {
        anchors.fill: parent
        radius: 44 * g.u
        color: Qt.rgba(1, 1, 1, g.weakest ? 0.085 : 0.05)
        border.width: g.weakest ? 3 * g.u : 1 * g.u
        border.color: g.weakest && g.zone >= 0 ? g.zones[g.zone].color : Qt.rgba(1, 1, 1, 0.1)
        Behavior on color { ColorAnimation { duration: 300 } }
        Behavior on border.color { ColorAnimation { duration: 300 } }
    }
    Text {
        y: 28 * g.u
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: g.title
        color: Theme.fg
        font { family: Theme.display; pixelSize: 29 * g.u; weight: Font.DemiBold }
    }

    Repeater {
        model: g.zones.length
        Item {
            id: section
            required property int index
            readonly property var info: g.zones[index] || ({ color: "white" })
            readonly property bool here: g.measured && g.zone === index
            readonly property bool reached: g.measured && g.zone >= index
            readonly property real mid: g.startAngle + (index + 0.5) * g.seg
            anchors.fill: parent
            // the zone it landed in glows, the weakest one more
            Shape {
                anchors.fill: parent
                opacity: section.here ? (g.weakest ? 0.42 : 0.22) : 0
                visible: opacity > 0
                preferredRendererType: Shape.CurveRenderer
                Behavior on opacity { NumberAnimation { duration: 420 } }
                ShapePath {
                    strokeColor: section.info.color
                    strokeWidth: 44 * g.u
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: g.cx; centerY: g.cy; radiusX: g.r; radiusY: g.r; startAngle: g.startAngle + section.index * g.seg + 3.2; sweepAngle: g.seg - 6.4 }
                }
            }
            Shape {
                anchors.fill: parent
                opacity: !g.measured ? 0.55 : section.reached ? 1 : 0.22
                preferredRendererType: Shape.CurveRenderer
                Behavior on opacity { NumberAnimation { duration: 420 } }
                ShapePath {
                    strokeColor: section.info.color
                    strokeWidth: 20 * g.u
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: g.cx; centerY: g.cy; radiusX: g.r; radiusY: g.r; startAngle: g.startAngle + section.index * g.seg + 3.2; sweepAngle: g.seg - 6.4 }
                }
            }
            Text {
                readonly property real a: section.mid * Math.PI / 180
                // the side labels grow away from the arc, so they end inside the card
                x: g.cx + Math.cos(a) * (g.r + 28 * g.u) - width / 2 + Math.cos(a) * width / 2
                y: g.cy + Math.sin(a) * (g.r + 42 * g.u) - height / 2
                text: section.info.label || ""
                color: section.here ? Theme.fg : Theme.fg3
                font { family: Theme.text; pixelSize: 20 * g.u; weight: section.here ? Font.Bold : Font.Medium }
                Behavior on color { ColorAnimation { duration: 300 } }
            }
        }
    }

    // needle: the outer item only sweeps while there's no live number, the inner one shows the reading
    Item {
        id: sweeper
        x: g.cx; y: g.cy
        width: 0; height: 0
        SequentialAnimation {
            running: g.busy && g.visible
            loops: Animation.Infinite
            onRunningChanged: if (!running) back.start()
            RotationAnimator { target: sweeper; to: g.sweep * 0.94; duration: 1150; easing.type: Easing.InOutSine }
            RotationAnimator { target: sweeper; to: 0; duration: 1150; easing.type: Easing.InOutSine }
        }
        RotationAnimator { id: back; target: sweeper; to: 0; duration: 320; easing.type: Easing.OutCubic }
        Item {
            id: needle
            width: 0; height: 0
            rotation: g.startAngle + g.sweep * g.fraction(g.value) + 90
            opacity: g.waiting || g.note ? 0.35 : 1
            Behavior on rotation { RotationAnimator { duration: 520; easing.type: Easing.OutCubic } }
            Rectangle {
                x: -3 * g.u; y: -(g.r - 30 * g.u)
                width: 6 * g.u
                height: g.r - 30 * g.u
                radius: width / 2
                gradient: Gradient {
                    GradientStop { position: 0; color: "white" }
                    GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0.25) }
                }
            }
        }
    }
    Rectangle {
        x: g.cx - width / 2; y: g.cy - height / 2
        width: 22 * g.u; height: width; radius: width / 2
        color: "white"
    }

    Column {
        x: 0
        // an error is wide: below the needle at rest
        y: g.cy + (g.note ? 90 : 44) * g.u
        width: parent.width
        spacing: 2 * g.u
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: g.note || g.number || (g.waiting ? qsTr("Waiting") : "…")
            color: g.waiting && !g.number ? Theme.fg3 : Theme.fg
            font { family: Theme.display; pixelSize: (g.note || (g.waiting && !g.number) ? 30 : 66) * g.u; weight: Font.Bold }
            SequentialAnimation on opacity {
                running: g.busy
                loops: Animation.Infinite
                onRunningChanged: if (!running) parent.opacity = 1
                NumberAnimation { to: 0.45; duration: 640; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 640; easing.type: Easing.InOutSine }
            }
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: g.note || (g.waiting && !g.number) ? "" : g.unit
            color: Theme.fg2
            font { family: Theme.text; pixelSize: 23 * g.u }
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: g.measured
            topPadding: 8 * g.u
            text: g.zone >= 0 ? g.zones[g.zone].label + (g.weakest ? "  ·  " + qsTr("Weakest") : "") : ""
            color: g.zone >= 0 ? g.zones[g.zone].color : Theme.fg
            font { family: Theme.display; pixelSize: 27 * g.u; weight: Font.DemiBold }
        }
    }
}
