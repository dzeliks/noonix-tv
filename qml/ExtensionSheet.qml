import QtQuick

// an addon or extension: before it's added, exactly what it brings (addresses, keys it sends
// where, torrents, release patterns) with add / cancel; once it's in, the same lines with
// on / off, update and remove
FocusScope {
    id: sheet
    readonly property real u: Theme.u
    property var info: null
    property string mode: "preview"      // preview | extension | addon
    property bool busy: false
    property bool confirmRemove: false
    signal closed()
    signal installed(var result)
    signal changed()
    signal wantKey(string key)
    visible: opacity > 0
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    function preview(d) { info = d; mode = "preview"; show() }
    function manage(d, kind) { info = d; mode = kind; show() }
    function show() { busy = false; confirmRemove = false; row.currentIndex = 0; opacity = 1; forceActiveFocus() }
    function close() { opacity = 0; closed() }

    readonly property bool isAddon: mode === "addon" || (mode === "preview" && info && info.kind === "addon")
    readonly property var lines: {
        var d = info, out = []
        if (!d) return out
        if (d.description) out.push(d.description)
        if (isAddon) {
            var host = mode === "addon" ? d.address : (d.hosts || [])[0]
            out.push(qsTr("A Stremio addon at %1").arg(host || "?"))
            var res = (d.resources || []).map(function (r) {
                return { stream: qsTr("videos"), catalog: qsTr("catalogs"), meta: qsTr("details"), subtitles: qsTr("subtitles") }[r] || r
            })
            if (res.length) out.push(qsTr("Offers %1").arg(res.join(", ")))
            if (mode === "addon" && d.lastError) out.push(qsTr("Didn't answer last time"))
            if (mode === "addon" && d.formatting === "unsupported") out.push(qsTr("Its source names are hard to read: badges and the auto pick may be off"))
            return out
        }
        var n = mode === "preview" ? d.addons : d.listed
        if (n) out.push(Theme.counted(qsTr("Adds %n source(s) from %1", "", n), n).arg((d.hosts || []).join(", ") || d.source || ""))
        ;(d.keys || []).forEach(function (k) {
            var to = (k.hosts || []).join(", ")
            if (!k.set && k.bundled && mode === "preview") out.push(qsTr("Brings a %1 key, sent only to %2").arg(k.name).arg(to))
            else out.push(qsTr("Sends your %1 key to %2").arg(k.name).arg(to)
                          + (k.set || mode !== "preview" ? "" : "  ·  " + qsTr("you'll add the key next")))
        })
        if (d.torrents) out.push(qsTr("Its sources are torrents: they play only once you allow torrents"))
        var p = d.patterns || {}
        if ((p.preferred || []).length) out.push(qsTr("Prefers releases with %1").arg(p.preferred.join(", ")))
        if ((p.excluded || []).length) out.push(qsTr("Hides releases with %1").arg(p.excluded.join(", ")))
        var by = (d.version ? qsTr("Version %1").arg(d.version) : "") + (d.author ? (d.version ? "  ·  " : "") + qsTr("by %1").arg(d.author) : "")
        if (by) out.push(by)
        if (mode === "preview" && d.installed) out.push(qsTr("Replaces the version you have (%1)").arg(d.installedVersion || "?"))
        if (mode === "extension" && (d.missingKeys || []).length) out.push(qsTr("Not working yet: it needs your %1 key").arg(d.missingKeys[0].name))
        if (mode === "extension" && d.source) out.push(d.source === "file" ? qsTr("Added from a file") : qsTr("From %1").arg(d.source))
        return out
    }
    readonly property var buttons: {
        var d = info || {}
        if (mode === "preview")
            return [{ text: d.installed ? qsTr("Update") : qsTr("Add"), act: "install", primary: true }, { text: qsTr("Cancel"), act: "close" }]
        var out = []
        if (mode === "extension" && (d.missingKeys || []).length) out.push({ text: qsTr("Add Key"), act: "key", primary: true })
        out.push({ text: d.enabled ? qsTr("Turn Off") : qsTr("Turn On"), act: "toggle", primary: !out.length })
        if (mode === "extension" && d.updatable) out.push({ text: qsTr("Update"), act: "update" })
        out.push({ text: confirmRemove ? qsTr("Press Again to Remove") : qsTr("Remove"), act: "remove" })
        return out
    }

    function act(a) {
        if (busy) return
        var d = info
        if (a === "close") { close(); return }
        if (a === "key") { close(); wantKey(d.missingKeys[0].key); return }
        if (a === "install") {
            busy = true
            Api.call("extensions.install", { token: d.token }, function (ok, r) {
                sheet.busy = false
                if (!ok) { toast.show((r && r.error) ? qsTranslate("core", r.error) : qsTr("Couldn't add it")); return }
                sheet.close()
                sheet.installed(r)
            })
        } else if (a === "toggle") {
            busy = true
            var call = mode === "addon" ? ["addons.enable", { id: d.id, on: !d.enabled }] : ["extensions.enable", { id: d.id, on: !d.enabled }]
            Api.call(call[0], call[1], function () { sheet.busy = false; sheet.close(); sheet.changed() })
        } else if (a === "update") {
            busy = true
            Api.call("extensions.update", { id: d.id }, function (ok, r) {
                sheet.busy = false
                if (!ok) { toast.show((r && r.error) ? qsTranslate("core", r.error) : qsTr("Couldn't reach it")); return }
                sheet.preview(r)
            })
        } else if (a === "remove") {
            if (!confirmRemove) { confirmRemove = true; removeTimer.restart(); return }
            busy = true
            var rm = mode === "addon" ? ["addons.remove", { id: d.id }] : ["extensions.remove", { id: d.id }]
            Api.call(rm[0], rm[1], function () { sheet.busy = false; sheet.close(); sheet.changed() })
        }
    }
    Timer { id: removeTimer; interval: 4000; onTriggered: sheet.confirmRemove = false }

    Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
    Shield { onOutside: sheet.close() }

    Column {
        anchors.centerIn: parent
        width: 1240 * sheet.u
        spacing: 30 * sheet.u
        scale: sheet.opacity > 0.5 ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Text {
            text: sheet.mode === "preview" ? (sheet.isAddon ? qsTr("Add this addon?") : qsTr("Add this extension?")) : ""
            visible: text !== ""
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 26 * sheet.u; weight: Font.Medium }
        }
        Text {
            width: parent.width
            text: sheet.info ? sheet.info.name || "" : ""
            elide: Text.ElideRight
            color: Theme.fg
            font { family: Theme.display; pixelSize: 60 * sheet.u; weight: Font.Bold }
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
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    color: index === 0 && sheet.info && sheet.info.description ? Theme.fg : Theme.fg2
                    lineHeight: 1.12
                    font { family: Theme.text; pixelSize: 29 * sheet.u }
                }
            }
        }
        Text {
            width: parent.width
            visible: sheet.mode === "preview"
            text: qsTr("Noonix TV doesn't check what an addon or extension offers. Only add ones you trust, for videos you have the right to watch.")
            wrapMode: Text.Wrap
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 24 * sheet.u }
        }
        Item { width: 1; height: 4 * sheet.u }
        Row {
            id: row
            property int currentIndex: 0
            spacing: 24 * sheet.u
            Repeater {
                model: sheet.buttons
                GlassButton {
                    primary: !!modelData.primary
                    text: modelData.text
                    focused: sheet.activeFocus && row.currentIndex === index
                    pointerFocus: false
                    opacity: sheet.busy ? 0.5 : 1
                    onClicked: sheet.act(modelData.act)
                }
            }
        }
    }

    Keys.onReturnPressed: act(buttons[row.currentIndex].act)
    Keys.onEnterPressed: act(buttons[row.currentIndex].act)
    Keys.onLeftPressed: row.currentIndex = Math.max(0, row.currentIndex - 1)
    Keys.onRightPressed: row.currentIndex = Math.min(buttons.length - 1, row.currentIndex + 1)
    Keys.onEscapePressed: close()
    Keys.onBackPressed: close()
    Keys.onPressed: function (e) { e.accepted = true }
}
