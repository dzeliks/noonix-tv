import QtQuick

// clearlogo in a fixed box, centred; the title text stands in only when there is no logo
// (none at all, or it failed), never while one is still loading
Item {
    id: box
    property url source
    property string title: ""
    property real titleSize: 64 * Theme.u
    property int align: Qt.AlignHCenter       // horizontal placement inside the box
    property real bottomPad: 0                // empty room at the bottom of the box
    property bool bottomAligned: false        // sits on the box's bottom edge (the player: on the line under it)
    readonly property bool ready: img.status === Image.Ready
    property bool loading: false              // the details that carry the logo aren't here yet
    readonly property bool noLogo: !loading && (String(source) === "" || img.status === Image.Error)

    Image {
        id: img
        anchors.fill: parent
        anchors.bottomMargin: box.bottomPad
        source: box.source
        fillMode: Image.PreserveAspectFit
        horizontalAlignment: box.align === Qt.AlignLeft ? Image.AlignLeft : Image.AlignHCenter
        verticalAlignment: box.bottomAligned ? Image.AlignBottom : Image.AlignVCenter
        asynchronous: true
        sourceSize.height: Math.ceil(height * Theme.dpr)
        opacity: box.ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 260 } }
    }
    Text {
        anchors.fill: parent
        anchors.bottomMargin: box.bottomPad
        visible: box.noLogo
        text: box.title
        color: Theme.fg
        font { family: Theme.display; pixelSize: box.titleSize; weight: Font.Bold }
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        fontSizeMode: Text.Fit
        minimumPixelSize: box.titleSize * 0.6
        horizontalAlignment: box.align === Qt.AlignLeft ? Text.AlignLeft : Text.AlignHCenter
        verticalAlignment: box.bottomAligned ? Text.AlignBottom : Text.AlignVCenter
    }
}
