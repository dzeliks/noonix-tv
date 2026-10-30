import QtQuick

// one key, address or login typed in setup / settings: the glass keyboard (remote), a real
// keyboard, or ctrl+v. `check` runs on done; its answer stays on the sheet until it works
FocusScope {
    id: ke
    readonly property real u: Theme.u
    property string title: ""
    property string hint: ""           // where to get it, in plain words
    property string placeholder: ""
    property bool secret: false        // passwords show as dots
    property bool allowEmpty: false    // an empty answer counts (clears a list)
    property string text: ""
    property string status: ""
    property bool busy: false
    property bool ok: false
    // function (value, reply): reply(ok, message)
    property var check: null
    signal done(string value)
    signal cancel()
    // the sheet slides up into place and drops away; closed and opened again at once (one sheet
    // after the other, like username then password) it just stays
    property bool isOpen: false
    property real reveal: 0
    onIsOpenChanged: {
        slide.to = isOpen ? 1 : 0
        slide.duration = isOpen ? 440 : 230
        slide.easing.type = isOpen ? Easing.OutCubic : Easing.InCubic
        slide.restart()
    }
    NumberAnimation { id: slide; target: ke; property: "reveal" }
    visible: reveal > 0

    function open(o) {
        title = o.title || ""; hint = o.hint || ""; placeholder = o.placeholder || ""
        secret = !!o.secret; text = o.text || ""; check = o.check || null; allowEmpty = !!o.allowEmpty
        status = ""; busy = false; ok = false; kb.shift = false
        isOpen = true; keys.forceActiveFocus()
    }
    function close() { isOpen = false }
    function submit() {
        var v = text.trim()
        if ((!v && !allowEmpty) || busy) return
        if (!check) { done(v); return }
        busy = true; status = qsTr("Checking…")
        check(v, function (good, message) {
            ke.busy = false; ke.ok = good
            ke.status = message || (good ? qsTr("Works") : qsTr("That didn't work"))
            if (good) closeLater.start()
        })
    }
    // the tick shows for a moment before the sheet goes
    Timer { id: closeLater; interval: 700; onTriggered: ke.done(ke.text.trim()) }
    Keys.onEscapePressed: cancel()

    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.35 * ke.reveal }
    MouseArea { anchors.fill: parent; enabled: ke.isOpen; acceptedButtons: Qt.RightButton; onClicked: ke.cancel() }

    Item {
        id: sheet
        anchors.fill: parent
        opacity: Math.min(1, ke.reveal * 1.6)
        transform: Translate { y: (1 - ke.reveal) * 280 * ke.u }
    Glass {
        id: card
        anchors.centerIn: parent
        width: 900 * ke.u
        height: col.height + 2 * 48 * ke.u
        radius: 56 * ke.u
        kind: "panel"
    }
    Column {
        id: col
        anchors.centerIn: card
        width: card.width - 2 * 48 * ke.u
        spacing: 22 * ke.u
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ke.title
            color: Theme.fg
            font { family: Theme.display; pixelSize: 40 * ke.u; weight: Font.Bold }
        }
        Text {
            width: parent.width
            visible: ke.hint !== ""
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: ke.hint
            color: Theme.fg2
            font { family: Theme.text; pixelSize: 24 * ke.u }
        }
        Rectangle {
            width: parent.width
            height: 64 * ke.u
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.1)
            border.width: 1 * ke.u
            border.color: Qt.rgba(1, 1, 1, 0.14)
            FieldText {
                anchors { left: parent.left; right: parent.right; margins: 28 * ke.u; verticalCenter: parent.verticalCenter }
                text: ke.text
                placeholder: ke.placeholder
                secret: ke.secret
                active: ke.isOpen
                size: 26 * ke.u
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            height: 30 * ke.u
            text: ke.status
            color: ke.ok ? "#30D158" : ke.busy ? Theme.fg2 : "#FF9F0A"
            font { family: Theme.text; pixelSize: 24 * ke.u; weight: Font.Medium }
        }
        FocusScope {
            id: keys
            // real keyboards type here: the input bindings leave it alone
            readonly property bool typing: true
            property bool typed: false
            width: parent.width
            height: kb.height
            focus: true
            onActiveFocusChanged: if (!activeFocus) typed = false
            Keys.onPressed: function (e) {
                var map = {}
                map[Qt.Key_Up] = "UP"; map[Qt.Key_Down] = "DOWN"; map[Qt.Key_Left] = "LEFT"; map[Qt.Key_Right] = "RIGHT"
                if (map[e.key]) { kb.key(map[e.key]); e.accepted = true; return }
                // a real keyboard's enter submits once it typed or pasted here; a remote's ok (posted, no
                // scan code, or a usb remote that never types) presses the focused key
                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && e.nativeScanCode !== 0 && typed) { ke.submit(); e.accepted = true; return }
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { kb.key("OK"); e.accepted = true; return }
                if (e.key === Qt.Key_Backspace) { ke.text = ke.text.slice(0, -1); ke.status = ""; e.accepted = true; return }
                if (e.key === Qt.Key_V && (e.modifiers & Qt.ControlModifier)) { ke.text += Desktop.paste(); ke.status = ""; typed = true; e.accepted = true; return }
                if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) { ke.text += e.text; ke.status = ""; typed = true; e.accepted = true }
            }
            Keyboard {
                id: kb
                width: parent.width
                u: ke.u / 2
                enterLabel: qsTr("done")
                active: keys.activeFocus
                onPointed: keys.forceActiveFocus()
                onTyped: function (t) { if (ke.text.length < 400) { ke.text += t; ke.status = "" } }
                onSpecial: function (n) {
                    if (n === "backspace") ke.text = ke.text.slice(0, -1)
                    else if (n === "clear") ke.text = ""
                    else if (n === "enter") ke.submit()
                    ke.status = ke.busy ? ke.status : ""
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("A real keyboard works too, and Ctrl+V pastes. Back closes this.")
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 22 * ke.u }
        }
    }
    }
}
