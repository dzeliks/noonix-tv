import QtQuick
import QtQuick.Effects

// a tvos button: glass at rest, white and lifted when focused
Item {
    id: b
    property string text: ""
    property string icon: ""
    property bool focused: activeFocus
    property bool primary: false
    // a finger: the main button is always the white one, the rest light while pressed (no remote focus look)
    readonly property bool touch: Theme.touch
    readonly property bool lit: touch ? primary || gbPt.down : focused
    property bool glass: false           // real liquid glass at rest (over video), flat fill otherwise
    property GlassSource source: null    // glass inside the scene: what it refracts (never the scene itself)
    property real iconSize: 34 * u
    property real u: Theme.u             // smaller where room is short
    signal clicked()
    signal pointed()
    property bool pointerFocus: true     // the mouse focuses it; false: the owner keeps the focus (pointed())
    implicitHeight: 76 * u
    implicitWidth: (text ? label.implicitWidth + 64 * u : 76 * u) + (icon && text ? 44 * u : 0)
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    Item {
        id: body
        anchors.fill: parent
        // a finger down sinks it (Pointer) instead
        scale: b.focused && !b.touch && !(Theme.android && gbPt.down) ? 1.08 : 1
        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
        RectangularShadow {
            anchors.fill: bg
            radius: bg.radius
            offset.y: 14 * b.u
            blur: 36 * b.u
            color: Qt.rgba(0, 0, 0, 0.5)
            opacity: b.lit ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
        Glass {
            anchors.fill: parent
            visible: b.glass
            kind: "chip"
            tint: b.primary ? 0.2 : 0.12
            backdrop: b.source ? b.source.tex : win.glassTex(b)
            frostTex: b.source ? b.source.frost : win.glassFrost(b)
            backdropOn: b.source || win.backdropOn ? 1 : win.videoThrough ? 0.25 : 0
            radius: height / 2
            opacity: b.lit ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }
        Rectangle {
            id: bg
            anchors.fill: parent
            radius: height / 2
            color: b.lit ? "white" : b.glass ? "transparent" : Qt.rgba(1, 1, 1, b.primary ? 0.24 : 0.14)
            Behavior on color { ColorAnimation { duration: 140 } }
        }
        Row {
            anchors.centerIn: parent
            spacing: 14 * b.u
            Symbol {
                visible: b.icon !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: b.iconSize; height: width
                name: b.icon
                weight: 2.2
                color: b.lit ? Theme.focusFg : Theme.fg
            }
            Text {
                id: label
                visible: b.text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: b.text
                color: b.lit ? Theme.focusFg : Theme.fg
                font { family: Theme.display; pixelSize: 27 * b.u; weight: Font.DemiBold }
            }
        }
    }

    Pointer {
        id: gbPt
        okKey: false
        onPointed: { if (b.pointerFocus) b.forceActiveFocus(); b.pointed() }
        onTapped: b.clicked()
    }
}
