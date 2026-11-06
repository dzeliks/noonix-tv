import QtQuick

// a new profile (or an edit of one): a name on the search keyboard and a look: one of the
// colours or a picture from the avatars folder (~/.local/share/noonix-tv/avatars; android: + picks
// one from the phone's gallery into it)
FocusScope {
    id: pa
    readonly property real u: Theme.u
    // real keyboards type here wherever the focus is: the input bindings leave it alone
    readonly property bool typing: true
    property string name: ""
    property int editId: 0
    property var taken: []
    property var files: []
    property string dir: ""
    property string fullDir: ""
    // android: the last look is "+", a picture from the gallery
    readonly property bool canPick: Theme.android && Input.canPickPicture()
    property int choice: 0
    property int pointedLook: -1           // under the mouse: a click picks it, hovering only shows it
    readonly property var colours: ["green", "pink", "blue", "orange", "purple"]
    readonly property var choices: colours.concat(files).concat(canPick ? ["+"] : [])
    readonly property bool picking: choices[choice] === "+"
    readonly property bool pictured: choice >= colours.length && !picking
    readonly property string colour: choice < colours.length ? colours[choice] : lastColour
    readonly property string avatar: pictured ? choices[choice] : ""
    property string lastColour: "green"
    onChoiceChanged: if (choice < colours.length) lastColour = colours[choice]
    readonly property bool hasPicked: files.some(function (f) { return /[\/]picture-[^\/]+$/.test(f) })
    function pick() { Input.pickPicture(fullDir) }
    // held: a picture picked on this phone goes again
    function unpick(i) {
        var f = choices[i]
        if (i < colours.length || !/[\/]picture-[^\/]+$/.test(f)) return
        var was = pa.choice
        Api.call("profiles.removeAvatar", { file: f }, function (ok, d) {
            if (!ok) return
            pa.pointedLook = -1
            pa.files = d.files || []
            pa.choice = was === i ? Math.max(0, pa.colours.indexOf(pa.lastColour)) : was > i ? was - 1 : was
        })
    }
    Connections {
        target: Input
        enabled: pa.visible
        function onPicturePicked(path) {
            if (path) pa.loadFiles(function () { var i = pa.files.indexOf(path); if (i >= 0) pa.choice = pa.colours.length + i })
        }
    }
    signal done(var profile)
    signal cancel()
    // what the card's glass shows through (the picker when it's open over it)
    property variant backdrop: win.glassTex(pa)
    property variant frost: win.glassFrost(pa)
    visible: false
    function loadFiles(then) {
        Api.call("profiles.avatars", {}, function (ok, d) {
            pa.files = ok ? d.files || [] : []
            pa.fullDir = ok ? d.dir || "" : ""
            pa.dir = ok ? (d.dir || "").replace(/^\/home\/[^\/]+/, "~") : ""
            if (then) then()
        })
    }
    // names start with a capital, like on a phone
    onNameChanged: kb.shift = name === ""
    function open(used) {
        taken = used || []; name = ""; editId = 0; kb.shift = true
        var free = 0
        while (free < colours.length && taken.indexOf(colours[free]) >= 0) ++free
        choice = free < colours.length ? free : taken.length % colours.length
        loadFiles()
        visible = true; keys.forceActiveFocus()
        if (ime.on) Qt.callLater(ime.open)
    }
    function openEdit(p) {
        taken = []; name = p.name; editId = p.id
        choice = Math.max(0, colours.indexOf(p.color))
        loadFiles(function () { var i = pa.files.indexOf(p.avatar || ""); if (i >= 0) pa.choice = pa.colours.length + i })
        visible = true; keys.forceActiveFocus()
        if (ime.on) Qt.callLater(ime.open)
    }
    function create() {
        var n = name.trim()
        if (!n) return
        var p = { name: n, color: colour, avatar: avatar }
        if (editId) {
            Api.call("profiles.update", Object.assign({ id: editId }, p), function (ok) {
                if (ok) pa.done(Object.assign({ id: pa.editId }, p))
            })
            return
        }
        Api.call("profiles.add", p, function (ok, d) {
            if (ok) pa.done(Object.assign({ id: d.id }, p))
        })
    }
    Keys.onEscapePressed: cancel()
    function add(t) { if (name.length < 20) name += t }

    Shield { onOutside: pa.cancel() }
    Glass {
        id: card
        anchors.centerIn: parent
        // a docked phone keyboard: up above it
        anchors.verticalCenterOffset: -Math.max(0, pa.height / 2 + height / 2 + 24 * pa.u - pa.mapFromItem(null, 0, ime.keyboardTop).y)
        Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        width: 760 * pa.u
        height: col.height + 2 * 48 * pa.u
        radius: 56 * pa.u
        kind: "panel"
        dim: Theme.veil
        backdrop: pa.backdrop
        frostTex: pa.frost
    }
    Column {
        id: col
        anchors.centerIn: card
        width: card.width - 2 * 48 * pa.u
        spacing: 26 * pa.u
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: pa.editId ? qsTr("Edit Profile") : qsTr("New Profile")
            color: Theme.fg
            font { family: Theme.display; pixelSize: 40 * pa.u; weight: Font.Bold }
        }
        Avatar {
            anchors.horizontalCenter: parent.horizontalCenter
            size: 150 * pa.u
            colour: pa.colour
            image: pa.avatar
            letter: pa.name.trim().charAt(0).toUpperCase()
        }
        // the looks: colours, then the pictures
        ListWheel { view: looks; across: true }
        ListView {
            id: looks
            width: Math.min(parent.width, count * (72 + 18) * pa.u - 18 * pa.u + 2 * 10 * pa.u)
            leftMargin: 10 * pa.u
            rightMargin: 10 * pa.u
            anchors.horizontalCenter: parent.horizontalCenter
            height: 92 * pa.u
            orientation: ListView.Horizontal
            spacing: 18 * pa.u
            clip: true
            model: pa.choices
            currentIndex: pa.choice
            highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
            preferredHighlightBegin: width / 2 - 36 * pa.u
            preferredHighlightEnd: width / 2 + 36 * pa.u
            highlightMoveDuration: 220
            highlightMoveVelocity: -1
            delegate: Item {
                required property var modelData
                required property int index
                readonly property bool foc: index === pa.choice && looks.activeFocus
                readonly property bool pointed: index === pa.pointedLook
                width: 72 * pa.u; height: looks.height
                Avatar {
                    visible: modelData !== "+"
                    anchors.centerIn: parent
                    size: 64 * pa.u
                    colour: index < pa.colours.length ? modelData : pa.lastColour
                    image: index < pa.colours.length || modelData === "+" ? "" : modelData
                    letter: ""
                    scale: parent.foc || parent.pointed ? 1.14 : 1
                    Behavior on scale { NumberAnimation { duration: 140 } }
                }
                // a picture from the gallery
                Rectangle {
                    visible: modelData === "+"
                    anchors.centerIn: parent
                    width: 64 * pa.u; height: width; radius: width / 2
                    color: Qt.rgba(1, 1, 1, 0.12)
                    scale: parent.foc || parent.pointed ? 1.14 : 1
                    Behavior on scale { NumberAnimation { duration: 140 } }
                    Text {
                        anchors.centerIn: parent
                        text: "+"
                        color: Theme.fg
                        font { family: Theme.text; pixelSize: 40 * pa.u; weight: Font.Medium }
                    }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 80 * pa.u; height: width; radius: width / 2
                    color: "transparent"
                    border.width: 4 * pa.u
                    border.color: "white"
                    opacity: index === pa.choice ? (parent.foc ? 1 : 0.45) : parent.pointed ? 0.3 : 0
                }
                Pointer {
                    okKey: false
                    takesFocus: false
                    menuOnHold: pa.canPick && /[\/]picture-[^\/]+$/.test(modelData)
                    holdMenuKey: false
                    onHeld: pa.unpick(index)
                    onContainsMouseChanged: pa.pointedLook = containsMouse ? index : pa.pointedLook === index ? -1 : pa.pointedLook
                    onTapped: {
                        if (modelData === "+") { pa.pick(); return }
                        pa.choice = index; keys.forceActiveFocus()
                    }
                }
            }
            Keys.onMenuPressed: pa.unpick(pa.choice)
            Keys.onLeftPressed: pa.choice = Math.max(0, pa.choice - 1)
            Keys.onRightPressed: pa.choice = Math.min(pa.choices.length - 1, pa.choice + 1)
            Keys.onDownPressed: keys.forceActiveFocus()
            Keys.onReturnPressed: pa.picking ? pa.pick() : keys.forceActiveFocus()
            Keys.onEnterPressed: pa.picking ? pa.pick() : keys.forceActiveFocus()
            // letters on the way: back to the name
            Keys.onPressed: function (e) {
                if (e.key === Qt.Key_Backspace) { pa.name = pa.name.slice(0, -1); e.accepted = true; return }
                if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) {
                    pa.add(e.text); keys.typed = true; keys.forceActiveFocus(); e.accepted = true
                }
            }
        }
        Rectangle {
            width: parent.width
            height: 64 * pa.u
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.1)
            border.width: 1 * pa.u
            border.color: Qt.rgba(1, 1, 1, 0.14)
            FieldText {
                anchors { left: parent.left; right: parent.right; margins: 28 * pa.u; verticalCenter: parent.verticalCenter }
                text: ime.on ? ime.displayText : pa.name
                placeholder: qsTr("Name")
                active: pa.visible && (!ime.on || ime.activeFocus)
                size: 28 * pa.u
            }
            ImeInput {
                id: ime
                value: pa.name
                maximumLength: 20
                inputMethodHints: Qt.ImhNone
                onEdited: function (t) { pa.name = t }
                onDone: pa.create()
            }
            Pointer { okKey: false; takesFocus: false; cursorShape: Qt.IBeamCursor; onTapped: if (ime.on) ime.open(); else keys.forceActiveFocus() }
        }
        // the phone's keyboard has no done of ours
        GlassButton {
            visible: ime.on
            anchors.horizontalCenter: parent.horizontalCenter
            text: pa.editId ? qsTr("Save") : qsTr("Create")
            primary: true
            pointerFocus: false
            onClicked: pa.create()
        }
        FocusScope {
            id: keys
            // letters came from a real keyboard: its enter is done (a remote's ok presses the focused key)
            property bool typed: false
            width: parent.width
            height: ime.on ? 0 : kb.height
            visible: !ime.on
            focus: true
            onActiveFocusChanged: if (!activeFocus) typed = false
            Keys.onPressed: function (e) {
                var map = {}
                map[Qt.Key_Up] = "UP"; map[Qt.Key_Down] = "DOWN"; map[Qt.Key_Left] = "LEFT"; map[Qt.Key_Right] = "RIGHT"
                if (map[e.key]) { kb.key(map[e.key]); e.accepted = true; return }
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    if (typed && Input.realKey()) pa.create(); else kb.key("OK")
                    e.accepted = true; return
                }
                if (e.key === Qt.Key_Backspace) { pa.name = pa.name.slice(0, -1); e.accepted = true; return }
                if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) { pa.add(e.text); typed = true; e.accepted = true }
            }
            Keyboard {
                id: kb
                width: parent.width
                u: pa.u / 2
                enterLabel: qsTr("done")
                active: keys.activeFocus
                onPointed: keys.forceActiveFocus()
                onLeave: function (dir) { if (dir === "up") looks.forceActiveFocus() }
                onTyped: function (t) { pa.add(t) }
                onSpecial: function (n) {
                    if (n === "backspace") pa.name = pa.name.slice(0, -1)
                    else if (n === "clear") pa.name = ""
                    else if (n === "enter") pa.create()
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            // android: the folder is the app's own, nothing else can put files there
            text: Theme.android ? (pa.canPick ? Theme.say(qsTr("Up to pick a colour, or + for a picture."), (pa.hasPicked ? qsTr("Tap a colour or + for a picture · hold a picture to remove it") : qsTr("Tap a colour above, or + for a picture.")), qsTr("Click a colour above, or + for a picture."))
                                              : Theme.say(qsTr("Up to pick a colour."), qsTr("Tap a colour above."), qsTr("Click a colour above.")))
                : Theme.say(qsTr("Up to pick a colour or a picture. Pictures: PNG or JPG files in %1"), "", qsTr("Click a colour or a picture above. Pictures: PNG or JPG files in %1")).arg(pa.dir)
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 22 * pa.u }
        }
    }
}
