pragma Singleton
import QtQuick

// one minute tick for the whole ui (clock, "ends at"); wakes on the minute, never polls faster
QtObject {
    id: clock
    property date now: new Date()
    property int minute: 0
    readonly property string hhmm: Qt.formatTime(now, "HH:mm")

    readonly property Timer tick: Timer {
        running: true
        interval: 60000 - (Date.now() % 60000) + 50
        onTriggered: {
            clock.now = new Date()
            clock.minute++
            interval = 60000 - (Date.now() % 60000) + 50
            restart()
        }
    }
}
