import QtQuick

// a list takes the wheel while the mouse is over it. anything on top of it (a sheet's shield) takes
// the hover, so the wheel never reaches a covered list
Item {
    id: lw
    required property Flickable view
    property bool across: false
    property bool cards: false           // the selection only shows under the mouse
    function scroll(w) { glide.scroll(w) }

    PageWheel { id: glide; view: lw.view; across: lw.across }
    // on the list itself: a handler above the cards would take their hover
    HoverHandler {
        parent: lw.view
        onHoveredChanged: lw.take(hovered)
    }
    function take(on) {
        if (lw.across) Theme.wheelRow = on ? lw : Theme.wheelRow === lw ? null : Theme.wheelRow
        else Theme.wheelList = on ? lw : Theme.wheelList === lw ? null : Theme.wheelList
    }
    Component.onDestruction: take(false)

    // a key after the mouse: the selection if it's still in view, else the first one in view. the
    // key that does this does nothing else when no selection was showing
    function seen(it) {
        if (!it) return false
        var mid = lw.across ? it.x + it.width / 2 : it.y + it.height / 2
        var from = lw.across ? view.contentX + view.leftMargin : view.contentY
        return mid >= from && mid <= (lw.across ? view.contentX + view.width : view.contentY + view.height)
    }
    function pick() {
        glide.stop()
        if (!view.visible || view.count === 0) return
        var had = seen(view.currentItem)
        var it = view.currentItem
        for (var p = 0; !had && p < (lw.across ? view.width : view.height); p += 20 * Theme.u) {
            var i = lw.across ? view.indexAt(view.contentX + view.leftMargin + p, view.contentY + view.height / 2)
                              : view.indexAt(it ? it.x + it.width / 2 : view.width / 2, view.contentY + p)
            if (i >= 0 && seen(view.itemAtIndex(i))) { view.currentIndex = i; break }
        }
        if (view.activeFocus && (!had || lw.cards && !win.pointedCard)) Input.holdKey()
    }
    Connections {
        target: Input
        function onPointingChanged() { if (!Input.pointing) lw.pick() }
    }
}
