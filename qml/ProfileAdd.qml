import QtQuick

// a new profile (or an edit of one): a name on the search keyboard and a look: one of the
// colours or a picture from the avatars folder (~/.local/share/noonix-tv/avatars)
FocusScope {
    id: pa
    readonly property real u: Theme.u
    property string name: ""
    property int editId: 0
    property var taken: []
    property var files: []
    property string dir: ""
    property int choice: 0
    readonly property var colours: ["green", "pink", "blue", "orange", "purple"]
    readonly property var choices: colours.concat(files)
    readonly property bool pictured: choice >= colours.length
    readonly property string colour: pictured ? lastColour : colours[choice]
    readonly property string avatar: pictured ? choices[choice] : ""
    property string lastColour: "green"
    onChoiceChanged: if (!pictured) lastColour = colours[choice]
    signal done(var profile)
    signal cancel()
    // what the card's glass shows through (the picker when it's open over it)
    property variant backdrop: win.backdropTex
    property variant frost: win.frostTex
    visible: false
    function loadFiles(then) {
        Api.call("profiles.avatars", {}, function (ok, d) {
            pa.files = ok ? d.files || [] : []
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
    }
    function openEdit(p) {
        taken = []; name = p.name; editId = p.id
        choice = Math.max(0, colours.indexOf(p.color))
        loadFiles(function () { var i = pa.files.indexOf(p.avatar || ""); if (i >= 0) pa.choice = pa.colours.length + i })
        visible = true; keys.forceActiveFocus()
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

    Glass {
        id: card
        anchors.centerIn: parent
        width: 760 * pa.u
        height: col.height + 2 * 48 * pa.u
        radius: 56 * pa.u
        kind: "panel"
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
                width: 72 * pa.u; height: looks.height
                Avatar {
                    anchors.centerIn: parent
                    size: 64 * pa.u
                    colour: index < pa.colours.length ? modelData : pa.lastColour
                    image: index < pa.colours.length ? "" : modelData
                    letter: ""
                    scale: parent.foc ? 1.14 : 1
                    Behavior on scale { NumberAnimation { duration: 140 } }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 80 * pa.u; height: width; radius: width / 2
                    color: "transparent"
                    border.width: 4 * pa.u
                    border.color: "white"
                    opacity: index === pa.choice ? (parent.foc ? 1 : 0.45) : 0
                }
                Pointer { okKey: false; onPointed: { pa.choice = index; looks.forceActiveFocus() } onTapped: keys.forceActiveFocus() }
            }
            Keys.onLeftPressed: pa.choice = Math.max(0, pa.choice - 1)
            Keys.onRightPressed: pa.choice = Math.min(pa.choices.length - 1, pa.choice + 1)
            Keys.onDownPressed: keys.forceActiveFocus()
            Keys.onReturnPressed: keys.forceActiveFocus()
            Keys.onEnterPressed: keys.forceActiveFocus()
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
                text: pa.name
                placeholder: qsTr("Name")
                active: keys.activeFocus
                size: 28 * pa.u
            }
        }
        FocusScope {
            id: keys
            // real keyboards type here: the input bindings leave it alone
            readonly property bool typing: true
            width: parent.width
            height: kb.height
            focus: true
            Keys.onPressed: function (e) {
                var map = {}
                map[Qt.Key_Up] = "UP"; map[Qt.Key_Down] = "DOWN"; map[Qt.Key_Left] = "LEFT"; map[Qt.Key_Right] = "RIGHT"
                map[Qt.Key_Return] = "OK"; map[Qt.Key_Enter] = "OK"
                if (map[e.key]) { kb.key(map[e.key]); e.accepted = true; return }
                if (e.key === Qt.Key_Backspace) { pa.name = pa.name.slice(0, -1); e.accepted = true; return }
                if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) { pa.name += e.text; e.accepted = true }
            }
            Keyboard {
                id: kb
                width: parent.width
                u: pa.u / 2
                enterLabel: qsTr("done")
                active: keys.activeFocus
                onPointed: keys.forceActiveFocus()
                onLeave: function (dir) { if (dir === "up") looks.forceActiveFocus() }
                onTyped: function (t) { if (pa.name.length < 20) pa.name += t }
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
            text: qsTr("Up to pick a colour or a picture. Pictures: PNG or JPG files in %1").arg(pa.dir)
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 22 * pa.u }
        }
    }
}
