import QtQuick

// picking a library folder, or a noonix file (files: true), with the remote (the system's dialog
// wants a mouse): the places to start from (home, its video or downloads folder, the drives), then
// folder by folder. ok opens a folder or picks the file, back goes up
FocusScope {
    id: picker
    readonly property real u: Theme.u
    property var view: ({})               // library.browse: path, label, parent, folders, videos, files
    property bool busy: false
    property var files: []               // file extensions to list and pick, none = a folder
    property string caption: qsTr("Add a folder")
    signal picked(string path)
    signal closed()
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    function open() { if (!files.length) Desktop.askMedia(); go(""); opacity = 1; forceActiveFocus() }
    function close() { opacity = 0; closed() }
    function go(path) {
        busy = true
        Api.call("library.browse", { path: path, files: picker.files }, function (ok, d) {
            picker.busy = false
            if (!ok) { toast.show((d && d.error) ? qsTranslate("core", d.error) : qsTr("Couldn't open that folder")); return }
            picker.view = d
            list.currentIndex = 0
            list.positionViewAtBeginning()
        })
    }
    function up() {
        if (view.path) go(view.parent || "")
        else close()
    }

    function placeName(f) {
        if (f.place === "home") return qsTr("Home folder")
        if (f.place === "storage") return qsTr("Internal storage")
        if (f.place === "videos") return f.name === "Movies" ? qsTr("Movies folder") : qsTr("Videos folder")
        if (f.place === "downloads") return qsTr("Downloads folder")
        return f.name
    }
    readonly property var lines: {
        var v = view, out = []
        if (v.path && !picker.files.length)
            out.push({ label: qsTr("Use this folder"), act: "use", value: qsTr("Add"),
                       detail: v.videos ? Theme.counted(qsTr("%n video(s) right here, and what's in the folders inside", "", v.videos), v.videos)
                                        : qsTr("With what's in the folders inside") })
        if (v.path)
            out.push({ label: qsTr("Up a folder"), act: "up", value: "‹",
                       detail: v.parent ? v.parent : picker.files.length ? qsTr("Back to where it may be") : qsTr("Back to where your videos may be") })
        ;(v.files || []).forEach(function (f) {
            out.push({ label: f.name, act: "file", path: f.path, value: qsTr("Open"), detail: "" })
        })
        ;(v.folders || []).forEach(function (f) {
            out.push({ label: picker.placeName(f), act: "open", path: f.path, value: "›",
                       detail: f.place === "drive" ? qsTr("Drive") + "  ·  " + f.label : f.place ? f.label : "" })
        })
        return out
    }
    function run(l) {
        if (!l || busy) return
        if (l.act === "use") { close(); picked(view.path) }
        else if (l.act === "file") { close(); picked(l.path) }
        else if (l.act === "up") up()
        else go(l.path)
    }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.AllButtons; onClicked: picker.close() }

    Column {
        anchors.centerIn: parent
        width: 1240 * picker.u
        spacing: 30 * picker.u
        scale: picker.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Text {
            text: picker.caption
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 26 * picker.u; weight: Font.Medium }
        }
        Column {
            width: parent.width
            spacing: 6 * picker.u
            Text {
                width: parent.width
                text: picker.view.path ? picker.view.name : picker.files.length ? qsTr("Where is it?") : qsTr("Where are your videos?")
                elide: Text.ElideRight
                color: Theme.fg
                font { family: Theme.display; pixelSize: 60 * picker.u; weight: Font.Bold }
            }
            Text {
                width: parent.width
                visible: !!picker.view.path
                text: picker.view.label || ""
                elide: Text.ElideMiddle
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 28 * picker.u }
            }
        }
        Item {
            width: parent.width
            height: Math.max(120 * picker.u, Math.min(640 * picker.u, list.contentHeight)) + 32 * picker.u
            Glass { anchors.fill: parent; kind: "panel"; radius: 40 * picker.u }
            // a click outside the list closes the sheet; on it, it doesn't
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
            ListView {
                id: list
                anchors { fill: parent; margins: 16 * picker.u }
                clip: true
                focus: true
                model: picker.lines
                keyNavigationEnabled: true
                highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
                preferredHighlightBegin: 2 * 92 * picker.u
                preferredHighlightEnd: height - 2 * 92 * picker.u
                highlightMoveDuration: 140
                highlightMoveVelocity: -1
                delegate: Toggle {
                    required property var modelData
                    required property int index
                    width: list.width
                    label: modelData.label
                    detail: modelData.detail || ""
                    value: modelData.value || ""
                    checkable: false
                    grow: 1
                    focused: list.currentIndex === index && picker.activeFocus
                    opacity: picker.busy ? 0.5 : 1
                    TapHandler { onTapped: { list.currentIndex = index; picker.run(modelData) } }
                }
                Text {
                    anchors.centerIn: parent
                    visible: !picker.busy && list.count === 0
                    text: picker.files.length ? qsTr("No folders or files here") : qsTr("No folders here")
                    color: Theme.fg3
                    font { family: Theme.text; pixelSize: 28 * picker.u }
                }
            }
        }
        Text {
            text: picker.files.length ? qsTr("OK opens a folder or the file, Back goes up") : qsTr("OK opens a folder, Back goes up")
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 24 * picker.u }
        }
    }

    Keys.onReturnPressed: run(lines[list.currentIndex])
    Keys.onEnterPressed: run(lines[list.currentIndex])
    Keys.onEscapePressed: up()
    Keys.onBackPressed: up()
    Keys.onPressed: function (e) { e.accepted = true }
}
