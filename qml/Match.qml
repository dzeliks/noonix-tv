import QtQuick

// "how's this match?" during playback: a small glass popover above the button that opened it.
// good remembers the source + subtitles; the three problems each come with their own fix
// (other subtitles, the timing, another source at the same spot)
FocusScope {
    id: sheet
    readonly property real u: Theme.u
    visible: false
    property real anchorX: Theme.margin
    property real anchorW: 560 * u
    property var info: null                // match.state: release, sub, marks
    readonly property bool subOn: !!(info && info.sub)
    signal closed()
    signal chosen(string what)             // good | sync | wrong | av | timing

    // shows once it knows what's playing: no empty header, no jump in size
    function open(x, w) {
        if (x !== undefined) anchorX = x
        if (w !== undefined && w > 0) anchorW = w
        Api.call("match.state", {}, function (ok, d) {
            // nothing playing any more (the end, an error): nothing to judge
            if (!ok) return
            sheet.info = d
            sheet.visible = true
            list.currentIndex = 0
            list.forceActiveFocus()
        })
    }
    function close() { visible = false; closed() }

    readonly property bool liked: !!info && info.releaseMark.verdict === 2 && (!subOn || info.subMark.verdict === 2)
    readonly property var lines: {
        var out = [{ id: "good", icon: "checkcircle", label: liked ? qsTr("Good match · saved") : qsTr("Good match"),
                     detail: subOn ? qsTr("Remember this source and subtitles") : qsTr("Remember this source") }]
        if (subOn) {
            out.push({ id: "sync", icon: "sync", label: qsTr("Subtitles out of sync"), detail: qsTr("Try others, then set the timing") })
            out.push({ id: "wrong", icon: "subtitles", label: qsTr("Wrong subtitles"), detail: qsTr("Another episode, language or cut") })
        }
        out.push({ id: "av", icon: "film", label: qsTr("Picture or sound problem"), detail: qsTr("Another source, from the same spot") })
        if (subOn)
            out.push({ id: "timing", icon: "sliders", label: qsTr("Subtitle timing"),
                       detail: Player.subDelay !== 0 ? Theme.signedSecs(Player.subDelay) + "  ·  " + (Player.subDelay > 0 ? qsTr("later") : qsTr("earlier")) : qsTr("Move them earlier or later") })
        return out
    }

    Keys.onEscapePressed: close()
    Keys.onBackPressed: close()

    // a finger needs less height than the tv's lift room
    readonly property real rowH: (Theme.touch ? 90 : 108) * u
    MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.LeftButton; onClicked: sheet.close() }
    Glass {
        id: panel
        kind: "panel"
        width: Math.max(sheet.anchorW, 540 * sheet.u)
        x: Math.min(sheet.anchorX, sheet.width - width - Theme.margin)
        // bottom sits just above the osd's button row, like the track picker
        y: sheet.height - 140 * sheet.u - height
        // a phone's short screen: never past the top, the lines scroll instead
        height: Math.min(head.height + sheet.lines.length * sheet.rowH + 44 * sheet.u, sheet.height - 180 * sheet.u)
        radius: 40 * sheet.u
    }
    MouseArea { anchors.fill: panel; hoverEnabled: true; acceptedButtons: Qt.AllButtons }
    // what's playing: the release, and the subtitle on screen
    Column {
        id: head
        x: panel.x + 46 * sheet.u
        y: panel.y + 30 * sheet.u
        width: panel.width - 92 * sheet.u
        spacing: 4 * sheet.u
        bottomPadding: 18 * sheet.u
        Text {
            text: qsTr("How's this one?")
            color: Theme.fg
            font { family: Theme.display; pixelSize: 30 * sheet.u; weight: Font.Bold }
        }
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: !sheet.info ? " " : sheet.info.release.label || qsTr("This source")
            color: Theme.fg2
            font { family: Theme.text; pixelSize: 21 * sheet.u; weight: Font.Medium }
        }
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: !sheet.info ? " " : !sheet.subOn ? qsTr("Subtitles off") : sheet.subLine(sheet.info.sub)
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 20 * sheet.u }
        }
    }
    ListView {
        id: list
        x: panel.x + 16 * sheet.u
        y: head.y + head.height
        width: panel.width - 32 * sheet.u
        height: panel.y + panel.height - 28 * sheet.u - y
        clip: contentHeight > height + 1
        interactive: clip
        model: sheet.lines.length
        keyNavigationEnabled: true
        highlightMoveDuration: 0
        Keys.onReturnPressed: sheet.pick(currentIndex)
        Keys.onEnterPressed: sheet.pick(currentIndex)
        delegate: Item {
            id: line
            required property int index
            readonly property var l: sheet.lines[index] || ({})
            readonly property bool foc: ListView.isCurrentItem && Theme.lit(list.activeFocus, lp)
            width: list.width
            height: sheet.rowH
            Rectangle {
                anchors.fill: parent
                radius: 24 * sheet.u
                color: line.foc ? "white" : "transparent"
            }
            Symbol {
                id: ic
                anchors { left: parent.left; leftMargin: 30 * sheet.u; verticalCenter: parent.verticalCenter }
                width: 36 * sheet.u; height: width
                name: line.l.icon || ""
                weight: 1.8
                color: line.foc ? Theme.focusFg : line.l.id === "good" && sheet.liked ? Theme.accent : Theme.fg
            }
            Column {
                anchors { left: ic.right; leftMargin: 24 * sheet.u; right: parent.right; rightMargin: 30 * sheet.u; verticalCenter: parent.verticalCenter }
                spacing: 4 * sheet.u
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: line.l.label || ""
                    color: line.foc ? Theme.focusFg : Theme.fg
                    font { family: Theme.text; pixelSize: 26 * sheet.u; weight: Font.Medium }
                }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: line.l.detail || ""
                    color: line.foc ? Qt.rgba(0.1, 0.1, 0.12, 0.6) : Theme.fg3
                    font { family: Theme.text; pixelSize: 20 * sheet.u }
                }
            }
            Pointer {
                id: lp
                okKey: false
                onPointed: { list.currentIndex = line.index; list.forceActiveFocus() }
                onTapped: sheet.pick(line.index)
            }
        }
    }
    // "English · SDH · In the file", "Serbian · OpenSubtitles · made for KILLERS"
    function subLine(s) {
        var lang = Theme.langName(s.lang), parts = [lang]
        if (s.embedded) {
            if (s.name && s.name.toLowerCase().indexOf(lang.toLowerCase()) < 0) parts.push(s.name)
            parts.push(qsTr("In the file"))
        } else {
            parts.push(s.provider === "file" ? qsTr("Added") : "OpenSubtitles")
            if (s.group) parts.push(qsTr("made for %1").arg(s.group))
        }
        return parts.join("  ·  ")
    }
    function pick(i) {
        var l = lines[i]
        if (!l) return
        close()
        chosen(l.id)
    }
}
