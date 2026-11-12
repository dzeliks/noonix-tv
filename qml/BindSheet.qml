import QtQuick
import "Pads.js" as Pads

// one action's buttons: three slots, ok on one waits for the press that fills it
FocusScope {
    id: bs
    readonly property real u: Theme.u
    property string side: "pad"          // pad | keys
    property string action: ""
    property string title: ""
    property var custom: ({})            // settings' app.controls
    property var positions: ({})
    property int slot: 0
    property int zone: 0                 // 0 slots, 1 the buttons under them
    property int waiting: -1
    property int choice: 0
    signal saved(var custom)
    signal closed()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    readonly property var bound: (Input.bindings[side] || {})[action] || []
    function nameOf(x) { return side === "pad" ? Pads.text(Input.padKind, x, positions) : Pads.keyText(x) }
    function open(o) {
        side = o.side; action = o.action; title = o.title; custom = o.custom || {}; positions = o.positions || {}
        slot = 0; zone = 0; waiting = -1; choice = 0
        opacity = 1
        forceActiveFocus()
    }
    function close() { stopWaiting(); opacity = 0; closed() }
    function stopWaiting() {
        if (waiting >= 0) Input.capture("")
        waiting = -1
        timeout.stop()
    }
    function listen(i) {
        stopWaiting()
        waiting = i
        // the ok that started it must not be taken as the answer: listen from the next event on
        Qt.callLater(function () { if (bs.waiting >= 0) Input.capture(bs.side === "pad" ? "pad" : "key") })
        timeout.restart()
    }
    function store(list) {
        var c = JSON.parse(JSON.stringify(custom))
        c[side] = c[side] || {}
        c[side][action] = list
        custom = c
        Input.setBindings(c)
        saved(c)
    }
    function clearSlot() {
        var l = bound.slice()
        if (slot >= l.length) return
        // the last one can't go: an action nobody can reach would lock you out
        if (l.length === 1 && (action === "OK" || action === "BACK")) { toast.show(qsTr("Select and Back always keep one")); return }
        l.splice(slot, 1)
        store(l)
    }
    Timer { id: timeout; interval: 8000; onTriggered: bs.stopWaiting() }
    Connections {
        target: Input
        function onCaptured(what, name) {
            if (bs.waiting < 0) return
            var i = bs.waiting
            bs.waiting = -1
            timeout.stop()
            if (!name) return
            // one button, one action: it leaves whatever had it before
            var c = JSON.parse(JSON.stringify(bs.custom)), now = Input.bindings[bs.side] || {}
            c[bs.side] = c[bs.side] || {}
            for (var a in now) {
                if (a === bs.action) continue
                var l = now[a] || []
                if (l.indexOf(name) >= 0) c[bs.side][a] = l.filter(function (x) { return x !== name })
            }
            var mine = bs.bound.filter(function (x) { return x !== name })
            mine.splice(Math.min(i, mine.length), i < bs.bound.length ? 1 : 0, name)
            bs.custom = c
            bs.store(mine.slice(0, 3))
        }
    }

    Keys.onPressed: function (e) {
        if (bs.waiting >= 0) { e.accepted = true; if (e.key === Qt.Key_Escape) bs.stopWaiting(); return }
        var n = bs.bound.length
        switch (e.key) {
        case Qt.Key_Left: if (zone === 0) slot = Math.max(0, slot - 1); else choice = Math.max(0, choice - 1); break
        case Qt.Key_Right: if (zone === 0) slot = Math.min(2, slot + 1); else choice = Math.min(1, choice + 1); break
        case Qt.Key_Up: zone = 0; break
        case Qt.Key_Down: zone = 1; break
        case Qt.Key_Return: case Qt.Key_Enter:
            if (zone === 0) listen(slot)
            else if (choice === 0) close()
            else clearSlot()
            break
        case Qt.Key_Escape: case Qt.Key_Back: close(); break
        default: return
        }
        e.accepted = true
    }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: bs.close() }

    Item {
        anchors.centerIn: parent
        width: 1040 * bs.u
        height: body.height + 2 * 52 * bs.u
        Resize on height {}
        scale: bs.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 52 * bs.u }
        Column {
            id: body
            x: 56 * bs.u; y: 52 * bs.u
            width: parent.width - 112 * bs.u
            spacing: 14 * bs.u
            Text {
                text: bs.title
                color: Theme.fg
                font { family: Theme.display; pixelSize: 40 * bs.u; weight: Font.Bold }
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                bottomPadding: 18 * bs.u
                text: bs.waiting >= 0 ? (bs.side === "pad" ? qsTr("Press a button on the controller") : qsTr("Press a key, Esc leaves it as it is"))
                                      : qsTr("Up to three for this action")
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 24 * bs.u }
            }
            Row {
                spacing: 20 * bs.u
                Repeater {
                    model: 3
                    Rectangle {
                        id: cell
                        required property int index
                        readonly property bool foc: Theme.lit(bs.activeFocus && bs.zone === 0 && bs.slot === index, cellPt)
                        readonly property bool wait: bs.waiting === index
                        readonly property string name: (bs.bound[index] ? bs.nameOf(bs.bound[index]) : "") || ""
                        width: (body.width - 40 * bs.u) / 3
                        height: 150 * bs.u
                        radius: 30 * bs.u
                        color: foc && !wait ? "white" : Qt.rgba(1, 1, 1, wait ? 0.16 : 0.08)
                        border.width: wait ? 3 * bs.u : 0
                        border.color: "white"
                        scale: foc ? 1.04 : 1
                        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
                        Behavior on color { ColorAnimation { duration: 140 } }
                        // waiting: the frame breathes
                        SequentialAnimation on opacity {
                            running: cell.wait
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) cell.opacity = 1
                            NumberAnimation { to: 0.55; duration: 620; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 620; easing.type: Easing.InOutSine }
                        }
                        Column {
                            anchors.centerIn: parent
                            width: parent.width - 24 * bs.u
                            spacing: 6 * bs.u
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                text: cell.wait ? "…" : cell.name || "–"
                                color: cell.foc && !cell.wait ? Theme.focusFg : cell.name ? Theme.fg : Theme.fg3
                                font { family: Theme.display; pixelSize: 32 * bs.u; weight: Font.DemiBold }
                            }
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: cell.wait ? qsTr("Waiting…") : qsTr("Slot %1").arg(cell.index + 1)
                                color: cell.foc && !cell.wait ? Qt.rgba(0.1, 0.1, 0.12, 0.6) : Theme.fg3
                                font { family: Theme.text; pixelSize: 20 * bs.u }
                            }
                        }
                        Pointer {
                            id: cellPt
                            okKey: false
                            takesFocus: false
                            onPointed: { bs.zone = 0; bs.slot = cell.index }
                            onTapped: { bs.zone = 0; bs.slot = cell.index; bs.listen(cell.index) }
                        }
                    }
                }
            }
            Item { width: 1; height: 16 * bs.u }
            Row {
                spacing: 24 * bs.u
                GlassButton {
                    icon: "arrowleft"
                    text: qsTr("Back")
                    focused: bs.activeFocus && bs.zone === 1 && bs.choice === 0
                    pointerFocus: false
                    onPointed: { bs.zone = 1; bs.choice = 0 }
                    onClicked: bs.close()
                }
                GlassButton {
                    text: qsTr("Clear Slot %1").arg(bs.slot + 1)
                    focused: bs.activeFocus && bs.zone === 1 && bs.choice === 1
                    pointerFocus: false
                    opacity: bs.slot < bs.bound.length ? 1 : 0.4
                    onPointed: { bs.zone = 1; bs.choice = 1 }
                    onClicked: bs.clearSlot()
                }
            }
        }
    }
}
