import QtQuick
import QtQuick.Effects

// a round glass button for the pointer: a row's page arrows, a page's back. the same glass, lift and
// white as the other glass buttons (GlassButton)
Item {
    id: rb
    property string icon: "chevronleft"
    property real size: 64                // across, on the 1920 grid
    // glass inside the scene: what it refracts (the page's art). the window's copy carries the
    // button itself and showed it blurred under it
    property GlassSource source: null
    signal clicked()
    readonly property bool hovered: Theme.hover(pt)
    property bool lit: false              // white without the mouse too (back armed by a key)
    readonly property bool white: hovered || lit
    readonly property real u: Theme.u
    width: size * u; height: width
    scale: white && !(Theme.android && pt.down) ? 1.08 : 1
    Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
    RectangularShadow {
        anchors.fill: face
        radius: face.radius
        offset.y: 14 * rb.size / 76 * rb.u
        blur: 36 * rb.size / 76 * rb.u
        color: Qt.rgba(0, 0, 0, 0.5)
        opacity: rb.white ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }
    Glass {
        anchors.fill: parent
        kind: "chip"
        tint: 0.12
        backdrop: rb.source ? rb.source.tex : win.glassTex(rb)
        frostTex: rb.source ? rb.source.frost : win.glassFrost(rb)
        backdropOn: rb.source || win.backdropOn ? 1 : win.videoThrough ? 0.25 : 0
        radius: width / 2
        opacity: rb.white ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }
    }
    Rectangle {
        id: face
        anchors.fill: parent
        radius: width / 2
        color: rb.white ? "white" : "transparent"
        Behavior on color { ColorAnimation { duration: 140 } }
    }
    Symbol {
        anchors.centerIn: parent
        // chevrons: half a unit toward the point, the arms read heavier than the point (user's pick)
        anchors.horizontalCenterOffset: (rb.icon === "chevronleft" ? -0.5 : rb.icon === "chevronright" ? 0.5 : 0) * width / 24
        width: 34 * rb.size / 64 * rb.u; height: width
        name: rb.icon
        weight: 2.4
        color: rb.white ? Theme.focusFg : Theme.fg
    }
    // a pointer like a card's: the row around it takes the focus, a click is the button's
    Pointer { id: pt; okKey: false; onTapped: rb.clicked() }
}
