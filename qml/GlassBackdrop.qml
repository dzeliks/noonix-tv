// the frosted backdrop glass reads when it sits on a kwin window (the tv wallpaper):
// a half-size copy and a 1/16 copy blurred twice, exposed as backdropTex / frostTex /
// backdropOn on the root window
import QtQuick

Item {
    id: gb
    property string uuid: ""
    readonly property bool ready: stream.ready
    readonly property alias tex: bdTex
    readonly property alias frostTex: frostV

    Item {
        id: backdrop
        width: gb.width; height: gb.height
        Rectangle { anchors.fill: parent; color: "black" }
        // kde screencast modules: missing elsewhere (and in the appimage), then the
        // loader just fails and the glass shows the gradient under it
        Loader {
            id: stream
            anchors.fill: parent
            source: "Stream.qml"
            readonly property bool ready: status === Loader.Ready && !!item && item.ready
            onLoaded: item.uuid = Qt.binding(function () { return gb.uuid })
        }
    }
    ShaderEffectSource {
        id: bdTex
        sourceItem: backdrop
        hideSource: true
        live: true
        mipmap: true
        smooth: true
        textureSize: Qt.size(Math.max(1, Math.round(gb.width / 2)), Math.max(1, Math.round(gb.height / 2)))
        visible: false
    }
    ShaderEffect {
        id: blurH
        width: 240; height: 135; visible: false
        property variant source: bdTex
        property vector2d dir: Qt.vector2d(1 / 240, 0)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: blurHTex; sourceItem: blurH; hideSource: true; live: true; smooth: true; visible: false }
    ShaderEffect {
        id: blurV
        width: 240; height: 135; visible: false
        property variant source: blurHTex
        property vector2d dir: Qt.vector2d(0, 1 / 135)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: frostV; sourceItem: blurV; hideSource: true; live: true; smooth: true; visible: false }
}
