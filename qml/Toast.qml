import QtQuick

// menu invokes the action while the toast is visible
Item {
    id: toast
    readonly property real u: Theme.u
    property string text: ""
    property string action: ""
    property var actionFn: null
    property var commitFn: null
    property bool shown: false
    function finish() {
        var f = commitFn
        commitFn = null; actionFn = null
        if (f) f()
    }
    onShownChanged: {
        if (!shown) finish()
        slideIn.stop(); slideOut.stop()
        ;(shown ? slideIn : slideOut).start()
    }
    // news nobody asked for (an update, a trakt login, a word from the core) waits until someone
    // is watching: the profile is chosen. the newest one, a moment after
    property bool held: false
    property string waiting: ""
    function notify(t) {
        if (held) waiting = t
        else show(t)
    }
    onHeldChanged: if (!held && waiting) release.start()
    Timer {
        id: release
        interval: 1200
        onTriggered: { var t = toast.waiting; toast.waiting = ""; if (t) toast.show(t) }
    }
    function show(t, act, fn, secs, commit) {
        finish()
        text = t; action = act || ""; actionFn = fn || null
        commitFn = commit || null
        shown = true
        timer.interval = (secs || (act ? 6 : 3)) * 1000
        timer.restart()
    }
    function trigger() {
        if (!shown || !actionFn) return false
        var f = actionFn
        commitFn = null; actionFn = null
        shown = false; timer.stop(); f()
        return true
    }
    Timer { id: timer; onTriggered: toast.shown = false }

    // top right just under the bar: the same height and glass as the tab pill. slides in from
    // the edge
    // the spring runs on how far in it is, not on x: a window resize must not fly it across
    // in with a spring, out quickly (an undo shouldn't leave it hanging there)
    property real inness: 0
    SpringAnimation { id: slideIn; target: toast; property: "inness"; to: 1; spring: 3.5; damping: 0.62; epsilon: 0.0005 }
    NumberAnimation { id: slideOut; target: toast; property: "inness"; to: 0; duration: 240; easing.type: Easing.InCubic }
    property real atY: 140 * u
    y: atY
    x: parent.width + 20 * u - inness * (width + Theme.margin + 20 * u)
    visible: inness > 0.001
    width: row.width + 72 * u
    height: 78 * u
    Glass { anchors.fill: parent; kind: "panel"; radius: height / 2 }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 26 * toast.u
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: toast.text
            color: Theme.fg
            font { family: Theme.display; pixelSize: 28 * toast.u; weight: Font.Medium }
        }
        KeyHint {
            visible: toast.action !== ""
            anchors.verticalCenter: parent.verticalCenter
            u: toast.u * 0.9
            labelSize: 28 * toast.u
            key: "MENU"
            label: toast.action
            pad: Remote.inputKind === "pad"
        }
    }
}
