import QtQuick

// a website from settings: a qr code for the phone, or the browser on this pc
FocusScope {
    id: sc
    readonly property real u: Theme.u
    property string url: ""
    property string title: ""
    property string svg: ""
    signal closed()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    function open(link, name) {
        url = link; title = name || link; svg = ""
        opacity = 1
        openBtn.forceActiveFocus()
        Api.call("qr", { text: link }, function (ok, d) { if (ok) sc.svg = d.svg })
    }
    function close() { opacity = 0; closed() }
    Keys.onEscapePressed: close()

    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.4 }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: sc.close() }

    Item {
        anchors.centerIn: parent
        width: 760 * sc.u
        height: body.height + 120 * sc.u
        scale: sc.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Glass { anchors.fill: parent; kind: "panel"; radius: 52 * sc.u }
        MouseArea { anchors.fill: parent }
        Column {
            id: body
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 60 * sc.u }
            width: parent.width - 120 * sc.u
            spacing: 0
            // the code on its own white tile, like a phone's own qr sheets
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 340 * sc.u; height: width; radius: 36 * sc.u
                color: "white"
                Image {
                    anchors { fill: parent; margins: 18 * sc.u }
                    source: sc.svg ? "data:image/svg+xml;base64," + Qt.btoa(sc.svg) : ""
                    sourceSize: Qt.size(width, height)
                    smooth: false
                }
                Spinner { anchors.centerIn: parent; width: 44 * sc.u; height: width; running: !sc.svg && sc.visible; visible: !sc.svg }
            }
            Item { width: 1; height: 34 * sc.u }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: sc.title
                color: Theme.fg
                font { family: Theme.display; pixelSize: 46 * sc.u; weight: Font.Bold }
            }
            Item { width: 1; height: 10 * sc.u }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("Scan it with your phone's camera")
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 27 * sc.u; weight: Font.Medium }
            }
            Item { width: 1; height: 38 * sc.u }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 20 * sc.u
                GlassButton {
                    id: openBtn
                    primary: true
                    text: qsTr("Open in Browser")
                    onClicked: { Qt.openUrlExternally(sc.url); sc.close() }
                    KeyNavigation.right: closeBtn
                }
                GlassButton {
                    id: closeBtn
                    text: qsTr("Close")
                    onClicked: sc.close()
                    KeyNavigation.left: openBtn
                }
            }
        }
    }
}
