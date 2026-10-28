import QtQuick

// a soft shade behind text over artwork: no edges, just enough to keep it readable
ShaderEffect {
    property real strength: 0.5
    blending: true
    fragmentShader: "qrc:/shaders/scrim.frag.qsb"
}
