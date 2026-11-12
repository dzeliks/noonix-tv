import QtQuick

// first trakt sign-in on a profile that already has a history here: whose counts from now on.
// back leaves both as they are, nothing is deleted or sent
FocusScope {
    id: tc
    readonly property real u: Theme.u
    property int profile: 0
    property var local: null              // { watched, progress, library }
    property bool busy: false
    property var back: null
    signal chosen()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    function ask(id, counts) {
        profile = id; local = counts; busy = false
        back = win.activeFocusItem
        list.currentIndex = 1
        opacity = 1
        list.forceActiveFocus()
    }
    function close() {
        opacity = 0
        if (back) back.forceActiveFocus()
        chosen()
    }
    function pick(i) {
        if (busy) return
        busy = true
        var c = options[i].id
        Api.call("trakt.choose", { profile: profile, choice: c }, function (ok) {
            tc.busy = false
            if (ok) tc.close()
            else toast.show(c === "merge" ? qsTr("Trakt isn't answering") : qsTr("Couldn't save it"))
        })
    }
    readonly property string summary: {
        var l = local || {}, out = []
        if (l.watched) out.push(qsTr("%1 watched").arg(l.watched))
        if (l.progress) out.push(qsTr("%1 in progress").arg(l.progress))
        if (l.library) out.push(qsTr("%1 in Library").arg(l.library))
        return out.join("  ·  ")
    }
    readonly property var options: [
        { id: "trakt", label: qsTr("Overwrite with Trakt"), detail: qsTr("Delete what's here and use Trakt's history") },
        { id: "merge", label: qsTr("Merge"), detail: qsTr("Add what's here to Trakt and keep both") },
        { id: "local", label: qsTr("Use Local"), detail: qsTr("Keep what's here, only new watches go to Trakt") }
    ]
    Keys.onEscapePressed: if (!busy) close()
    Keys.onBackPressed: if (!busy) close()
    Keys.onPressed: function (e) { e.accepted = true }

    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.4 }
    Shield { onOutside: if (!tc.busy) tc.close(); onRightClick: if (!tc.busy) tc.close() }

    Item {
        anchors.centerIn: parent
        width: 1040 * tc.u
        height: body.height + 104 * tc.u
        Resize on height {}
        scale: tc.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 52 * tc.u }
        Column {
            id: body
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 52 * tc.u }
            width: parent.width - 104 * tc.u
            spacing: 14 * tc.u
            Text {
                width: parent.width
                text: qsTr("This profile already has a history")
                wrapMode: Text.WordWrap
                color: Theme.fg
                font { family: Theme.display; pixelSize: 42 * tc.u; weight: Font.Bold }
            }
            Text {
                width: parent.width
                text: tc.summary
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 27 * tc.u; weight: Font.Medium }
            }
            Item { width: 1; height: 10 * tc.u }
            ListView {
                id: list
                width: parent.width
                height: contentHeight
                interactive: false
                spacing: 4 * tc.u
                model: tc.options
                focus: true
                keyNavigationEnabled: true
                opacity: tc.busy ? 0.5 : 1
                delegate: Toggle {
                    required property var modelData
                    required property int index
                    width: list.width
                    label: modelData.label
                    detail: modelData.detail
                    checkable: false
                    grow: 1
                    focused: list.currentIndex === index && list.activeFocus
                }
                Keys.onReturnPressed: tc.pick(currentIndex)
                Keys.onEnterPressed: tc.pick(currentIndex)
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: 8 * tc.u
                text: tc.busy ? qsTr("Sending it to Trakt…") : qsTr("Back changes nothing")
                color: Theme.fg3
                font { family: Theme.text; pixelSize: 22 * tc.u }
            }
        }
    }
}
