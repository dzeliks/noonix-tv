import QtQuick

// rounded, cropped artwork; a quiet placeholder until the image is in
Item {
    id: art
    property url source
    property real radius: 18 * Theme.u
    property real shade: 0
    property real inset: 0                   // drawn this far inside, the corners stay the same
    property string placeholder: ""          // title shown while there's no image
    readonly property bool ready: img.status === Image.Ready

    // the grey box (and its title) only when the picture takes a moment: a cached one is in
    // before this, and a card skips laying out a title nobody sees
    property bool slow: false
    onSourceChanged: slow = false   // a reused card starts over
    Timer { interval: 120; running: !art.ready && !art.slow; onTriggered: art.slow = true }
    Rectangle {
        anchors.fill: parent
        anchors.margins: art.inset
        radius: art.radius
        color: Qt.rgba(1, 1, 1, 0.08)
        visible: !art.ready
    }
    Loader {
        anchors.fill: parent
        active: art.slow && !art.ready && art.placeholder !== ""
        sourceComponent: Text {
            anchors.fill: parent
            anchors.margins: 16 * Theme.u
            text: art.placeholder
            color: Theme.fg3
            font.family: Theme.display
            font.pixelSize: 22 * Theme.u
            font.weight: Font.Medium
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    Image {
        id: img
        source: art.source
        visible: false
        asynchronous: true
        cache: true
        // decode at the size it is shown, never the full original
        sourceSize.width: Math.ceil(art.width)
        sourceSize.height: Math.ceil(art.height)
        fillMode: Image.PreserveAspectCrop
    }
    ShaderEffect {
        anchors.fill: parent
        visible: art.ready
        opacity: art.ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
        property variant source: img
        property real w: width
        property real h: height
        property real radius: art.radius
        readonly property real imgAr: img.implicitHeight > 0 ? img.implicitWidth / img.implicitHeight : 1
        readonly property real boxAr: height > 2 * art.inset ? (width - 2 * art.inset) / (height - 2 * art.inset) : 1
        property real sx: imgAr > boxAr ? boxAr / imgAr : 1
        property real sy: imgAr > boxAr ? 1 : imgAr / boxAr
        property real shade: art.shade
        property real inset: art.inset
        fragmentShader: "qrc:/shaders/art.frag.qsb"
    }
}
