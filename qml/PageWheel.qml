import QtQuick

// the wheel on a page: pixels, not steps. the page glides after its goal and notches in a quick run
// throw it further and further. a touchpad follows the fingers: it has scroll phases, a wheel has
// none (on wayland both send pixels, a wheel's are only 15 a notch)
FrameAnimation {
    required property Flickable view
    property real goal: 0
    property real rush: 1
    property real dir: 0
    property double last: 0

    function top() { return view.originY }
    function end() { return Math.max(top(), view.originY + view.contentHeight - view.height) }
    function clamp(y) { return Math.max(top(), Math.min(end(), y)) }
    onTriggered: {
        var y = view.contentY + (goal - view.contentY) * (1 - Math.exp(-Math.min(frameTime, 0.05) / 0.08))
        var done = Math.abs(goal - y) < 0.5
        view.contentY = done ? goal : y
        if (done) stop()
    }
    function scroll(w) {
        if (w.phase !== Qt.NoScrollPhase) {
            stop()
            view.contentY = clamp(view.contentY - w.pixelDelta.y)
            return
        }
        var notches = w.angleDelta.y / 120, now = Date.now(), d = notches > 0 ? 1 : -1
        // the other way stops the throw where the page is
        if (!running || d !== dir) goal = view.contentY
        rush = now - last < 160 && d === dir ? Math.min(24, rush + Math.abs(notches)) : 1
        last = now
        dir = d
        goal = clamp(goal - notches * 240 * Theme.u * rush)
        start()
    }
}
