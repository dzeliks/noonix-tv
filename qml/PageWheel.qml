import QtQuick

// the wheel on a page or a list: pixels, not steps. it glides after its goal and notches in a quick
// run throw it further and further. a touchpad follows the fingers: it has scroll phases, a wheel has
// none (on wayland both send pixels, a wheel's are only 15 a notch). the focus isn't touched: that's
// the mouse's (Pointer). across: sideways
FrameAnimation {
    required property Flickable view
    property bool across: false
    property real goal: 0
    property real rush: 1
    property real dir: 0
    property double last: 0

    function at() { return across ? view.contentX : view.contentY }
    function put(p) { if (across) view.contentX = p; else view.contentY = p; Theme.wheelAt = Date.now() }
    function top() { return across ? view.originX - view.leftMargin : view.originY - view.topMargin }
    function end() {
        return Math.max(top(), across ? view.originX + view.contentWidth + view.rightMargin - view.width
                                      : view.originY + view.contentHeight + view.bottomMargin - view.height)
    }
    function clamp(p) { return Math.max(top(), Math.min(end(), p)) }
    onTriggered: {
        var p = at() + (goal - at()) * (1 - Math.exp(-Math.min(frameTime, 0.05) / 0.08))
        var done = Math.abs(goal - p) < 0.5
        put(done ? goal : p)
        if (done) stop()
    }
    function scroll(w) {
        Input.setPointing(true)
        if (w.phase !== Qt.NoScrollPhase) {
            stop()
            put(clamp(at() - (across ? w.pixelDelta.x || w.pixelDelta.y : w.pixelDelta.y)))
            return
        }
        // sideways is a tilt, or shift on the wheel
        var notches = (across ? w.angleDelta.x || w.angleDelta.y : w.angleDelta.y) / 120
        var now = Date.now(), d = notches > 0 ? 1 : -1
        // the other way stops the throw where it is
        if (!running || d !== dir) goal = at()
        rush = now - last < 160 && d === dir ? Math.min(24, rush + Math.abs(notches)) : 1
        last = now
        dir = d
        goal = clamp(goal - notches * 240 * Theme.u * rush)
        start()
    }
}
