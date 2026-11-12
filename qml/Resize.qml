import QtQuick

// a size that follows its content eases there (quick, no jump). off until the item has been on
// screen a moment, so a sheet opens at its size instead of growing into it
Behavior {
    id: b
    readonly property Item host: targetProperty.object
    readonly property bool shown: !!host && host.visible
    property bool settled: false
    onShownChanged: { settled = false; if (shown) wait.restart() }
    Component.onCompleted: if (shown) wait.restart()
    property Timer wait: Timer { interval: 300; onTriggered: b.settled = true }
    enabled: settled
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
}
