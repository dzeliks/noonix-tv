import QtQuick

// "what's this?" next to torrents / a debrid service: the difference in a few lines. asking:
// the torrent one also takes the user's yes or no (a source of theirs answers with torrents)
FocusScope {
    id: help
    readonly property real u: Theme.u
    property string topic: "torrent"     // torrent | debrid
    property bool asking: false
    signal closed()
    signal answered(bool yes)
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    function open(t) { topic = t || "torrent"; asking = false; show() }
    // torrents found: allow them or not
    function ask() { topic = "torrent"; asking = true; show() }
    function show() { opacity = 1; buttons.currentIndex = 0; forceActiveFocus() }
    function close() { opacity = 0; closed() }
    function answer(yes) { opacity = 0; answered(yes); closed() }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: if (!help.asking) help.close() }

    readonly property var texts: help.topic === "debrid" ? [
        qsTr("A debrid service (TorBox, Real-Debrid, AllDebrid and others) is a paid service that fetches videos to its own fast servers, and you watch from there. It starts quickly and plays smoothly."),
        qsTr("An addon or extension you added asks for your key from the service. Noonix TV sends it only to the addresses that extension listed."),
        qsTr("Only watch what you have the right to. You're responsible for the sources you add.")
    ] : [
        qsTr("A source of yours can answer with torrents: the video comes straight from other people who have it. Noonix TV only downloads, it never shares pieces back, and deletes the file when you stop."),
        qsTr("It can be slower to start, and videos few people have may not play. Others in the swarm can see your IP address."),
        qsTr("Downloading videos you have no right to is illegal in many countries. Use it at your own risk, and only for what you're allowed to watch.")
    ]

    Column {
        anchors.centerIn: parent
        width: 1240 * help.u
        spacing: 34 * help.u
        scale: help.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Text {
            text: help.topic === "debrid" ? qsTr("Debrid services") : help.asking ? qsTr("Allow torrents?") : qsTr("Torrents")
            color: Theme.fg
            font { family: Theme.display; pixelSize: 60 * help.u; weight: Font.Bold }
        }
        Repeater {
            model: help.texts
            Text {
                width: parent.width
                text: modelData
                wrapMode: Text.Wrap
                color: Theme.fg2
                lineHeight: 1.15
                font { family: Theme.text; pixelSize: 30 * help.u }
            }
        }
        Text {
            width: parent.width
            visible: help.topic === "torrent"
            text: qsTr("You can change it any time in Settings › Sources.")
            wrapMode: Text.Wrap
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 26 * help.u }
        }
        Item { width: 1; height: 6 * help.u }
        Row {
            id: buttons
            property int currentIndex: 0
            spacing: 24 * help.u
            GlassButton {
                primary: true
                width: 340 * help.u
                text: help.asking ? qsTr("Allow Torrents") : qsTr("Got It")
                focused: help.activeFocus && buttons.currentIndex === 0
                pointerFocus: false
                onClicked: help.asking ? help.answer(true) : help.close()
            }
            GlassButton {
                visible: help.asking
                width: 300 * help.u
                text: qsTr("Not Now")
                focused: help.activeFocus && buttons.currentIndex === 1
                pointerFocus: false
                onClicked: help.answer(false)
            }
        }
    }

    function activate() {
        if (buttons.currentIndex === 1) answer(false)
        else if (asking) answer(true)
        else close()
    }
    Keys.onReturnPressed: activate()
    Keys.onEnterPressed: activate()
    Keys.onLeftPressed: buttons.currentIndex = 0
    Keys.onRightPressed: if (asking) buttons.currentIndex = 1
    Keys.onEscapePressed: asking ? answer(false) : close()
    Keys.onBackPressed: asking ? answer(false) : close()
    Keys.onPressed: function (e) { e.accepted = true }
}
