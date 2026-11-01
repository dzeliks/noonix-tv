import QtQuick

// the wheel on a page: pixels, not steps. notches in a quick run go further and further, a
// touchpad follows the fingers
NumberAnimation {
    id: pw
    required property Flickable view
    property real goal: 0
    property real rush: 1
    property double last: 0
    target: view
    property: "contentY"
    duration: 260
    easing.type: Easing.OutCubic

    function top() { return view.originY }
    function end() { return Math.max(top(), view.originY + view.contentHeight - view.height) }
    function clamp(y) { return Math.max(top(), Math.min(end(), y)) }
    function scroll(w) {
        if (!running) goal = view.contentY
        if (w.pixelDelta.y !== 0) {
            stop()
            view.contentY = clamp(view.contentY - w.pixelDelta.y)
            return
        }
        var notches = w.angleDelta.y / 120, now = Date.now()
        rush = now - last < 140 ? Math.min(14, rush + 0.6 * Math.abs(notches)) : 1
        last = now
        goal = clamp(goal - notches * 130 * Theme.u * rush)
        stop()
        from = view.contentY
        to = goal
        start()
    }
}
