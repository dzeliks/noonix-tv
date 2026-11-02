import QtQuick

// every source for one title, ranked, filling in while the addons answer
FocusScope {
    id: sheet
    property var target: null          // {kind, tmdb, season?, episode?}
    property string title: ""
    property var streams: []
    property var addons: []
    property int total: 0
    property int hidden: 0
    property int torrents: 0                // torrents left out: not allowed (yet)
    property var torrentsAllowed: null
    property bool done: false
    property string req: ""
    property bool showTemplate: false
    property var template: null
    // found but not in the list: past the best ones, or left out by the rules (cam, 3D, too big, hidden words)
    readonly property int filteredOut: Math.max(0, total - streams.length) + Math.max(0, hidden - torrents)
    readonly property real u: Theme.u
    readonly property var unsupported: addons.filter(function (a) { return a.formatting === "unsupported" })
    // up from the list: the addon chips; ok on one shows only its sources (ok again: all)
    property string only: ""
    readonly property var shown: only ? streams.filter(function (x) { return x.addon === only }) : streams
    // the list holds keys: what arrives fades in, what moves in the ranking slides, the selection stays
    ListModel { id: rowsModel }
    property var byKey: ({})
    function keyOf(x) { return [x.addon, x.url || "", x.infoHash || "", x.fileIdx === undefined ? "" : x.fileIdx, x.filename || x.title || ""].join("|") }
    onShownChanged: syncRows()
    function syncRows() {
        var m = byKey, want = [], used = {}, count = {}, i, list0 = list.currentIndex === 0
        for (i = 0; i < shown.length; ++i) {
            var k = keyOf(shown[i]), n = count[k] || 0
            count[k] = n + 1
            var id = n ? k + "#" + n : k
            m[id] = shown[i]
            want.push(id)
            used[id] = true
        }
        byKey = m
        for (i = rowsModel.count - 1; i >= 0; --i) if (!used[rowsModel.get(i).rowKey]) rowsModel.remove(i)
        for (i = 0; i < want.length; ++i) {
            if (i < rowsModel.count && rowsModel.get(i).rowKey === want[i]) continue
            var from = -1
            for (var j = i + 1; j < rowsModel.count && from < 0; ++j) if (rowsModel.get(j).rowKey === want[i]) from = j
            if (from >= 0) rowsModel.move(from, i, 1)
            else rowsModel.insert(i, { rowKey: want[i] })
        }
        // nobody moved yet: the top stays the top as better ones come in
        if (list0) list.currentIndex = 0
    }
    property int chip: 0
    property int hoverChip: -1
    // several addons: an All tab first, and it's the one on
    readonly property var tabs: addons.length > 1 ? [{ name: "", all: true, state: "done", count: streams.length }].concat(addons) : addons
    signal pick(var stream)
    signal closed()

    function start(t, label) {
        target = t; title = label || ""
        rowsModel.clear(); byKey = ({})
        streams = []; addons = []; total = 0; hidden = 0; torrents = 0; done = false; showTemplate = false; only = ""; chip = 0
        req = "src-" + Date.now()
        list.forceActiveFocus()
        Api.call("streams.list", Object.assign({ req: req }, t), function (ok, d) {
            if (!ok) { sheet.done = true; return }
            if (d.req !== sheet.req) return
            sheet.apply(d)
        })
    }
    function apply(d) {
        streams = d.streams || []
        addons = d.addons || []
        total = d.total || streams.length
        hidden = d.hidden || 0
        torrents = d.torrents || 0
        torrentsAllowed = d.torrentsAllowed === undefined ? null : d.torrentsAllowed
        done = !!d.done
    }
    Connections {
        target: Api
        function onPushed(name, d) { if (name === "streams" && d && d.req === sheet.req) sheet.apply(d) }
    }
    // a source of the user's answered with torrents and they were never asked: ask once
    readonly property bool askTorrents: torrents > 0 && torrentsAllowed === null
    function warnText(w) { return w === "level" ? qsTr("May not play smoothly here") : w === "seeders" ? qsTr("Few people sharing") : "" }
    function resLabel(r) { return r >= 2160 ? "4K" : r >= 1440 ? "1440p" : r > 0 ? r + "p" : "?" }
    function gb(b) { return !b ? "" : b < 1e9 ? Math.max(1, Math.round(b / 1e6)) + " MB" : (b / 1e9).toFixed(b >= 1e10 ? 0 : 1) + " GB" }

    // beside the panel: closes it, nothing behind it reacts
    Shield { onOutside: sheet.close() }
    Glass {
        id: panel
        kind: "panel"
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom; margins: 40 * sheet.u }
        width: parent.width * 0.5
        radius: 56 * sheet.u
    }

    MouseArea { anchors.fill: panel; hoverEnabled: true; acceptedButtons: Qt.AllButtons }

    Column {
        id: head
        anchors { left: panel.left; right: panel.right; top: panel.top; margins: 56 * sheet.u }
        spacing: 14 * sheet.u
        Text {
            text: qsTr("Sources")
            color: Theme.fg
            font { family: Theme.display; pixelSize: 46 * sheet.u; weight: Font.Bold }
        }
        Text {
            width: parent.width
            text: sheet.title
            color: Theme.fg2
            elide: Text.ElideRight
            font { family: Theme.text; pixelSize: 25 * sheet.u }
        }
        // one chip per addon: answering / count / error
        Flow {
            id: chips
            width: parent.width
            spacing: 12 * sheet.u
            Keys.onLeftPressed: sheet.chip = Math.max(0, sheet.chip - 1)
            Keys.onRightPressed: sheet.chip = Math.min(sheet.tabs.length - 1, sheet.chip + 1)
            Keys.onDownPressed: (sheet.askTorrents ? torrentBtn : sheet.unsupported.length ? advanced : list).forceActiveFocus()
            Keys.onReturnPressed: {
                // picking a tab leaves the focus on the tabs: the first source lights up when you go down to it
                var a = sheet.tabs[sheet.chip]
                if (!a) return
                if (sheet.addons.length > 1) sheet.only = a.all ? "" : a.name
                list.currentIndex = 0
                list.positionViewAtBeginning()
            }
            Repeater {
                model: sheet.tabs.length
                Rectangle {
                    id: chipItem
                    required property int index
                    readonly property var modelData: sheet.tabs[index] || ({})
                    // with the mouse about only the tab under it is lit
                    readonly property bool foc: chips.activeFocus && sheet.chip === index && (!Input.pointing || sheet.hoverChip === index)
                    readonly property bool on: sheet.addons.length > 1 ? (modelData.all ? sheet.only === "" : sheet.only === modelData.name) : false
                    height: 44 * sheet.u
                    width: chipRow.implicitWidth + 32 * sheet.u
                    radius: height / 2
                    color: foc ? "white" : on ? Qt.rgba(1, 1, 1, 0.32) : modelData.state === "error" ? Qt.rgba(1, 0.3, 0.35, 0.22) : Qt.rgba(1, 1, 1, 0.1)
                    border.width: on && !foc ? 2 * sheet.u : 0
                    border.color: "white"
                    scale: foc ? 1.06 : 1
                    Behavior on scale { NumberAnimation { duration: 140 } }
                    Pointer {
                        okKey: false
                        onContainsMouseChanged: {
                            if (containsMouse) sheet.hoverChip = chipItem.index
                            else if (sheet.hoverChip === chipItem.index) sheet.hoverChip = -1
                        }
                        onPointed: { sheet.chip = chipItem.index; chips.forceActiveFocus() }
                        onTapped: { sheet.chip = chipItem.index; chips.forceActiveFocus(); Remote.pointerKey("OK") }
                    }
                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 10 * sheet.u
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: (modelData.all ? qsTr("All") : modelData.name) + (modelData.state === "loading" ? "" : "  " + (modelData.state === "error" ? qsTr("no answer") : modelData.count))
                            color: chipItem.foc ? Theme.focusFg : chipItem.on ? Theme.fg : Theme.fg2
                            font { family: Theme.text; pixelSize: 20 * sheet.u; weight: Font.Medium }
                        }
                        Spinner {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: modelData.state === "loading" && sheet.addons.length > 1
                            running: visible && sheet.visible
                            color: chipItem.foc ? Theme.focusFg : Theme.fg2
                            width: 20 * sheet.u; height: width
                        }
                    }
                }
            }
        }
        // torrents found, never decided: what they are, then yes or no
        Item {
            visible: sheet.askTorrents
            width: parent.width
            height: visible ? 64 * sheet.u : 0
            Text {
                anchors { left: parent.left; right: torrentBtn.left; rightMargin: 16 * sheet.u; verticalCenter: parent.verticalCenter }
                text: Theme.counted(qsTr("%n torrent source(s) hidden", "", sheet.torrents), sheet.torrents)
                elide: Text.ElideRight
                color: Theme.fg2
                font { family: Theme.text; pixelSize: 23 * sheet.u; weight: Font.DemiBold }
            }
            GlassButton {
                id: torrentBtn
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                height: 60 * sheet.u
                text: qsTr("Torrents?")
                onClicked: torrentHelp.ask()
                Keys.onDownPressed: (sheet.unsupported.length ? advanced : list).forceActiveFocus()
                Keys.onUpPressed: if (sheet.addons.length > 1) chips.forceActiveFocus()
            }
        }
        // a custom manifest whose stream text noonix tv can't read
        Item {
            visible: sheet.unsupported.length > 0
            width: parent.width
            height: visible ? 64 * sheet.u : 0
            Text {
                anchors { left: parent.left; right: advanced.left; rightMargin: 24 * sheet.u; verticalCenter: parent.verticalCenter }
                elide: Text.ElideRight
                text: qsTr("Unsupported formatting") + (sheet.unsupported.length ? "  ·  " + sheet.unsupported.map(function (a) { return a.name }).join(", ") : "")
                color: Theme.cached
                font { family: Theme.text; pixelSize: 23 * sheet.u; weight: Font.DemiBold }
            }
            GlassButton {
                id: advanced
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                height: 60 * sheet.u
                text: qsTr("Advanced")
                onClicked: {
                    sheet.showTemplate = !sheet.showTemplate
                    if (sheet.showTemplate && !sheet.template)
                        Api.call("addons.formatter", {}, function (ok, d) { if (ok) sheet.template = d })
                }
                Keys.onDownPressed: (sheet.showTemplate ? copyBtn : list).forceActiveFocus()
                Keys.onUpPressed: (sheet.askTorrents ? torrentBtn : sheet.addons.length > 1 ? chips : advanced).forceActiveFocus()
            }
        }
        // the template to paste into aiostreams > formatter > custom
        Rectangle {
            visible: sheet.showTemplate
            width: parent.width
            height: visible ? tpl.height + 120 * sheet.u : 0
            radius: 24 * sheet.u
            color: Qt.rgba(0, 0, 0, 0.35)
            Column {
                id: tpl
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 24 * sheet.u }
                spacing: 10 * sheet.u
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.fg2
                    font { family: Theme.text; pixelSize: 20 * sheet.u }
                    text: qsTr("In AIOStreams open Formatter, choose Custom and paste these as Name and Description. Noonix TV then reads every detail exactly.")
                }
                Text {
                    width: parent.width
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 6
                    elide: Text.ElideRight
                    color: Theme.fg
                    font { family: "monospace"; pixelSize: 17 * sheet.u }
                    text: sheet.template ? sheet.template.name + "\n" + sheet.template.description : "…"
                }
            }
            GlassButton {
                id: copyBtn
                anchors { right: parent.right; bottom: parent.bottom; margins: 18 * sheet.u }
                height: 56 * sheet.u
                icon: "copy"
                text: qsTr("Copy")
                onClicked: if (sheet.template) {
                    Desktop.copy(JSON.stringify(sheet.template, null, 2))
                    text = qsTr("Copied")
                }
                Keys.onUpPressed: advanced.forceActiveFocus()
                Keys.onDownPressed: list.forceActiveFocus()
            }
        }
    }

    ListWheel { view: list }
    ListView {
        id: list
        anchors { left: panel.left; right: panel.right; top: head.bottom; bottom: panel.bottom; topMargin: 24 * sheet.u; bottomMargin: 30 * sheet.u }
        clip: true
        focus: true
        topMargin: 8 * sheet.u
        model: rowsModel
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 320; easing.type: Easing.OutCubic } }
        remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 160 } }
        displaced: Transition { NumberAnimation { property: "y"; duration: 280; easing.type: Easing.OutCubic } }
        move: Transition { NumberAnimation { property: "y"; duration: 280; easing.type: Easing.OutCubic } }
        spacing: 10 * sheet.u
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
        preferredHighlightBegin: 120 * sheet.u
        preferredHighlightEnd: height - 160 * sheet.u
        highlightMoveDuration: 260
        highlightMoveVelocity: -1
        cacheBuffer: 600 * sheet.u
        Keys.onUpPressed: function (e) {
            if (currentIndex > 0) decrementCurrentIndex()
            else if (sheet.unsupported.length) (sheet.showTemplate ? copyBtn : advanced).forceActiveFocus()
            else if (sheet.askTorrents) torrentBtn.forceActiveFocus()
            else if (sheet.addons.length > 1) chips.forceActiveFocus()
        }
        Keys.onReturnPressed: if (sheet.shown.length) sheet.pick(sheet.shown[currentIndex])
        delegate: Item {
            id: rowItem
            required property int index
            required property string rowKey
            readonly property bool foc: ListView.isCurrentItem && list.activeFocus
            readonly property var s: sheet.byKey[rowKey] || ({})
            width: list.width
            height: 116 * sheet.u
            Pointer { okKey: false; onTapped: if (rowItem.s.addon !== undefined) sheet.pick(rowItem.s) }
            Rectangle {
                anchors { fill: parent; leftMargin: 28 * sheet.u; rightMargin: 28 * sheet.u }
                radius: 26 * sheet.u
                color: rowItem.foc ? "white" : "transparent"
                scale: rowItem.foc ? 1.02 : 1
                Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
                Row {
                    id: badges
                    anchors { left: parent.left; leftMargin: 26 * sheet.u; verticalCenter: parent.verticalCenter }
                    spacing: 8 * sheet.u
                    width: 210 * sheet.u
                    Badge { text: sheet.resLabel(rowItem.s.resolution); strong: true; onLight: rowItem.foc; tint: rowItem.foc ? Theme.accent : "white" }
                    Repeater {
                        model: (rowItem.s.hdr || []).filter(function (h) { return h !== "SDR" })
                        Badge { required property var modelData; text: modelData; onLight: rowItem.foc }
                    }
                }
                Column {
                    anchors { left: badges.right; leftMargin: 16 * sheet.u; right: tail.left; rightMargin: 16 * sheet.u; verticalCenter: parent.verticalCenter }
                    spacing: 6 * sheet.u
                    Text {
                        width: parent.width
                        text: rowItem.s.filename || rowItem.s.title
                        elide: Text.ElideMiddle
                        color: rowItem.foc ? Theme.focusFg : Theme.fg
                        font { family: Theme.text; pixelSize: 23 * sheet.u; weight: Font.Medium }
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        color: rowItem.foc ? Qt.rgba(0.1, 0.1, 0.12, 0.7) : Theme.fg3
                        font { family: Theme.text; pixelSize: 20 * sheet.u }
                        text: [rowItem.s.codec, (rowItem.s.audio || []).slice(0, 2).join(" "), rowItem.s.channels, sheet.gb(rowItem.s.size),
                               rowItem.s.group, rowItem.s.local ? (Theme.android ? qsTr("This device") : qsTranslate("core", "This PC")) : rowItem.s.addon].filter(function (x) { return x }).join("  ·  ")
                    }
                }
                Row {
                    id: tail
                    anchors { right: parent.right; rightMargin: 26 * sheet.u; verticalCenter: parent.verticalCenter }
                    spacing: 8 * sheet.u
                    // may stutter here (above the picture quality level, few people sharing)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!rowItem.s.warn
                        text: sheet.warnText(rowItem.s.warn)
                        color: rowItem.foc ? "#B45309" : "#FFB340"
                        font { family: Theme.text; pixelSize: 19 * sheet.u; weight: Font.DemiBold }
                    }
                    // a torrent: how many people share it, when the addon says
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !rowItem.s.url && !rowItem.s.local
                        text: !visible ? "" : rowItem.s.seeders !== null && rowItem.s.seeders !== undefined ? qsTr("%1 sharing").arg(rowItem.s.seeders) : qsTr("Torrent")
                        color: rowItem.foc ? Theme.focusFg : Theme.fg2
                        font { family: Theme.text; pixelSize: 20 * sheet.u; weight: Font.DemiBold }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: rowItem.s.service || ""
                        color: rowItem.foc ? Theme.focusFg : Theme.fg2
                        font { family: Theme.text; pixelSize: 20 * sheet.u; weight: Font.Bold }
                    }
                    Symbol {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 30 * sheet.u; height: width
                        visible: rowItem.s.cached !== null && rowItem.s.cached !== undefined
                        name: rowItem.s.cached ? "bolt" : "hourglass"
                        color: rowItem.s.cached ? (rowItem.foc ? "#C79A00" : Theme.cached) : (rowItem.foc ? Theme.focusFg : Theme.fg3)
                    }
                }
            }
        }
        footer: Item {
            width: list.width
            height: 80 * sheet.u
            Row {
                anchors.centerIn: parent
                spacing: 14 * sheet.u
                Spinner {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !sheet.done && sheet.shown.length > 0
                    running: visible && sheet.visible
                    color: Theme.fg3
                    width: 24 * sheet.u; height: width
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.fg3
                    font { family: Theme.text; pixelSize: 20 * sheet.u }
                    text: !sheet.done ? (sheet.shown.length ? qsTr("Looking for more sources") : "")
                        : sheet.streams.length === 0 && !sheet.addons.length ? qsTr("Nothing here yet: add a video folder or a source in Settings › Sources")
                        : sheet.streams.length === 0 && !sheet.torrents ? qsTr("No sources found")
                        : qsTr("%1 shown").arg(sheet.shown.length)
                          + (sheet.filteredOut > 0 && !sheet.only ? "  ·  " + qsTr("%1 filtered out (lower ranked, cam, 3D, too big or your hidden patterns)").arg(sheet.filteredOut) : "")
                          + (sheet.torrents && sheet.torrentsAllowed === false ? "  ·  " + qsTr("%1 torrents (off in Settings › Sources)").arg(sheet.torrents) : "")
                }
            }
        }
    }

    // nothing in yet: one spinner in the middle of the list
    Spinner {
        x: list.x + (list.width - width) / 2
        y: list.y + (list.height - height) / 2 - 20 * sheet.u
        width: 56 * sheet.u; height: width
        color: Theme.fg2
        opacity: !sheet.done && sheet.shown.length === 0 ? 1 : 0
        visible: opacity > 0
        running: visible && sheet.visible
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    SourcesHelp {
        id: torrentHelp
        parent: win.sheetLayer
        anchors.fill: parent
        onAnswered: function (yes) {
            Api.call("setup.torrents", { on: yes }, function () { if (sheet.target) sheet.start(sheet.target, sheet.title) })
        }
        onClosed: list.forceActiveFocus()
    }
}
