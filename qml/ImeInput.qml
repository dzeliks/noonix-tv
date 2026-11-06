import QtQuick

// touch on android: the phone's own keyboard types into this, unseen. the field's line shows
// displayText (half typed words too). value: the owner's text, edited(): what it becomes
TextInput {
    id: ii
    readonly property bool on: Theme.touch
    property string value: ""
    signal edited(string t)
    signal done()
    // where a docked phone keyboard starts, in scene y (android hands it over in device pixels);
    // the window's bottom while there's none (or it floats)
    readonly property rect kbr: Qt.inputMethod.keyboardRectangle
    readonly property real keyboardTop: on && Qt.inputMethod.visible && kbr.height > 0
        ? kbr.y / Screen.devicePixelRatio : (Window.window ? Window.window.height : 100000)
    // real keyboards type here too: the input bindings leave it alone
    readonly property bool typing: true
    anchors.fill: parent
    opacity: 0
    enabled: on
    inputMethodHints: Qt.ImhNoAutoUppercase
    onDisplayTextChanged: if (activeFocus && displayText !== value) edited(displayText)
    onValueChanged: if (displayText !== value) text = value
    Keys.onReturnPressed: finish()
    Keys.onEnterPressed: finish()
    onActiveFocusChanged: if (!activeFocus && on) Qt.inputMethod.hide()

    function open() {
        if (text !== value) text = value
        forceActiveFocus()
        cursorPosition = text.length
        Qt.inputMethod.show()
    }
    function finish() {
        Qt.inputMethod.commit()
        Qt.inputMethod.hide()
        done()
    }
}
