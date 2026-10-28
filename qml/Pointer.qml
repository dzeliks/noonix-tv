import QtQuick

// the mouse: moving over something focuses it (like the arrows would), a click is ok on it.
// inside lists it picks that row in every list around it. only real movement counts, so a
// list scrolling under a resting cursor (qt's synthetic hover) never steals the focus. lists don't
// scroll for the mouse (Input.pointing), so something half out of the window or hidden doesn't
// take it either: the wheel brings it in
MouseArea {
    id: pt
    property bool okKey: true            // a click sends ok; false: just tapped()
    property alias tapPolicy: tap.gesturePolicy   // WithinBounds: a button over cards keeps its clicks
    signal pointed()
    signal tapped()
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    cursorShape: Qt.PointingHandCursor

    function focusLists() {
        // (view, index) for each list we sit in, innermost first
        var chain = [], d = pt.parent
        while (d && d.parent) {
            var v = d.parent.parent
            if (v && d.parent === v.contentItem && v.indexAt !== undefined && v.currentIndex !== undefined) {
                var i = v.indexAt(d.x + d.width / 2, d.y + d.height / 2)
                if (i >= 0) chain.push({ view: v, index: i })
                d = v
            } else {
                d = d.parent
            }
        }
        for (var k = chain.length - 1; k >= 0; --k) chain[k].view.currentIndex = chain[k].index
        if (chain.length) chain[0].view.forceActiveFocus()
    }
    function go() { focusLists(); pt.pointed() }

    function whole() {
        var it = pt.parent, w = pt.Window.window
        if (!it || !w) return true
        for (var d = it; d; d = d.parent)
            if (!d.visible || d.opacity === 0) return false
        var p = it.mapToItem(null, 0, 0)
        return p.x >= -1 && p.y >= -1 && p.x + it.width <= w.width + 1 && p.y + it.height <= w.height + 1
    }

    onPositionChanged: if (Input.pointerLive() && whole()) go()
    // the click is a tap handler's: mouse areas skip presses qt tags as a touchpad's (laptop touchpads,
    // some virtual mice), handlers take every pointer
    TapHandler {
        id: tap
        acceptedButtons: Qt.LeftButton
        onTapped: {
            pt.go()
            if (pt.okKey) Remote.Key("OK"); else pt.tapped()
        }
    }
}
