import QtQuick

// a profile as a .noonix file: export shows what goes in (watch history and keys are choices) and
// saves it to the downloads folder; import shows what the file adds before the new profile is made
FocusScope {
    id: sheet
    readonly property real u: Theme.u
    property string mode: "export"       // export | import
    property var info: null              // profiles.exportSummary / profiles.importPreview
    property int profile: -1
    property bool watch: true
    property bool keys: false
    property bool busy: false
    property int index: 0                // the options, then the buttons' row
    property int button: 0
    signal closed()
    signal imported(var result)
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    function exportProfile(id) {
        profile = id; mode = "export"; watch = true; keys = false
        Api.call("profiles.exportSummary", { id: id }, function (ok, d) {
            if (!ok) { toast.show(qsTr("Couldn't read that profile")); sheet.closed(); return }
            sheet.info = d
            sheet.show()
        })
    }
    function importFile(path) {
        mode = "import"
        Api.call("profiles.importPreview", { path: path }, function (ok, d) {
            if (!ok) { toast.show((d && d.error) ? qsTranslate("core", d.error) : qsTr("Couldn't read that file")); sheet.closed(); return }
            sheet.info = d
            sheet.show()
        })
    }
    function show() { busy = false; index = 0; button = 0; opacity = 1; forceActiveFocus() }
    function close() { opacity = 0; closed() }

    function list(names) { return (names || []).map(function (n) { return qsTranslate("core", n) }).join(", ") }
    readonly property var lines: {
        var d = info, out = []
        if (!d) return out
        var langs = (d.languages || []).length ? qsTr("Audio: %1").arg(list(d.languages)) : ""
        if ((d.subtitles || []).length) langs += (langs ? "  ·  " : "") + qsTr("Subtitles: %1").arg(list(d.subtitles))
        if (langs) out.push(langs)
        var ext = (d.extensions || []).length, ad = (d.addons || []).length
        if (mode === "export") {
            if (ext) out.push(Theme.counted(qsTr("%n extension(s): %1", "", ext), ext).arg(d.extensions.join(", ")))
            if (ad) out.push(Theme.counted(qsTr("%n addon(s): %1", "", ad), ad).arg(d.addons.join(", ")))
            if (!ext && !ad) out.push(qsTr("No addons or extensions"))
        } else {
            if (ext) out.push(Theme.counted(qsTr("Adds %n extension(s): %1", "", ext), ext).arg(d.extensions.join(", ")))
            if (ad) out.push(Theme.counted(qsTr("Adds %n addon(s): %1", "", ad), ad).arg(d.addons.join(", ")))
            if (d.torrents) out.push(qsTr("Its sources are torrents: they play only once you allow torrents"))
        }
        if (d.patterns) out.push(Theme.counted(mode === "export" ? qsTr("%n release pattern(s)", "", d.patterns) : qsTr("Adds %n release pattern(s) to yours", "", d.patterns), d.patterns))
        if (mode === "import") {
            if ((d.keys || []).length) out.push(qsTr("Brings keys for %1").arg(d.keys.join(", ")))
            if ((d.keptKeys || []).length) out.push(qsTr("Keeps the keys here for %1").arg(d.keptKeys.join(", ")))
            var w = d.watch
            out.push(w ? Theme.counted(qsTr("With its watch history: %n title(s)", "", w.titles), w.titles)
                       : qsTr("Without watch history"))
        } else if (!keys && (d.keyedAddons || []).length) {
            var k = d.keyedAddons.length
            out.push(Theme.counted(qsTr("Leaves out %n address(es) that may hold a key: %1", "", k), k).arg(d.keyedAddons.join(", ")))
        }
        if (d.trakt) out.push(mode === "export" ? qsTr("Trakt stays here: sign in again on the other one") : qsTr("Sign in to Trakt again after adding it"))
        return out
    }
    // export's choices: toggles above the buttons
    readonly property var options: {
        var d = info, out = []
        if (!d || mode !== "export") return out
        var n = (d.watch || {}).titles || 0
        out.push({ id: "watch", label: qsTr("Watch history"), checked: watch,
                   detail: n ? Theme.counted(qsTr("Progress, history, watchlist and rated sources: %n title(s)", "", n), n) : qsTr("Progress, history, watchlist and rated sources") })
        if ((d.keys || []).length || (d.keyedAddons || []).length)
            out.push({ id: "keys", label: qsTr("Keys"), checked: keys,
                       detail: ((d.keys || []).length ? qsTr("Your keys for %1, and addresses with a key in them").arg(d.keys.join(", "))
                                                      : qsTr("Addresses with a key in them")) + ". " + qsTr("Anyone with the file can use them") })
        return out
    }
    readonly property var buttons: mode === "export"
        ? [{ text: qsTr("Save to Downloads"), act: "save", primary: true }, { text: qsTr("Cancel"), act: "close" }]
        : [{ text: qsTr("Add Profile"), act: "import", primary: true }, { text: qsTr("Cancel"), act: "close" }]

    function toggle(id) { if (id === "watch") watch = !watch; else if (id === "keys") keys = !keys }
    function act(a) {
        if (busy) return
        if (a === "close") { close(); return }
        busy = true
        if (a === "save") {
            Api.call("profiles.export", { id: profile, watch: watch, keys: keys }, function (ok, r) {
                sheet.busy = false
                if (!ok) { toast.show((r && r.error) ? qsTranslate("core", r.error) : qsTr("Couldn't save it")); return }
                toast.show(qsTr("Saved to Downloads as %1").arg(r.file))
                sheet.close()
            })
        } else if (a === "import") {
            Api.call("profiles.import", { token: info.token }, function (ok, r) {
                sheet.busy = false
                if (!ok) { toast.show((r && r.error) ? qsTranslate("core", r.error) : qsTr("Couldn't add it")); return }
                toast.show((r.failed || []).length ? qsTr("Added %1, without %2").arg(r.name).arg(r.failed.join(", ")) : qsTr("Added %1").arg(r.name))
                sheet.close()
                sheet.imported(r)
            })
        }
    }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: sheet.close() }

    Column {
        anchors.centerIn: parent
        width: 1240 * sheet.u
        spacing: 30 * sheet.u
        scale: sheet.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Text {
            text: sheet.mode === "export" ? qsTr("Export a profile") : qsTr("Add this profile?")
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 26 * sheet.u; weight: Font.Medium }
        }
        Row {
            spacing: 28 * sheet.u
            Avatar {
                id: face
                anchors.verticalCenter: parent.verticalCenter
                size: 96 * sheet.u
                colour: sheet.info ? sheet.info.color || "green" : "green"
                image: sheet.info ? sheet.info.image || "" : ""
                letter: sheet.info ? (sheet.info.name || "").trim().charAt(0).toUpperCase() : ""
            }
            Text {
                width: 1240 * sheet.u - face.width - 28 * sheet.u
                anchors.verticalCenter: parent.verticalCenter
                text: sheet.info ? sheet.info.name || "" : ""
                elide: Text.ElideRight
                color: Theme.fg
                font { family: Theme.display; pixelSize: 60 * sheet.u; weight: Font.Bold }
            }
        }
        Column {
            width: parent.width
            spacing: 14 * sheet.u
            Repeater {
                model: sheet.lines
                Text {
                    width: parent.width
                    text: modelData
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    color: Theme.fg2
                    lineHeight: 1.12
                    font { family: Theme.text; pixelSize: 29 * sheet.u }
                }
            }
        }
        Column {
            width: parent.width
            visible: sheet.options.length > 0
            spacing: 4 * sheet.u
            Repeater {
                model: sheet.options
                Toggle {
                    width: parent.width
                    label: modelData.label
                    detail: modelData.detail
                    checked: modelData.checked
                    grow: 1
                    focused: sheet.activeFocus && sheet.index === index
                    opacity: sheet.busy ? 0.5 : 1
                    TapHandler { onTapped: { sheet.index = index; sheet.toggle(modelData.id) } }
                }
            }
        }
        Text {
            width: parent.width
            visible: sheet.mode === "import" && !!sheet.info && ((sheet.info.extensions || []).length + (sheet.info.addons || []).length) > 0
            text: qsTr("Noonix TV doesn't check what an addon or extension offers. Only add ones you trust, for videos you have the right to watch.")
            wrapMode: Text.Wrap
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 24 * sheet.u }
        }
        Item { width: 1; height: 4 * sheet.u }
        Row {
            spacing: 24 * sheet.u
            Repeater {
                model: sheet.buttons
                GlassButton {
                    primary: !!modelData.primary
                    text: modelData.text
                    focused: sheet.activeFocus && sheet.index === sheet.options.length && sheet.button === index
                    pointerFocus: false
                    opacity: sheet.busy ? 0.5 : 1
                    onClicked: sheet.act(modelData.act)
                }
            }
        }
    }

    function ok() {
        if (index < options.length) toggle(options[index].id)
        else act(buttons[button].act)
    }
    Keys.onReturnPressed: ok()
    Keys.onEnterPressed: ok()
    Keys.onUpPressed: index = Math.max(0, index - 1)
    Keys.onDownPressed: index = Math.min(options.length, index + 1)
    Keys.onLeftPressed: if (index === options.length) button = Math.max(0, button - 1)
    Keys.onRightPressed: if (index === options.length) button = Math.min(buttons.length - 1, button + 1)
    Keys.onEscapePressed: close()
    Keys.onBackPressed: close()
    Keys.onPressed: function (e) { e.accepted = true }
}
