import QtQuick
import QtQuick.Effects

// one tile in a row: poster (2:3) or landscape (16:9, episodes and continue watching).
// focus = tvos lift: a spring scale, a deeper shadow and the sheen
Item {
    id: card
    property var media: ({})
    property string style: "poster"          // poster | landscape | episode
    property bool focused: false
    readonly property bool lifted: focused && (Input.pointing !== true || Theme.pointedCards > 0)
    readonly property bool wide: style !== "poster"
    readonly property real u: Theme.u
    property real posterW: 214 * u
    readonly property real artW: wide ? 400 * u : posterW
    readonly property real artH: wide ? artW * 9 / 16 : artW * 1.5
    readonly property real progress: media.progress || 0
    // media.label / media.sublabel override the defaults (season pages)
    readonly property string label: media.label !== undefined ? media.label
        : media.kind === "episode" ? (media.showTitle || "") : (media.title || "")
    readonly property string sublabel: media.sublabel !== undefined ? media.sublabel
        : media.kind === "episode" ? "S" + media.season + " · E" + media.episode + (media.episodeTitle ? "  " + media.episodeTitle : "")
        : ""

    width: artW
    height: artH + (wide ? 92 * u : 0)

    Item {
        id: lift
        width: card.artW; height: card.artH
        scale: card.lifted ? 1.1 : 1.0
        transformOrigin: Item.Center
        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
        z: 1

        RectangularShadow {
            anchors.fill: art
            radius: art.radius
            offset.y: (card.lifted ? 26 : 8) * card.u
            blur: (card.lifted ? 60 : 24) * card.u
            color: Qt.rgba(0, 0, 0, card.lifted ? 0.6 : 0.35)
            Behavior on offset.y { NumberAnimation { duration: 200 } }
        }
        Art {
            id: art
            anchors.fill: parent
            source: card.wide ? (card.media.still || card.media.backdrop || "") : (card.media.poster || "")
            placeholder: card.label
        }
        // resume bar inside the artwork, like apple tv
        Rectangle {
            visible: card.progress > 0.01 && card.progress < 0.97
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 16 * card.u }
            height: 7 * card.u
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.28)
            Rectangle {
                width: parent.width * card.progress
                height: parent.height
                radius: parent.radius
                color: "white"
            }
        }
    }

    Column {
        visible: card.wide
        anchors { top: lift.bottom; topMargin: (card.lifted ? 30 : 16) * card.u; left: parent.left; right: parent.right }
        Behavior on anchors.topMargin { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        spacing: 4 * card.u
        Text {
            width: parent.width
            text: card.label
            color: card.lifted ? Theme.fg : Theme.fg2
            font { family: Theme.display; pixelSize: 25 * card.u; weight: Font.DemiBold }
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: card.sublabel
            visible: text !== ""
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 21 * card.u }
            elide: Text.ElideRight
        }
    }

    Pointer {
        onContainsMouseChanged: Theme.pointedCards = Math.max(0, Theme.pointedCards + (containsMouse ? 1 : -1))
        Component.onDestruction: if (containsMouse) Theme.pointedCards = Math.max(0, Theme.pointedCards - 1)
    }
}
