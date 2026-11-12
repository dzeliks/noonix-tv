import QtQuick

// a short fade-in for what shows up all at once (a status line, a row turning visible): restarts
// each time `key` changes to something truthy while the target is shown. the target's opacity
// must be its own (not bound)
NumberAnimation {
    property var key: target ? target.visible : false
    property: "opacity"
    from: 0; to: 1
    duration: 180
    easing.type: Easing.OutQuad
    onKeyChanged: if (key && target && target.visible) restart()
}
