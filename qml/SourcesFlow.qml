import QtQuick

// the library and the user's own sources, for setup's "your videos" step and settings › sources
// and accounts: the lines, what ok on them does, and the sheets and pickers they open. debrid
// keys and torrents only show up once something the user added asks for them
Item {
    id: flow
    property var lib: ({})
    property var addons: []
    property var exts: []
    property var acc: ({})
    property var tvs: ({})            // this computer as the tvs' streaming server
    property var entry: null          // the page's KeyEntry
    property var enterKey: null       // function (key): the page's key sheet
    property var pending: null        // a preview waiting for the entry sheet to close
    property string focusAct: ""      // the row of what was just added: the page focuses it
    property string removing: ""      // the folder whose remove waits for the second press
    Timer { id: removeTimer; interval: 4000; onTriggered: flow.removing = "" }
    signal changed()
    signal back()                     // a sheet closed: the page takes the focus again

    function load() {
        Api.call("library.status", {}, function (ok, d) { if (ok) flow.lib = d })
        Api.call("addons.list", {}, function (ok, d) { if (ok) flow.addons = d })
        Api.call("extensions.list", {}, function (ok, d) { if (ok) flow.exts = d })
        Api.call("setup.accounts", {}, function (ok, d) { if (ok) flow.acc = d })
        Api.call("tvServer.state", {}, function (ok, d) { if (ok) flow.tvs = d })
    }
    Connections {
        target: Api
        function onPushed(name, d) { if (name === "library" && d) flow.lib = d }
    }
    readonly property bool hasSources: (lib.folders || []).length > 0 || addons.length > 0

    // on this pc, then the addons and extensions
    readonly property var lines: {
        var out = [], l = lib || {}, on = l.on !== false, folders = l.folders || []
        out.push({ header: true, label: (Theme.android ? qsTr("On this device") : qsTr("On this PC")) })
        out.push({ label: qsTr("Use the library"), checkable: true, checked: on, act: "lib:on",
                   detail: !on ? qsTr("Off: only the sources below play")
                         : l.scanning ? qsTr("Looking through your folders…")
                         : !folders.length ? qsTr("Pick the folders your movies and shows are in")
                         : Theme.counted(qsTr("%n video(s) found", "", l.files || 0), l.files || 0) + (l.unmatched ? "  ·  " + qsTr("%n not recognized", "", l.unmatched) : "") })
        if (on) {
            folders.forEach(function (f) {
                var asked = flow.removing === f.path
                out.push({ label: f.label || f.path, value: asked ? qsTr("Press Again to Remove") : qsTr("Remove"), act: "lib:remove:" + f.path,
                           detail: asked ? qsTr("Takes it out of the library, the files stay")
                                         : Theme.counted(Theme.say(qsTr("%n video(s)  ·  OK takes it out of the library, the files stay", "", f.files), qsTr("%n video(s)  ·  tap to take it out of the library, the files stay", "", f.files), qsTr("%n video(s)  ·  click to take it out of the library, the files stay", "", f.files)), f.files) })
            })
            out.push({ label: qsTr("Add a folder"), detail: qsTr("Movies and shows, named the usual way: Show/Season 1/Show S01E02.mkv, Movie (2010).mkv"), value: "+", act: "lib:add" })
            if (folders.length)
                out.push({ label: qsTr("Look for new videos"), value: l.scanning ? "…" : qsTr("Scan"), act: "lib:scan",
                           detail: (l.unmatchedNames || []).length ? qsTr("Not recognized: %1").arg(l.unmatchedNames.join(", ")) : qsTr("Runs by itself every time Noonix TV opens") })
        }
        out.push({ header: true, label: qsTr("Addons and extensions") })
        exts.forEach(function (e) {
            var missing = (e.missingKeys || [])[0]
            out.push({ label: e.name, value: e.enabled ? "›" : qsTr("Off"), act: "ext:" + e.id,
                       detail: missing ? qsTr("Needs your %1 key").arg(missing.name)
                             : qsTr("Extension") + "  ·  " + Theme.counted(qsTr("%n source(s)", "", e.addons), e.addons) + (e.torrents ? "  ·  " + qsTr("torrents") : "") })
        })
        addons.forEach(function (a) {
            if (a.extension) return
            out.push({ label: a.name, value: a.enabled ? "›" : qsTr("Off"), act: "addon:" + a.id,
                       detail: a.address + (a.formatting === "unsupported" ? "  ·  " + qsTr("Unsupported formatting") : "") + (a.lastError ? "  ·  " + qsTr("Didn't answer last time") : "") })
        })
        out.push({ label: qsTr("Add an addon or extension"), detail: qsTr("Its address: a Stremio addon (…/manifest.json) or a Noonix TV extension. Optional"), value: "+", act: "src:url" })
        // android lets an app read only media files on shared storage: extensions come by address there
        if (!Theme.android)
            out.push({ label: qsTr("Open an extension file"), detail: qsTr("A .noonix file on this PC"), value: "+", act: "src:file" })
        return out
    }

    // the debrid services an extension asked for (or with a key from before)
    readonly property var debridLines: {
        var ds = (acc.debrids || []).filter(function (d) { return d.wanted || d.set }), out = []
        if (!ds.length) return out
        var site = { torbox: "torbox.app › Settings", realdebrid: "real-debrid.com/apitoken", alldebrid: "alldebrid.com › Account › API keys" }
        out.push({ header: true, label: qsTr("Debrid services") })
        ds.forEach(function (d) {
            out.push({ label: d.name, value: d.set ? qsTr("Change") : qsTr("Add"), act: "cred:" + d.key,
                       detail: d.set ? d.preview + (d.wanted ? "" : "  ·  " + qsTr("Nothing you added uses it now"))
                                     : qsTr("An extension of yours needs your key from %1").arg(site[d.id] || d.name) })
        })
        out.push({ label: qsTr("What's this?"), detail: qsTr("Debrid services in a few lines"), value: "?", act: "help:debrid" })
        return out
    }

    // torrents: once a source of the user's can answer with them, or they were decided before
    readonly property var torrentLines: {
        var t = acc.torrents || {}, out = []
        if (!t.wanted && (t.allowed === null || t.allowed === undefined)) return out
        out.push({ header: true, label: qsTr("Torrents") })
        out.push({ label: qsTr("Allow torrents"), checkable: true, checked: t.allowed === true, act: "torrents",
                   detail: qsTr("Download only, at your own risk. While it's off, torrent sources stay hidden") })
        out.push({ label: qsTr("What's this?"), detail: qsTr("Torrents in a few lines"), value: "?", act: "help:torrent" })
        // lg and samsung tvs stream torrents themselves; this computer can do it for them (more memory, a disk)
        if (t.allowed === true)
            out.push({ label: qsTr("Stream torrents to TVs"), checkable: true, checked: tvs.on === true, act: "tvserver",
                       detail: !tvs.on ? qsTr("Noonix TV on an LG or Samsung TV plays torrent sources through this device. Each TV asks here first")
                             : tvs.error ? qsTranslate("core", tvs.error)
                             : qsTr("On the TV: Settings › Streaming server › %1, while Noonix TV is open here. Only on a home network you trust").arg(tvs.address || "") })
        if (t.allowed === true && tvs.on === true && tvs.allowed > 0)
            out.push({ label: qsTr("Forget allowed TVs"), value: String(tvs.allowed), act: "tvforget",
                       detail: qsTr("Each TV asks again before it can use this device") })
        return out
    }

    // ok on one of the lines above; false = not ours
    function run(a) {
        if (a === "lib:on") {
            Api.call("library.setOn", { on: lib.on === false }, function (ok, d) { if (ok) flow.lib = d; flow.changed() })
        } else if (a === "lib:add") {
            folders.open()
        } else if (a.indexOf("lib:remove:") === 0) {
            // one press asks, the second takes it out
            if (removing !== a.slice(11)) { removing = a.slice(11); removeTimer.restart(); return true }
            removing = ""
            Api.call("library.removeFolder", { path: a.slice(11) }, function (ok, d) { if (ok) flow.lib = d; flow.changed() })
        } else if (a === "lib:scan") {
            var l = Object.assign({}, lib); l.scanning = true; lib = l
            Api.call("library.scan", {}, function (ok, d) { if (ok) flow.lib = d; flow.changed() })
        } else if (a.indexOf("ext:") === 0) {
            var e = exts.filter(function (x) { return x.id === a.slice(4) })[0]
            if (e) sheet.manage(e, "extension")
        } else if (a.indexOf("addon:") === 0) {
            var ad = addons.filter(function (x) { return String(x.id) === a.slice(6) })[0]
            if (ad) sheet.manage(ad, "addon")
        } else if (a === "src:url") {
            entry.open({ title: qsTr("Addon or extension address"), placeholder: "https://…",
                         hint: qsTr("A Stremio addon's address (…/manifest.json) or a Noonix TV extension's"),
                         check: function (v, reply) {
                             Api.call("extensions.preview", { url: v }, function (ok, d) {
                                 if (ok) flow.pending = d
                                 reply(ok, ok ? d.name : (d && d.error) ? qsTranslate("core", d.error) : qsTr("That address didn't answer"))
                             })
                         } })
            // after the entry sheet is gone (it hands the focus back first)
            entry.after = function () { Qt.callLater(function () { if (flow.pending) sheet.preview(flow.pending); flow.pending = null }) }
        } else if (a === "src:file") {
            filePick.open()
        } else if (a === "help:debrid") {
            help.open("debrid")
        } else if (a === "help:torrent") {
            help.open("torrent")
        } else if (a === "tvforget") {
            Api.call("tvServer.forget", {}, function (ok, d) { if (ok) flow.tvs = d; flow.changed() })
        } else if (a === "tvserver") {
            Api.call("tvServer.set", { on: tvs.on !== true }, function (ok, d) { if (ok) flow.tvs = d; flow.changed() })
        } else if (a === "torrents") {
            // yes goes through the sheet that says what it means; no right away
            if ((acc.torrents || {}).allowed === true) setTorrents(false)
            else help.ask()
        } else return false
        return true
    }
    function setTorrents(on) {
        Api.call("setup.torrents", { on: on }, function (ok, d) {
            if (ok) flow.acc = d
            Api.call("tvServer.state", {}, function (ok2, s) { if (ok2) flow.tvs = s; flow.changed() })
        })
    }

    // what to ask after an install: torrents first, then a missing key
    property var keyAfter: null
    function installed(r) {
        toast.show(qsTr("Added %1").arg(r.name || ""))
        focusAct = r.kind === "addon" ? "addon:" + r.id : "ext:" + r.id
        load()
        changed()
        var key = r.needKeys && r.needKeys.length ? r.needKeys[0].key : null
        if (r.torrents && (acc.torrents || {}).allowed !== true) { keyAfter = key; help.ask() }
        else if (key) enterKey(key)
        else back()
    }

    FolderPicker {
        id: folders
        anchors.fill: parent
        onPicked: function (path) {
            Api.call("library.addFolder", { path: path }, function (ok, d) {
                if (ok) flow.lib = d
                else toast.show((d && d.error) ? qsTranslate("core", d.error) : qsTr("Couldn't add that folder"))
                flow.changed()
            })
        }
        onClosed: flow.back()
    }
    FolderPicker {
        id: filePick
        anchors.fill: parent
        files: ["noonix", "json"]
        caption: qsTr("Open an extension file")
        onPicked: function (path) {
            Api.call("extensions.preview", { path: path }, function (ok, d) {
                if (ok) sheet.preview(d)
                else { toast.show((d && d.error) ? qsTranslate("core", d.error) : qsTr("Couldn't read that file")); flow.back() }
            })
        }
        onClosed: if (!sheet.visible) flow.back()
    }
    ExtensionSheet {
        id: sheet
        anchors.fill: parent
        onClosed: if (!help.visible && !(flow.entry && flow.entry.isOpen)) flow.back()
        onInstalled: function (r) { flow.installed(r) }
        onChanged: { flow.load(); flow.changed() }
        onWantKey: function (k) { flow.enterKey(k) }
    }
    SourcesHelp {
        id: help
        anchors.fill: parent
        onAnswered: function (yes) {
            flow.setTorrents(yes)
            var k = flow.keyAfter; flow.keyAfter = null
            if (k) Qt.callLater(function () { flow.enterKey(k) })
        }
        onClosed: if (!flow.keyAfter && !(flow.entry && flow.entry.isOpen)) flow.back()
    }
}
