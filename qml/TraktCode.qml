import QtQuick

// trakt sign-in from settings: the code big enough to read from the couch, polled until trakt says
// yes. back cancels
FocusScope {
    id: tc
    readonly property real u: Theme.u
    property int profile: 0
    property string profileName: ""
    property var code: null
    signal done(bool ok)
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    function open(id, name) {
        profile = id; profileName = name || ""; code = null
        opacity = 1
        forceActiveFocus()
        Api.call("trakt.deviceCode", {}, function (ok, d) {
            if (!ok) { tc.finish(false); toast.show(qsTr("Trakt isn't answering")); return }
            tc.code = d
            poll.interval = (d.interval || 5) * 1000
            poll.left = Math.ceil((d.expires_in || 600) / (d.interval || 5))
            poll.start()
        })
    }
    function finish(ok) { poll.stop(); code = null; opacity = 0; done(ok) }
    Keys.onEscapePressed: finish(false)
    Keys.onReturnPressed: {}

    Timer {
        id: poll
        property int left: 0
        repeat: true
        onTriggered: {
            if (--left <= 0 || !tc.code) { tc.finish(false); return }
            Api.call("trakt.devicePoll", { code: tc.code.device_code, profile: tc.profile }, function (ok, d) {
                if (ok && d.done) { tc.finish(true); toast.show(qsTr("Signed in to Trakt")) }
                else if (!ok) { tc.finish(false); toast.show(qsTr("That code didn't work")) }
            })
        }
    }

    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.4 }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: function (m) { if (m.button === Qt.RightButton) tc.finish(false) } }

    Item {
        anchors.centerIn: parent
        width: 980 * tc.u
        height: body.height + 120 * tc.u
        scale: tc.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 52 * tc.u }
        Column {
            id: body
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 60 * tc.u }
            width: parent.width - 120 * tc.u
            spacing: 14 * tc.u
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: tc.profileName ? qsTr("Trakt for %1").arg(tc.profileName) : "Trakt"
                color: Theme.fg
                font { family: Theme.display; pixelSize: 46 * tc.u; weight: Font.Bold }
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: tc.code ? qsTr("On your phone, open %1 and enter").arg(tc.code.verification_url) : qsTr("Asking Trakt for a code…")
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 27 * tc.u; weight: Font.Medium }
            }
            Item { width: 1; height: 6 * tc.u }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: tc.code ? tc.code.user_code : "· · · ·"
                color: Theme.fg
                font { family: Theme.rounded; pixelSize: 96 * tc.u; weight: Font.Bold; letterSpacing: 10 * tc.u }
            }
            Spinner { anchors.horizontalCenter: parent.horizontalCenter; width: 44 * tc.u; height: width; running: tc.visible }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("Back cancels")
                color: Theme.fg3
                font { family: Theme.text; pixelSize: 22 * tc.u }
            }
        }
    }
}
