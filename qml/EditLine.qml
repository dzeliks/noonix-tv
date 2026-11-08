import QtQuick

// a real field for a mouse or a keyboard: select with the mouse, copy, cut, paste, undo.
// value: the owner's text, edited(): what it becomes, done(): enter
TextInput {
    id: e
    property string value: ""
    property string placeholder: ""
    property real size: 26 * Theme.u
    readonly property real u: Theme.u
    signal edited(string t)
    signal done()
    // real keyboards type here: the input bindings leave it alone
    readonly property bool typing: true
    height: size * 1.5
    verticalAlignment: TextInput.AlignVCenter
    clip: true
    selectByMouse: true
    persistentSelection: false
    inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
    color: Theme.fg
    selectionColor: Qt.rgba(1, 1, 1, 0.32)
    selectedTextColor: "white"
    font { family: Theme.display; pixelSize: size; weight: Font.Medium }
    onTextEdited: if (text !== value) edited(text)
    onValueChanged: if (text !== value) text = value
    Component.onCompleted: text = value
    Keys.onReturnPressed: done()
    Keys.onEnterPressed: done()
    // escape lets go of a selection first
    Keys.onEscapePressed: function (ev) {
        if (selectedText.length) { deselect(); ev.accepted = true } else ev.accepted = false
    }

    cursorDelegate: Rectangle {
        id: caret
        property bool on: true
        visible: e.activeFocus && on && !e.selectedText.length
        width: 3 * e.u
        height: e.size * 1.15
        y: (e.height - height) / 2
        radius: width / 2
        color: Theme.fg
        Timer {
            interval: 530
            repeat: true
            running: e.activeFocus
            onTriggered: caret.on = !caret.on
        }
        Connections {
            target: e
            function onTextChanged() { caret.on = true }
            function onCursorPositionChanged() { caret.on = true }
        }
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        x: 2 * e.u
        visible: !e.text.length
        text: e.placeholder
        color: Theme.fg3
        font: e.font
    }
}
