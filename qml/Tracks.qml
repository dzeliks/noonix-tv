import QtQuick

// subtitle or audio picker during playback: a small glass popover above the button that opened it
FocusScope {
    id: tr
    readonly property real u: Theme.u
    visible: false
    property string kind: "sub"          // sub | audio
    property real anchorX: Theme.margin  // left edge of the subtitles + audio buttons
    property real anchorW: 470 * u       // their width together
    signal closed()
    property string search: ""            // "" | searching | none | added | failed
    Connections {
        target: Player
        function onItemChanged() { tr.search = "" }
    }
    function searchSubs() {
        if (search === "searching") return
        search = "searching"
        Api.call("playback.searchSubs", {}, function (ok, d) {
            tr.search = !ok ? "failed" : d.count > 0 ? "added" : "none"
        })
    }
    function open(k, x, w) {
        kind = k || "sub"
        if (x !== undefined) anchorX = x
        if (w !== undefined && w > 0) anchorW = w
        visible = true
        list.currentIndex = firstSelected()
        list.remember()
        list.forceActiveFocus()
    }
    function close() { visible = false; closed() }
    function subKind(codec) {
        return codec === "hdmv_pgs_subtitle" || codec === "dvd_subtitle" || codec === "dvb_subtitle" ? qsTr("Image") : ""
    }
    function groupOf(name) {
        var m = /-([A-Za-z0-9]{2,})(\.[a-z]{2,4})?$/.exec(name || "")
        return m ? m[1] : ""
    }
    function audioFormat(t) {
        var c = { eac3: "Dolby Digital+", ac3: "Dolby Digital", truehd: "Dolby TrueHD", dts: "DTS", aac: "AAC", opus: "Opus", flac: "FLAC", mp3: "MP3" }[t.codec] || (t.codec || "").toUpperCase()
        var ch = t.channels === 8 ? "7.1" : t.channels === 6 ? "5.1" : t.channels === 2 ? qsTr("Stereo") : t.channels === 1 ? qsTr("Mono") : ""
        return [c, ch].filter(function (x) { return x }).join(" ")
    }
    readonly property var lines: {
        var out = [], seen = {}
        if (kind === "audio") {
            out.push({ header: true, label: qsTr("Audio") })
            Player.audioTracks.forEach(function (t) {
                var label = Theme.langName(t.lang)
                seen[label] = (seen[label] || 0) + 1
                out.push({ kind: "audio", id: t.id, label: seen[label] > 1 && !t.title ? label + " " + seen[label] : label,
                           detail: [t.title, tr.audioFormat(t)].filter(function (x) { return x }).join("  ·  "), selected: t.selected })
            })
            return out
        }
        out.push({ header: true, label: qsTr("Subtitles") })
        out.push({ kind: "sub", id: 0, label: qsTr("Off"), selected: !Player.subtitleTracks.some(function (t) { return t.selected }) })
        Player.subtitleTracks.forEach(function (t) {
            var label = Theme.langName(t.lang) + (t.forced ? " · " + qsTr("Forced") : t.sdh ? " · SDH" : "")
            // the same language twice without a title: number them
            seen[label] = (seen[label] || 0) + 1
            // an added one: where it's from and the release it was made for, not its file name
            var made = t.external ? tr.groupOf(t.title) : ""
            var detail = (t.external ? ["OpenSubtitles", made ? qsTr("made for %1").arg(made) : ""]
                                     : [t.title, tr.subKind(t.codec)]).filter(function (x) { return x }).join("  ·  ")
            out.push({ kind: "sub", id: t.id, label: seen[label] > 1 && !t.title ? label + " " + seen[label] : label, detail: detail, selected: t.selected })
        })
        out.push({ kind: "search", id: -1, label: qsTr("Search Subtitles"),
                   detail: { searching: qsTr("Looking on OpenSubtitles…"), none: qsTr("Nothing new for your languages"),
                             added: qsTr("Added to the list"), failed: qsTr("OpenSubtitles isn't answering") }[tr.search]
                           || qsTr("Your languages, from OpenSubtitles") })
        return out
    }
    // the panel fits its lines (toggle 84 / 108 with a detail, headers 84)
    readonly property real linesHeight: {
        var h = 0
        for (var i = 0; i < lines.length; ++i) h += lines[i].header ? 84 : lines[i].detail ? 108 : 84
        return h * u
    }
    function firstSelected() {
        for (var i = 0; i < lines.length; ++i) if (!lines[i].header && lines[i].selected) return i
        return 1
    }

    Keys.onEscapePressed: close()
    Keys.onBackPressed: close()

    Glass {
        id: panel
        kind: "panel"
        width: tr.anchorW
        x: tr.anchorX
        // bottom sits just above the osd's button row
        y: tr.height - 140 * tr.u - height
        height: Math.min(tr.height - 200 * tr.u, tr.linesHeight + 32 * tr.u)
        radius: 40 * tr.u
    }
    ListView {
        id: list
        // 16 all round: the rows' 24 radius + 16 = the panel's 40, corners stay concentric
        anchors { fill: panel; margins: 16 * tr.u }
        clip: true
        model: tr.lines
        // tracks arriving rebuild the list: stay on the same line
        property var keep: null
        function remember() { var l = tr.lines[currentIndex]; keep = l && !l.header ? l.kind + ":" + l.id : null }
        onModelChanged: {
            var k = keep
            for (var i = 0; i < tr.lines.length; ++i)
                if (!tr.lines[i].header && tr.lines[i].kind + ":" + tr.lines[i].id === k) {
                    currentIndex = i
                    Qt.callLater(function () { list.positionViewAtIndex(list.currentIndex, ListView.Contain) })
                    keep = k
                    return
                }
        }
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
        preferredHighlightBegin: 100 * tr.u
        preferredHighlightEnd: height - 120 * tr.u
        highlightMoveDuration: 160
        highlightMoveVelocity: -1
        Keys.onReturnPressed: {
            var l = tr.lines[currentIndex]
            if (!l || l.header) return
            if (l.kind === "search") tr.searchSubs()
            else if (l.kind === "sub") Player.setSubtitleTrack(l.id); else Player.setAudioTrack(l.id)
        }
        Keys.onUpPressed: function (e) { var i = currentIndex - 1; while (i >= 0 && tr.lines[i].header) i--; if (i >= 0) { currentIndex = i; remember() } }
        Keys.onDownPressed: function (e) { var i = currentIndex + 1; while (i < count && tr.lines[i].header) i++; if (i < count) { currentIndex = i; remember() } }
        delegate: Loader {
            required property var modelData
            required property int index
            width: list.width
            sourceComponent: modelData.header ? head : line
            Component {
                id: head
                Text {
                    height: 84 * tr.u
                    leftPadding: 30 * tr.u
                    bottomPadding: 22 * tr.u
                    verticalAlignment: Text.AlignBottom
                    text: modelData.label
                    color: Theme.fg2
                    font { family: Theme.display; pixelSize: 28 * tr.u; weight: Font.Bold }
                }
            }
            Component {
                id: line
                Toggle {
                    label: modelData.label
                    detail: modelData.detail || ""
                    checkable: false
                    grow: 1                     // a lift would eat the inset and crowd the corners
                    value: modelData.kind === "search" ? (tr.search === "searching" ? "…" : "›") : modelData.selected ? "✓" : ""
                    focused: list.currentIndex === index && list.activeFocus
                }
            }
        }
    }
}
