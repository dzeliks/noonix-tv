import QtQuick

// android hdr straight from the decoder: mpv draws nothing over that picture, so the subtitle
// comes here as text, in mpv's own look (38/720 of the height, a 3/720 black edge, 22/720 off
// the bottom, or with its foot just above the seek bar while the controls show)
Item {
    id: root
    property bool covered: false
    visible: Video.colour.decoder === true && Player.subText !== "" && !covered
    readonly property real k: height / 720
    readonly property real edge: 3 * k * 0.8

    Item {
        id: block
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.width * 0.9
        height: face.contentHeight
        y: (Player.subLifted ? root.height * Player.subLiftPos / 100 : root.height - 22 * root.k) - height
        // the edge: black copies around the text
        Repeater {
            model: 16
            Text {
                required property int index
                x: Math.cos(index * Math.PI / 8) * root.edge
                y: Math.sin(index * Math.PI / 8) * root.edge
                width: block.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: face.text
                font: face.font
                color: "black"
            }
        }
        Text {
            id: face
            width: block.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: Player.subText
            color: "white"
            font.pixelSize: Math.round(38 * root.k)
        }
    }
}
