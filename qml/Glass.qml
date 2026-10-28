// one piece of liquid glass (shaders/glass.frag) over the live backdrop. kinds:
//   panel - dark, carries text    chip - lighter, on a panel    clear - bright, focus
import QtQuick

ShaderEffect {
    id: g
    property string kind: "panel"
    property real radius: 40
    property real bevel: Math.min(kind === "panel" ? radius * 1.9 : radius * 1.15, Math.min(width, height) * 0.5)
    property real refraction: kind === "panel" ? 110 : 30
    property real frost: kind === "panel" ? 4.6 : kind === "chip" ? 3.6 : 2.6
    property real frostRadius: kind === "panel" ? 70 : 34
    property real tint: kind === "panel" ? 0.075 : kind === "chip" ? 0.12 : 0.80
    property real dim: kind === "panel" ? 0.40 : kind === "chip" ? 0.22 : 0.0
    property real adapt: kind === "panel" ? 0.45 : kind === "chip" ? 0.25 : 0.10
    property real rim: kind === "clear" ? 0.22 : 0.14
    property real rimWidth: 1.6
    property real sat: kind === "chip" ? 0.55 : kind === "panel" ? 1.3 : 1.45
    property real soft: kind === "panel" ? 1.0 : kind === "chip" ? 0.6 : 0.0
    property variant frostTex: win.frostTex
    property color washColor: "transparent"
    property real washAmount: 0
    readonly property vector4d wash: Qt.vector4d(washColor.r, washColor.g, washColor.b, washAmount)

    // from Main.qml
    property variant backdrop: win.backdropTex
    property real backdropOn: win.backdropOn ? 1 : 0
    readonly property real texelX: 1 / Math.max(1, win.width)
    readonly property real texelY: 1 / Math.max(1, win.height)
    readonly property real w: width
    readonly property real h: height

    vertexShader: "qrc:/shaders/glass.vert.qsb"
    fragmentShader: "qrc:/shaders/glass.frag.qsb"
    blending: true
}
