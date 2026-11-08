import QtQuick

// a yes / no question over everything, like the exit prompt: the title, a line on what happens,
// then the two buttons. cancel has the focus, so a stray ok or back is harmless
FocusScope {
    id: cf
    readonly property real u: Theme.u
    property string title: ""
    property string detail: ""
    property string okText: ""
    property var onYes: null
    property int choice: 1               // 0 yes, 1 cancel
    signal closed()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    function open(o) {
        title = o.title || ""; detail = o.detail || ""; okText = o.ok || ""; onYes = o.yes || null
        choice = 1
        opacity = 1
        forceActiveFocus()
    }
    function close() { opacity = 0; closed() }
    function yes() { var f = onYes; onYes = null; close(); if (f) f() }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: cf.close() }

    Column {
        anchors.centerIn: parent
        // the title on one line (as long as it fits), the detail a little narrower, everything centred
        width: Math.max(buttons.width, Math.min(titleText.implicitWidth, cf.width - 2 * Theme.margin))
        scale: cf.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Text {
            id: titleText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: cf.title
            color: Theme.fg
            font { family: Theme.display; pixelSize: 64 * cf.u; weight: Font.Bold }
        }
        Item { width: 1; height: 26 * cf.u; visible: cf.detail !== "" }
        Text {
            visible: cf.detail !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, 900 * cf.u)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: cf.detail
            color: Theme.fg2
            lineHeight: 1.15
            font { family: Theme.text; pixelSize: 28 * cf.u }
        }
        Item { width: 1; height: 56 * cf.u }
        Row {
            id: buttons
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 28 * cf.u
            // one width for both: the longer label decides
            readonly property real bw: Math.max(300 * cf.u, okM.advanceWidth + 120 * cf.u, noM.advanceWidth + 120 * cf.u)
            TextMetrics { id: okM; text: cf.okText; font { family: Theme.display; pixelSize: 27 * cf.u; weight: Font.DemiBold } }
            TextMetrics { id: noM; text: qsTr("Cancel"); font: okM.font }
            GlassButton {
                width: buttons.bw
                text: cf.okText
                focused: cf.activeFocus && cf.choice === 0
                pointerFocus: false
                onPointed: cf.choice = 0
                onClicked: cf.yes()
            }
            GlassButton {
                width: buttons.bw
                text: qsTr("Cancel")
                focused: cf.activeFocus && cf.choice === 1
                pointerFocus: false
                onPointed: cf.choice = 1
                onClicked: cf.close()
            }
        }
    }

    Keys.onLeftPressed: choice = 0
    Keys.onRightPressed: choice = 1
    Keys.onReturnPressed: choice === 0 ? yes() : close()
    Keys.onEnterPressed: choice === 0 ? yes() : close()
    Keys.onEscapePressed: close()
    Keys.onBackPressed: close()
    Keys.onPressed: function (e) { e.accepted = true }
}
