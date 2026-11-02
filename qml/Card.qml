import QtQuick
import QtQuick.Effects

// one tile in a row: poster (2:3) or landscape (16:9, episodes and continue watching).
// focus = tvos lift: a spring scale, a deeper shadow and the sheen
Item {
    id: card
    property var media: ({})
    property string style: "poster"          // poster | landscape | episode
    property bool focused: false
    // with the mouse in use only the card under it: moving off lets it down
    readonly property bool lifted: focused && (Input.pointing !== true || point.containsMouse)
    readonly property bool wide: style !== "poster"
    readonly property real u: Theme.u
    property real posterW: 214 * u
    readonly property real artW: wide ? 400 * u : posterW
    readonly property real artH: wide ? artW * 9 / 16 : artW * 1.5
    readonly property real progress: media.progress || 0
    readonly property real inset: 16 * u * shrink
    // media.label / media.sublabel override the defaults (season pages)
    readonly property string label: media.label !== undefined ? media.label
        : media.kind === "episode" ? (media.showTitle || "") : (media.title || "")
    readonly property string sublabel: media.sublabel !== undefined ? media.sublabel
        : media.kind === "episode" ? "S" + media.season + " · E" + media.episode + (media.episodeTitle ? "  " + media.episodeTitle : "")
        : ""

    // a removal waiting out its undo time: the cover pulls in, a line round the border drains. only
    // in the rows a removal is for: the same title elsewhere (library, search) isn't leaving
    property bool undoable: false
    readonly property var removal: undoable ? (win.removalsVersion, win.removalOf(media)) : null
    readonly property bool removing: removal !== null
    property real shrink: 0
    property real leaveT: 0              // the row's remove transition runs this
    function syncDrain() {
        drainAnim.stop()
        if (!removal) return
        var rest = Math.max(0, removal.until - Date.now())
        drainAnim.from = rest / removal.total
        drainAnim.duration = Math.max(1, rest)
        drainAnim.start()
    }
    onRemovalChanged: syncDrain()
    onRemovingChanged: shrink = removing ? 1 : 0
    // a reused delegate starts from its own state
    function snapState() {
        shrinkBehavior.enabled = false
        shrink = removing ? 1 : 0
        shrinkBehavior.enabled = true
    }
    onMediaChanged: snapState()
    Component.onCompleted: { snapState(); syncDrain() }
    Behavior on shrink { id: shrinkBehavior; NumberAnimation { duration: 420; easing.type: Easing.InOutCubic } }
    transform: Translate { x: -card.leaveT * 36 * card.u }

    width: artW
    height: artH + (wide ? 92 * u : 0)

    Item {
        id: lift
        opacity: 1 - card.leaveT
        width: card.artW; height: card.artH
        scale: card.lifted ? 1.1 : 1.0
        transformOrigin: Item.Center
        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
        z: 1

        RectangularShadow {
            opacity: 1 - 0.6 * card.shrink
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
            opacity: 1 - 0.45 * card.shrink
            transform: Scale {
                origin.x: art.width / 2; origin.y: art.height / 2
                xScale: 1 - 2 * card.inset / art.width
                yScale: 1 - 2 * card.inset / art.height
            }
        }
        // resume bar inside the artwork, like apple tv
        Rectangle {
            opacity: 1 - card.shrink
            visible: card.progress > 0.01 && card.progress < 0.97 && card.shrink < 1
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
        // the border and the line draining inside it, counter-clockwise from the top
        Rectangle {
            anchors.fill: parent
            radius: art.radius
            color: "transparent"
            border { width: 2 * card.u; color: Qt.rgba(1, 1, 1, 0.22) }
            opacity: card.shrink
            visible: opacity > 0
        }
        ShaderEffect {
            id: ring
            anchors.fill: parent
            opacity: card.shrink
            visible: opacity > 0
            property size size: Qt.size(width, height)
            property real inset: 8 * card.u
            property real radius: Math.max(4, art.radius - inset)
            property real stroke: 4 * card.u
            property real drain: 1
            fragmentShader: "qrc:/shaders/ring.frag.qsb"
            // on the render thread: six seconds of it must not wake the scene
            UniformAnimator { id: drainAnim; target: ring; uniform: "drain"; to: 0 }
        }
        Column {
            anchors.centerIn: parent
            spacing: 10 * card.u
            width: parent.width - 2 * card.inset - 24 * card.u
            opacity: Math.max(0, (card.shrink - 0.55) / 0.45)
            visible: opacity > 0
            Symbol { anchors.horizontalCenter: parent.horizontalCenter; name: "undo"; width: 38 * card.u; height: width; color: "white"; weight: 2.2 }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: Input.pointing ? (Qt.platform.os === "android" ? qsTr("Tap to undo") : qsTr("Click to undo")) : qsTr("Press OK to undo")
                color: "white"
                font { family: Theme.display; pixelSize: 22 * card.u; weight: Font.DemiBold }
            }
        }
    }

    Column {
        visible: card.wide
        opacity: 1 - card.leaveT
        anchors { top: lift.bottom; topMargin: (card.lifted ? 30 : 16) * card.u; left: parent.left; right: parent.right }
        Behavior on anchors.topMargin { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        spacing: 4 * card.u
        Text {
            width: parent.width
            text: card.label
            color: card.lifted ? Theme.fg : Theme.fg2
            opacity: 1 - 0.5 * card.shrink
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
        id: point
        menuOnHold: true
        onContainsMouseChanged: {
            if (containsMouse) win.pointedCard = point
            else if (win.pointedCard === point) win.pointedCard = null
        }
        Component.onDestruction: if (win.pointedCard === point) win.pointedCard = null
    }
}
