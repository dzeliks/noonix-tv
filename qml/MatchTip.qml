import QtQuick

// one-time tip on the first play: what "how's this one?" is and how to open it.
// ok = again next launch, don't show again = never
FocusScope {
    id: tip
    readonly property real u: Theme.u
    property int choice: 0               // 0 ok, 1 don't show again
    signal done(bool forever)
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    function open() { choice = 0; opacity = 1; forceActiveFocus() }
    function close() { opacity = 0 }
    function pick(forever) { close(); done(forever) }

    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.32 }
    Shield { onOutside: tip.pick(false) }

    Item {
        id: card
        anchors.centerIn: parent
        width: 1040 * tip.u
        height: body.height + 112 * tip.u
        scale: tip.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 52 * tip.u }

        Column {
            id: body
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 56 * tip.u }
            width: parent.width - 120 * tip.u
            spacing: 0

            // the button it's about, as it looks when focused
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 104 * tip.u; height: width; radius: width / 2
                color: "white"
                Symbol {
                    anchors.centerIn: parent
                    width: 50 * tip.u; height: width
                    name: "feedback"; weight: 1.8
                    color: Theme.focusFg
                }
            }
            Item { width: 1; height: 30 * tip.u }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("How's this one?")
                color: Theme.fg
                font { family: Theme.display; pixelSize: 46 * tip.u; weight: Font.Bold }
            }
            Item { width: 1; height: 14 * tip.u }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                lineHeight: 1.12
                text: Theme.say(qsTr("Press Menu while watching to say if the source and subtitles fit."),
                               qsTr("Tap the screen while watching, then the speech bubble, to say if the source and subtitles fit."),
                               qsTr("Click the speech bubble while watching to say if the source and subtitles fit."))
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 27 * tip.u; weight: Font.Medium }
            }
            Item { width: 1; height: 34 * tip.u }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12 * tip.u
                Repeater {
                    model: [
                        { icon: "checkcircle", label: qsTr("Good match") },
                        { icon: "sync", label: qsTr("Out of sync") },
                        { icon: "subtitles", label: qsTr("Wrong subtitles") },
                        { icon: "film", label: qsTr("Picture or sound") }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        height: 58 * tip.u
                        width: chip.implicitWidth + 40 * tip.u
                        radius: height / 2
                        color: Qt.rgba(1, 1, 1, 0.08)
                        border { width: 1; color: Qt.rgba(1, 1, 1, 0.10) }
                        Row {
                            id: chip
                            anchors.centerIn: parent
                            spacing: 10 * tip.u
                            Symbol {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 26 * tip.u; height: width
                                name: modelData.icon; weight: 1.8
                                color: Theme.fg
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                color: Theme.fg
                                font { family: Theme.text; pixelSize: 21 * tip.u; weight: Font.Medium }
                            }
                        }
                    }
                }
            }
            Item { width: 1; height: 26 * tip.u }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: qsTr("What works is remembered for the next episodes.\nWhat doesn't gets fixed where you are.")
                color: Theme.fg3
                font { family: Theme.text; pixelSize: 22 * tip.u }
            }
            Item { width: 1; height: 44 * tip.u }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 24 * tip.u
                GlassButton {
                    width: 360 * tip.u
                    text: qsTr("OK")
                    primary: Theme.touch
                    focused: tip.activeFocus && tip.choice === 0
                    pointerFocus: false
                    onPointed: tip.choice = 0
                    onClicked: tip.pick(false)
                }
                GlassButton {
                    width: 360 * tip.u
                    text: qsTr("Don't show again")
                    focused: tip.activeFocus && tip.choice === 1
                    pointerFocus: false
                    onPointed: tip.choice = 1
                    onClicked: tip.pick(true)
                }
            }
        }
    }

    Keys.onLeftPressed: choice = 0
    Keys.onRightPressed: choice = 1
    Keys.onReturnPressed: pick(choice === 1)
    Keys.onEnterPressed: pick(choice === 1)
    Keys.onEscapePressed: pick(false)
    Keys.onBackPressed: pick(false)
    Keys.onPressed: function (e) { e.accepted = true }
}
