import QtQuick

// the pointer's way along a row of cards: page arrows at its ends while the mouse is over it (gone
// with the first key, so a remote or a pad never sees them). a page is the cards in view; the focus
// lands on the new page's rest slot, where the keys would have it, so they go on without a jump
Item {
    id: ra
    required property ListView view
    property int restSlot: 1
    property real cardW: 0
    property real artH: 0
    readonly property real u: Theme.u
    readonly property real step: cardW + view.spacing
    readonly property int page: Math.max(1, Math.floor((view.width - Theme.margin - cardW) / step) + 1)
    readonly property real startX: view.originX - view.leftMargin
    readonly property real endX: Math.max(startX, view.originX + view.contentWidth + view.rightMargin - view.width)
    // the arrows sit over the list and take its hover: they keep themselves up
    readonly property bool shown: (hover.hovered || back.hovered || fwd.hovered) && Input.pointing === true && view.count > 0
    x: view.x; y: view.y
    width: view.width; height: view.height

    // on the list itself: a handler on this layer above the cards would take their hover
    HoverHandler { id: hover; parent: ra.view }

    function go(dir) {
        var first = Math.round((view.contentX - startX) / step)
        var last = Math.round((endX - startX) / step)
        var f = Math.max(0, Math.min(last, first + dir * page))
        slide.to = Math.max(startX, Math.min(endX, startX + f * step))
        slide.index = Math.min(view.count - 1, f + restSlot)
        slide.restart()
        view.forceActiveFocus()
    }
    // the focus moves once the row is there: a current card out of view would scroll it on its own
    NumberAnimation {
        id: slide
        property int index: 0
        target: ra.view; property: "contentX"; duration: 380; easing.type: Easing.InOutQuad
        onFinished: ra.view.currentIndex = index
    }

    RoundButton {
        id: back
        icon: "chevronleft"
        x: (Theme.margin - width) / 2
        y: ra.artH / 2 - height / 2
        opacity: ra.shown && ra.view.contentX > ra.startX + 1 ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        onClicked: ra.go(-1)
    }
    RoundButton {
        id: fwd
        icon: "chevronright"
        x: ra.width - Theme.margin / 2 - width / 2
        y: ra.artH / 2 - height / 2
        opacity: ra.shown && ra.view.contentX < ra.endX - 1 ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        onClicked: ra.go(1)
    }
}
