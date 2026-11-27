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

    // how it's typed, picked as it opens: "osk" the glass keyboard (a remote or pad), "keys" a real
    // keyboard and the mouse (the field, paste and done), "ime" the phone's own keyboard (a finger).
    // only a remote or pad taking over changes it: the glass keyboard comes up and stays
    property string mode: "osk"
    readonly property bool remoteNow: InputMode.remote
    onRemoteNowChanged: if (remoteNow && isOpen && mode !== "osk") toOsk()
    function toOsk() {
        if (mode === "ime") Qt.inputMethod.hide()
        mode = "osk"
        keys.forceActiveFocus()
        Input.swallowKey()
    }

    function open(o) {
        title = o.title || ""; hint = o.hint || ""; placeholder = o.placeholder || ""
        secret = !!o.secret; text = o.text || ""; check = o.check || null; allowEmpty = !!o.allowEmpty
        status = ""; busy = false; ok = false; kb.shift = false
        mode = InputMode.pick()
        isOpen = true; keys.forceActiveFocus()
        if (ime.on) Qt.callLater(ime.open)
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
    Shield { enabled: ke.isOpen; onOutside: ke.cancel() }

    Item {
        id: sheet
        anchors.fill: parent
        opacity: Math.min(1, ke.reveal * 1.6)
        // a docked phone keyboard: up above it
        readonly property real lift: Math.max(0, ke.height / 2 + card.height / 2 + 24 * ke.u - ke.mapFromItem(null, 0, ime.keyboardTop).y)
        transform: Translate { y: (1 - ke.reveal) * 280 * ke.u - sheet.lift }
    Glass {
        id: card
        anchors.centerIn: parent
        // the content as wide as the keyboard (the same size everywhere)
        width: (Theme.keyboardW + 2 * 48) * ke.u
        height: col.height + 2 * 48 * ke.u
        Resize on height {}
        radius: 56 * ke.u
        kind: "panel"
    }
    Column {
        id: col
        anchors { horizontalCenter: card.horizontalCenter; top: card.top; topMargin: 48 * ke.u }
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
                placeholder: ke.placeholder
                secret: ke.secret
                text: ime.on ? ime.displayText : ke.text
                active: ke.isOpen && (!ime.on || ime.activeFocus)
                size: 26 * ke.u
            }
            ImeInput {
                id: ime
                on: ke.mode === "ime"
                value: ke.text
                maximumLength: 4096
                inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | (ke.secret ? Qt.ImhSensitiveData : 0)
                onEdited: function (t) { ke.text = t; ke.status = "" }
                onDone: ke.submit()
            }
            // a finger on the field asks for the phone's keyboard, whatever was up
            Pointer { okKey: false; takesFocus: false; cursorShape: Qt.IBeamCursor; onTapped: { if (Theme.touch) ke.mode = "ime"; else if (InputMode.pcFinger) ke.mode = "osk"; if (ime.on) ime.open(); else keys.forceActiveFocus() } }
        }
        Text {
            id: statusLine
            // a fixed row even while empty where a check answers (else the card jumps); none without one
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            height: ke.check ? 30 * ke.u : 0
            Appear { target: statusLine; key: statusLine.text }
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
            height: ke.mode === "osk" ? kb.height : 0
            visible: !ime.on
            focus: true
            onActiveFocusChanged: if (!activeFocus) typed = false
            Keys.onPressed: function (e) {
                var map = {}
                map[Qt.Key_Up] = "UP"; map[Qt.Key_Down] = "DOWN"; map[Qt.Key_Left] = "LEFT"; map[Qt.Key_Right] = "RIGHT"
                if (map[e.key]) { if (ke.mode === "osk") kb.key(map[e.key]); e.accepted = true; return }
                // a real keyboard's enter submits once it typed or pasted here (always without the glass
                // keyboard); a remote's ok (posted, a d-pad centre, or a usb remote that never types) presses the focused key
                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (ke.mode !== "osk" || Input.realKey() && typed)) { ke.submit(); e.accepted = true; return }
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { kb.key("OK"); e.accepted = true; return }
                if (e.key === Qt.Key_Backspace) { ke.text = ke.text.slice(0, -1); ke.status = ""; e.accepted = true; return }
                if (e.key === Qt.Key_V && (e.modifiers & Qt.ControlModifier)) { ke.text += Desktop.paste(); ke.status = ""; typed = true; e.accepted = true; return }
                if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) { ke.text += e.text; ke.status = ""; typed = true; e.accepted = true }
            }
            Keyboard {
                id: kb
                visible: ke.mode === "osk"
                width: parent.width
                u: ke.u / 2
                enterLabel: qsTr("done")
                active: keys.activeFocus
                onPointed: keys.forceActiveFocus()
                onTyped: function (t) { if (ke.text.length < 4096) { ke.text += t; ke.status = "" } }
                onSpecial: function (n) {
                    if (n === "backspace") ke.text = ke.text.slice(0, -1)
                    else if (n === "clear") ke.text = ""
                    else if (n === "enter") ke.submit()
                    ke.status = ke.busy ? ke.status : ""
                }
            }
        }
        // the phone's keyboard and the mouse have no done of ours; keys are long, pasting is how they arrive
        Row {
            visible: ke.mode !== "osk"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 20 * ke.u
            GlassButton { text: qsTr("Paste"); pointerFocus: false; onClicked: { ke.text += Desktop.paste(); ke.status = "" } }
            GlassButton { text: qsTr("Done"); primary: true; pointerFocus: false; onClicked: ke.submit() }
        }
        Text {
            visible: !ime.on
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: ke.mode === "osk" ? qsTr("A real keyboard works too, and Ctrl+V pastes. Back closes this.")
                                    : qsTr("Ctrl+V pastes, Enter is done, Esc closes this.")
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 22 * ke.u }
        }
    }
    }
}
