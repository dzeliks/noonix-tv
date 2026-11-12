import QtQuick

// a backdrop for glass made from one item that fills the window: a quarter-size copy and a small
// blurred one (Glass' backdrop and frostTex). for glass inside the scene: the scene's own copy
// would carry the glass too and blur it back into itself
Item {
    id: gs
    property Item sourceItem
    property bool hideSource: false
    property bool live: true
    readonly property alias tex: copy
    readonly property alias frost: frostV

    ShaderEffectSource {
        id: copy
        sourceItem: gs.sourceItem
        hideSource: gs.hideSource
        live: gs.live
        smooth: true
        mipmap: true
        textureSize: Theme.copySize(win.width, win.height)
        visible: false
    }
    ShaderEffect {
        id: blurH
        width: 240; height: 135; visible: false
        property variant source: copy
        property vector2d dir: Qt.vector2d(1 / 240, 0)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: blurHTex; sourceItem: blurH; hideSource: true; live: gs.live; smooth: true; textureSize: Theme.frostSize; visible: false }
    ShaderEffect {
        id: blurV
        width: 240; height: 135; visible: false
        property variant source: blurHTex
        property vector2d dir: Qt.vector2d(0, 1 / 135)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: frostV; sourceItem: blurV; hideSource: true; live: gs.live; smooth: true; textureSize: Theme.frostSize; visible: false }
}
