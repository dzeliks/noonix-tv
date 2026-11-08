import QtQuick

// the mouse: what it's over has the focus (like the arrows would), a click is ok on it. inside lists
// it picks that row in every list around it, and no list moves for it: a card half out of the window
// takes the focus where it is. only real movement counts, or the wheel moving the list under the
// mouse: anything else sliding under a resting cursor (qt's synthetic hover) never steals the focus
MouseArea {
    id: pt
    property bool okKey: true            // a click sends ok; false: just tapped()
    property bool takesFocus: true       // false: pointing at it leaves the focus where it is
    property bool menuOnHold: false      // touch: holding is the right click (a card's menu)
    property bool holdMenuKey: true      // false: a hold is held() instead of the menu key
    property bool longDone: false
    readonly property bool down: tap.pressed
    signal pointed()
    signal tapped()
    signal held()
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
        for (var k = chain.length - 1; k >= 0; --k) {
            // a list scrolls to its current item at once: back before anything draws
            v = chain[k].view
            var x = v.contentX, y = v.contentY
            v.currentIndex = chain[k].index
            v.contentX = x
            v.contentY = y
        }
        if (chain.length) chain[0].view.forceActiveFocus()
    }
    function go() { if (takesFocus) focusLists(); pt.pointed() }

    // not what's hidden (rows behind the hero, cards faded out at a row's edge)
    function shown() {
        for (var d = pt.parent; d; d = d.parent)
            if (!d.visible || d.opacity === 0) return false
        return true
    }

    onPositionChanged: if (Input.pointerLive() && shown()) go()
    onContainsMouseChanged: if (containsMouse && Input.pointing && Date.now() - Theme.wheelAt < 150 && shown()) go()
    // the click is a tap handler's: mouse areas skip presses qt tags as a touchpad's (laptop touchpads,
    // some virtual mice), handlers take every pointer
    TapHandler {
        id: tap
        acceptedButtons: Qt.LeftButton
        onPressedChanged: {
            if (pressed) {
                pt.longDone = false
                // a finger lights what it's on while it's down (a mouse already did by pointing), a
                // moment later: a swipe starting on it never lights it
                sinkHold.stop(); sinkBack.stop()
                if (Theme.android) lightLater.restart(); else sinkIn.restart()
                if (hold.enabled && Theme.android) sinkHold.restart()
            } else if (!pt.longDone) {
                lightLater.stop()
                sinkIn.stop(); sinkHold.stop(); sinkBack.restart()
            }
        }
        onTapped: {
            if (pt.longDone) { pt.longDone = false; return }
            pt.go()
            if (pt.okKey) Remote.pointerKey("OK"); else pt.tapped()
        }
    }
    Timer {
        id: lightLater
        interval: 90
        onTriggered: {
            if (!tap.pressed) return
            sinkIn.restart()
            if (pt.shown()) pt.go()
        }
    }
    TapHandler {
        id: hold
        acceptedDevices: PointerDevice.TouchScreen
        enabled: pt.menuOnHold
        onLongPressed: {
            pt.longDone = true
            sinkIn.stop(); sinkHold.stop(); sinkBack.restart()
            pt.go()
            if (pt.holdMenuKey) Remote.pointerKey("MENU"); else pt.held()
        }
    }

    // a press sinks what it's on a little, holding (a card's menu coming) a little more. a few px
    // at most, so a wide row barely moves
    property bool sinks: true
    property real depth: 0
    readonly property real sinkStep: Math.min(0.03, 9 * Theme.u / Math.max(1, width, height))
    NumberAnimation { id: sinkIn; target: pt; property: "depth"; to: 1; duration: 110; easing.type: Easing.OutQuad }
    SequentialAnimation {
        id: sinkHold
        PauseAnimation { duration: 140 }
        NumberAnimation { target: pt; property: "depth"; to: 2.2; duration: Math.max(200, hold.longPressThreshold * 1000 - 140); easing.type: Easing.InOutQuad }
    }
    SpringAnimation { id: sinkBack; target: pt; property: "depth"; to: 0; spring: 5; damping: 0.38; epsilon: 0.005 }
    Scale {
        id: press
        origin.x: pt.width / 2 + pt.x; origin.y: pt.height / 2 + pt.y
        xScale: 1 - pt.depth * pt.sinkStep; yScale: xScale
    }
    Component.onCompleted: {
        if (!sinks || !parent) return
        var t = []
        for (var i = 0; i < parent.transform.length; ++i) t.push(parent.transform[i])
        t.push(press)
        parent.transform = t
    }
}
