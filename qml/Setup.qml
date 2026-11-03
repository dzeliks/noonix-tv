import QtQuick
import QtQuick.Effects

// first run (and settings › about): a few calm steps over the app itself, blurred in a window
// in the middle; when it's done that window zooms in and comes into focus.
// every step works with the remote alone: up/down through the lines, ok on a line, down to
// continue
FocusScope {
    id: setup
    readonly property real u: Theme.u
    property int step: 0
    property var info: null                  // setup.state
    property var app: ({})
    property var code: null                  // trakt device code being shown
    property int codeProfile: 0
    property bool busy: false
    property var langs: ({ languages: ["en", "original"], subtitles: ["en"] })
    property var langOptions: null
    // the languages' order as the step opened (the chosen ones first): a line doesn't jump away
    // from the focus while it's ticked
    property var langSnap: null
    onStepChanged: langSnap = { languages: langs.languages.slice(), subtitles: langs.subtitles.slice() }
    property var quality: null               // quality.options
    // termsOnly: set up before, the terms are new (or changed): just them
    property bool termsOnly: false
    readonly property var steps: termsOnly ? ["terms"] : ["language", "welcome", "terms", "profiles", "videos", "trakt", "audio", "subtitles"].concat(Theme.android ? [] : ["background", "playback"], ["benchmark", "quality", "done"])
    readonly property var acc: (info && info.accounts) || ({})
    // what still keeps the app from working (the done step says it instead of "all set")
    readonly property var gaps: {
        var g = []
        if (acc.tmdb && !acc.tmdb.set) g.push(qsTr("Home stays empty without a TMDB key (Your videos step)"))
        if (!flow.hasSources) g.push(qsTr("Nothing to play yet: pick a video folder or add a source (Your videos step)"))
        var missing = (acc.debrids || []).filter(function (d) { return d.wanted && !d.set })[0]
        if (missing) g.push(qsTr("An extension still needs your %1 key (Your videos step)").arg(missing.name))
        return g
    }
    readonly property string name: steps[step]
    signal finished()
    visible: false

    function open(onlyTerms) {
        termsOnly = !!onlyTerms
        step = 0
        pane.opacity = 1; shift.x = 0
        frame.reveal = 0
        visible = true
        refresh()
        Api.call("sources.prefs", {}, function (ok, d) { if (ok) setup.langs = { languages: d.languages, subtitles: d.subtitles } })
        Api.call("languages.options", {}, function (ok, d) { if (ok) setup.langOptions = d })
        continueBtn.forceActiveFocus()
    }
    // balkan mode for the whole install; on = "balkan" in the subtitle languages
    function balkan(on) {
        Api.call("setup.setBalkan", { on: on }, function () {
            setup.refresh()
            Api.call("languages.options", {}, function (ok, d) { if (ok) setup.langOptions = d })
            Api.call("sources.prefs", {}, function (ok, d) { if (ok) setup.langs = { languages: d.languages, subtitles: d.subtitles } })
        })
    }
    function toggleLang(list, code) {
        var l = langs[list].slice(), i = l.indexOf(code)
        if (i >= 0) { if (l.length > 1) l.splice(i, 1) } else l.push(code)
        var n = Object.assign({}, langs); n[list] = l; langs = n
    }
    function firstLine() {
        for (var i = 0; i < lines.length; ++i) if (!lines[i].header) return i
        return 0
    }
    // up from the buttons: the line just above them, or where the focus was in the list
    function enterList() {
        if (!lines.length) return
        if (keepIndex < 0) {
            var i = lines.length - 1
            while (i > 0 && lines[i].header) i--
            list.currentIndex = i
            keepIndex = i
        }
        list.forceActiveFocus()
    }
    function refresh() {
        Api.call("setup.state", {}, function (ok, d) { if (ok) setup.info = d })
        flow.load()
        Api.call("settings.app", {}, function (ok, d) { if (ok) setup.app = d })
    }
    function appOn(k) { return app[k] !== false }
    function setApp(k, v) {
        var a = Object.assign({}, app); a[k] = v; app = a
        Api.call("settings.setApp", { key: k, value: v })
    }
    function modeName(m) {
        return m === "own" ? qsTr("Signed in") : info && info.traktRelogin ? qsTr("Sign in once more: Trakt now connects through Noonix TV itself") : qsTr("Not signed in")
    }

    readonly property var title: ({
        language: qsTr("Choose your language"),
        welcome: qsTr("Welcome to Noonix TV"), profiles: qsTr("Who watches here?"),
        terms: qsTr("Before you start"), videos: qsTr("Your videos"), trakt: qsTr("Trakt"), audio: qsTr("Audio languages"), subtitles: qsTr("Subtitles"), background: qsTr("Stay signed in"),
        playback: (Theme.android ? qsTr("This device") : qsTr("This PC")), benchmark: qsTr("Speed check"), quality: qsTr("Picture quality"), done: qsTr("You're all set")
    })
    readonly property var blurb: ({
        language: qsTr("You can change it any time in Settings."),
        welcome: qsTr("Your own movies and shows, and the sources you add, on this TV. A few steps and you're watching."),
        terms: qsTr("Please read this, then agree to go on."),
        profiles: qsTr("Everyone gets their own Up Next, progress and language choices."),
        videos: (Theme.android ? qsTr("Noonix TV plays the videos on this device and the sources you add yourself. Pick the folders your movies and shows are in; an addon or extension is optional.") : qsTr("Noonix TV plays the videos on this PC and the sources you add yourself. Pick the folders your movies and shows are in; an addon or extension is optional.")),
        trakt: qsTr("Optional: Trakt keeps what you watched in sync. OK on a profile signs it in or out, or skip it for now."),
        audio: qsTr("The languages you like to hear, best first. Noonix TV picks the audio track in this order. Right jumps to Continue."),
        subtitles: qsTr("Subtitle languages, best first. Noonix TV turns on the first one a video has and can find the ones it doesn't. Right jumps to Continue."),
        background: qsTr("Logins expire when nothing uses them for a while. Noonix TV can check them once a day."),
        playback: qsTr("These can be changed any time in Settings."),
        benchmark: qsTr("How fast this internet connection and this device are. The next step picks a picture quality from it."),
        quality: qsTr("Picked from the speed check. Higher ones may stutter here, lower ones always play smoothly. Sources above it still show, last and marked. You can change it in Settings."),
        done: gaps.length ? qsTr("Almost there. You can start now and add the rest later in Settings.") : qsTr("That's everything. You can change any of it later in Settings.")
    })

    // the step's lines: {label, detail, value, checkable, checked, act}
    readonly property var lines: {
        var out = [], s = info
        if (!s) return out
        if (name === "language") {
            // each in its own words, never translated
            out.push({ label: "English", checkable: true, checked: Desktop.language === "en", act: "uilang:en" })
            out.push({ label: "Srpski", checkable: true, checked: Desktop.language === "sr", act: "uilang:sr" })
        } else if (name === "profiles") {
            (s.profiles || []).forEach(function (p, i) { out.push({ label: p.name, detail: setup.modeName(p.trakt), checkable: false, value: "›", act: "edit:" + i }) })
            out.push({ label: qsTr("Add Profile"), checkable: false, value: "+", act: "add" })
        } else if (name === "videos") {
            out = out.concat(flow.lines, flow.debridLines, flow.torrentLines)
            if (acc.tmdb && !acc.tmdb.builtin) {
                out.push({ header: true, label: qsTr("Movie and show info") })
                out.push({ label: qsTr("TMDB key"), detail: acc.tmdb.set ? qsTr("Set up") : qsTr("A free API key from themoviedb.org › Settings › API. Without it home stays empty"),
                           checkable: false, value: acc.tmdb.set ? qsTr("Change") : qsTr("Add"), act: "cred:TMDB_API_KEY" })
            }
        } else if (name === "trakt") {
            (s.profiles || []).forEach(function (p) {
                var waiting = setup.code && setup.codeProfile === p.id
                out.push({ label: p.name, detail: waiting ? qsTr("Waiting for the code below") : setup.modeName(p.trakt), checkable: false, value: "›", act: "trakt:" + p.id + ":" + p.trakt })
            })
        } else if (name === "audio" && langOptions) {
            Theme.preferredFirst(langOptions.audio, (langSnap || langs).languages).forEach(function (o) {
                var r = setup.langs.languages.indexOf(o.code)
                out.push({ label: qsTranslate("core", o.name), checkable: true, checked: r >= 0, badge: r >= 0 ? String(r + 1) : "", act: "lang:languages:" + o.code })
            })
        } else if (name === "subtitles" && langOptions) {
            out.push({ label: qsTr("Find extra subtitles"), detail: qsTr("For languages the video doesn't have, free through Stremio's OpenSubtitles addon"), checkable: true, checked: appOn("extra_subs"), act: "app:extra_subs" })
            var os = acc.opensubtitles || {}, osOn = !!os.set && app.opensubtitles !== false
            out.push({ label: qsTr("Use my OpenSubtitles.com account"), detail: qsTr("Searches there first with your own API key (opensubtitles.com › Consumers). Signing in raises the daily limit"),
                       checkable: true, checked: osOn, act: "os" })
            if (osOn) {
                out.push({ label: qsTr("OpenSubtitles API key"), detail: os.preview || "", checkable: false, value: qsTr("Change"), act: "cred:OPENSUBTITLES_API_KEY" })
                out.push({ label: qsTr("Sign in (optional)"), detail: os.user ? qsTr("Signed in as %1").arg(os.user) : qsTr("Without it the limit is a few subtitles a day per home"),
                           checkable: false, value: os.user ? qsTr("Change") : "›", act: "oslogin" })
            }
            out.push({ label: qsTr("Balkan mode"), detail: qsTr("Treats Serbian, Croatian and Bosnian as one choice and always picks the best of them"),
                       checkable: true, checked: !!s.balkanOn, act: "balkan" })
            out.push({ header: true, label: qsTr("Languages") })
            Theme.preferredFirst(langOptions.subtitles, (langSnap || langs).subtitles).forEach(function (o) {
                var r = setup.langs.subtitles.indexOf(o.code)
                out.push({ label: qsTranslate("core", o.name), checkable: true, checked: r >= 0, badge: r >= 0 ? String(r + 1) : "", act: "lang:subtitles:" + o.code })
            })
        } else if (name === "background") {
            var k = s.keepalive || {}
            // on by default: a fresh setup gets the timer when it finishes, unless turned off here
            var kOn = !!k.installed || (k.chosen === null && k.scheduler !== false)
            if (k.scheduler === false)
                out.push({ label: qsTr("Checked while Noonix TV is open"), detail: qsTr("This PC has no systemd timers: logins are checked whenever the app runs"), checkable: false })
            else
                out.push({ label: qsTr("Check logins once a day (Recommended)"), detail: qsTr("Trakt, OpenSubtitles and your debrid keys, even on days Noonix TV stays closed"), checkable: true, checked: kOn, act: "keepalive" })
        } else if (name === "benchmark") {
            var bn = speed.net, bd = speed.dev
            out.push({ label: qsTr("Speed check"), checkable: false, act: "bench", value: speed.running ? "…" : qsTr("Run"),
                       detail: speed.running ? qsTr("Measuring…") : speed.headline ? qsTr("You can watch up to %1").arg(speed.headline) + (speed.why ? "  ·  " + speed.why : "") : qsTr("Not measured yet") })
            if (speed.netDone) out.push({ label: qsTr("Internet"), checkable: false, act: "bench", detail: qsTr("%1 Mbit/s down").arg(bn.mbps), value: speed.label(speed.netZones, bn.mbps) })
            if (speed.devDone) out.push({ label: speed.deviceName, checkable: false, act: "bench", detail: speed.devText(bd.score), value: speed.label(speed.devZones, bd.score) })
        } else if (name === "quality") {
            out = Theme.qualityLines(quality, true)
        } else if (name === "done") {
            gaps.forEach(function (g) { out.push({ label: g, checkable: false }) })
        } else if (name === "playback") {
            var dk = s.desktop || {}
            // the menu entry is on by default: setup adds it when it finishes, unless turned off here
            if (dk.menuFixed)
                out.push({ label: qsTr("In the app menu"), detail: qsTr("Installed with Noonix TV"), checkable: false })
            else
                out.push({ label: qsTr("Add to the app menu"), detail: qsTr("Find Noonix TV with your other apps"), checkable: true,
                           checked: !!dk.menu || dk.menuChosen === null, act: "desk:menu" })
            out.push({ label: qsTr("Open at login"), detail: qsTr("Starts Noonix TV when you sign in, handy on a PC made for the TV"), checkable: true, checked: !!dk.login, act: "desk:login" })
            out.push({ label: qsTr("Show the title bar"), detail: qsTr("A normal window with the title bar and its buttons"), checkable: true, checked: app.title_bar === true, act: "titlebar" })
            out.push({ label: qsTr("Match the TV's refresh rate"), detail: qsTr("24 / 25 / 50 / 60 Hz for each video, never the resolution or HDR"), checkable: true, checked: app.refresh_match === true, act: "app:refresh_match" })
            out.push({ label: qsTr("Dim the controllers while playing"), detail: qsTr("Lightbar off, player light low"), checkable: true, checked: appOn("pad_leds"), act: "app:pad_leds" })
        }
        return out
    }

    // the row to land on when the lines are rebuilt (-1: the step's first)
    property int keepIndex: -1
    function run(l) {
        keepIndex = list.currentIndex
        var a = l.act || ""
        if (flow.run(a)) return
        if (a.indexOf("uilang:") === 0) {
            Desktop.setLanguage(a.slice(7))
            setApp("ui_lang", a.slice(7))
            // serbian: balkan mode on, so the subtitles step already shows it picked
            if (a === "uilang:sr" && !(info && info.balkanOn)) balkan(true)
        } else if (a === "add") {
            add.open((info.profiles || []).map(function (p) { return p.color }))
        } else if (a.indexOf("edit:") === 0) {
            var ep = (info.profiles || [])[Number(a.slice(5))]
            if (ep) add.openEdit(ep)
        } else if (a.indexOf("trakt:") === 0) {
            var parts = a.split(":"), id = Number(parts[1]), mode = parts[2]
            // signed in -> out; out -> sign in with a code
            if (mode === "own") Api.call("profiles.setTrakt", { id: id, mode: "none" }, function () { setup.refresh() })
            else startCode(id)
        } else if (a === "bench") {
            speed.open(!speed.netDone || !speed.devDone)
        } else if (a.indexOf("quality:") === 0) {
            Api.call("quality.set", { id: a.slice(8) }, function (ok, d) { if (ok) setup.quality = d })
        } else if (a.indexOf("lang:") === 0) {
            var lp = a.split(":")
            // serbian, croatian or bosnian subtitles: balkan mode picks the best of the three
            if (lp[1] === "subtitles" && ["sr", "hr", "bs"].indexOf(lp[2]) >= 0 && !(info && info.balkanOn) && !l.checked) balkan(true)
            else toggleLang(lp[1], lp[2])
        } else if (a.indexOf("desk:") === 0) {
            Api.call("desktop.set", { what: a.slice(5), on: !l.checked }, function () { setup.refresh() })
        } else if (a === "keepalive") {
            busy = true
            Api.call(l.checked ? "keepalive.remove" : "keepalive.install", {}, function (ok, d) {
                setup.busy = false
                if (!ok) toast.show(qsTr("Couldn't change the daily check"))
                setup.refresh()
            })
        } else if (a.indexOf("cred:") === 0) {
            enter(a.slice(5))
        } else if (a === "os") {
            var on = !(acc.opensubtitles && acc.opensubtitles.set && app.opensubtitles !== false)
            setApp("opensubtitles", on)
            if (on && !(acc.opensubtitles && acc.opensubtitles.set)) enter("OPENSUBTITLES_API_KEY")
        } else if (a === "oslogin") {
            entry.open({ title: qsTr("OpenSubtitles username"), placeholder: qsTr("Username") })
            entry.after = function (user) {
                entry.open({ title: qsTr("OpenSubtitles password"), placeholder: qsTr("Password"), secret: true,
                             check: function (v, reply) {
                                 Api.call("setup.credential", { key: "OPENSUBTITLES_LOGIN", value: { username: user, password: v } }, function (ok, d) {
                                     reply(ok && d.ok, ok ? Theme.coreText(d.message, d.count) : qsTr("Couldn't save it"))
                                 })
                             } })
                entry.after = function () { setup.refresh() }
            }
        } else if (a.indexOf("app:") === 0) {
            var k = a.slice(4); setApp(k, !appOn(k))
        } else if (a === "titlebar") {
            setApp("title_bar", app.title_bar !== true)
            Remote.setTitleBar(app.title_bar === true)
        } else if (a === "balkan") {
            balkan(!l.checked)
        }
    }

    // a key typed on the entry sheet, checked with its service before it's kept
    readonly property var credText: ({
        TMDB_API_KEY: { title: qsTr("TMDB API key"), hint: qsTr("themoviedb.org › Settings › API › API Key (the short one)"), placeholder: qsTr("API key") },
        OPENSUBTITLES_API_KEY: { title: qsTr("OpenSubtitles API key"), hint: qsTr("opensubtitles.com › Consumers › New consumer › API key"), placeholder: qsTr("API key") }
    })
    function enter(key) {
        var t = credText[key] || Theme.debridKeys[key] || { title: key }
        entry.open({ title: t.title, hint: t.hint, placeholder: t.placeholder,
                     check: function (v, reply) {
                         Api.call("setup.credential", { key: key, value: v }, function (ok, d) {
                             reply(ok && d.ok, ok ? Theme.coreText(d.message, d.count) : qsTr("Couldn't save it"))
                         })
                     } })
        entry.after = function () { setup.refresh() }
    }

    // trakt sign-in with a code
    function startCode(id) {
        codeProfile = id
        Api.call("trakt.deviceCode", {}, function (ok, d) {
            if (!ok) { toast.show(qsTr("Trakt isn't answering")); return }
            setup.code = d
            poll.interval = (d.interval || 5) * 1000
            poll.left = Math.ceil((d.expires_in || 600) / (d.interval || 5))
            poll.start()
        })
    }
    Timer {
        id: poll
        property int left: 0
        repeat: true
        onTriggered: {
            if (--left <= 0 || !setup.code) { stop(); setup.code = null; return }
            Api.call("trakt.devicePoll", { code: setup.code.device_code, profile: setup.codeProfile }, function (ok, d) {
                if (ok && d.done) {
                    poll.stop(); setup.code = null; setup.refresh(); toast.show(qsTr("Signed in to Trakt"))
                    if (d.local) traktChoice.ask(setup.codeProfile, d.local)
                }
                else if (!ok) { poll.stop(); setup.code = null; toast.show(qsTr("That code didn't work")) }
            })
        }
    }

    function next() {
        if (name === "profiles" && !(info && info.profiles && info.profiles.length)) {
            add.open([])
            return
        }
        if (name === "terms") Api.call("setup.agree", {}, function () { if (setup.termsOnly) finish.start() })
        if (termsOnly) return
        // continuing without a pick keeps the recommended one
        if (name === "quality" && quality && !quality.chosen)
            Api.call("quality.set", { id: quality.recommended }, function (ok, d) { if (ok) setup.quality = d })
        if (name === "audio" || name === "subtitles")
            Api.call("setup.setLanguages", { languages: langs.languages, subtitles: langs.subtitles })
        if (name === "done") {
            Api.call("setup.finish", {}, function () { finish.start() })
            return
        }
        go(step + 1)
    }
    function back() {
        if (add.visible) { add.visible = false; list.forceActiveFocus(); return }
        if (code) { poll.stop(); code = null; return }
        if (step > 0) go(step - 1)
    }

    // steps slide: out to the side they came from, in from the other
    property int target: 0
    property bool benchAsked: false
    function loadQuality() { Api.call("quality.options", {}, function (ok, d) { if (ok) setup.quality = d }) }
    onNameChanged: {
        // comes up by itself once, while the step slides in
        if (name === "benchmark" && !benchAsked) { benchAsked = true; speed.open(true) }
        if (name === "quality") loadQuality()
    }
    function go(n) {
        if (turn.running) return
        target = n
        turn.dir = n > step ? 1 : -1
        turn.start()
    }
    SequentialAnimation {
        id: turn
        property int dir: 1
        ParallelAnimation {
            NumberAnimation { target: pane; property: "opacity"; to: 0; duration: 150; easing.type: Easing.InQuad }
            NumberAnimation { target: shift; property: "x"; to: -70 * setup.u * turn.dir; duration: 150; easing.type: Easing.InQuad }
        }
        ScriptAction { script: { setup.keepIndex = -1; setup.step = setup.target; shift.x = 70 * setup.u * turn.dir; continueBtn.forceActiveFocus() } }
        ParallelAnimation {
            NumberAnimation { target: pane; property: "opacity"; to: 1; duration: 280; easing.type: Easing.OutCubic }
            NumberAnimation { target: shift; property: "x"; to: 0; duration: 340; easing.type: Easing.OutCubic }
        }
    }
    // done: the words go, the app's window zooms in to the whole screen and sharpens
    SequentialAnimation {
        id: finish
        NumberAnimation { target: pane; property: "opacity"; to: 0; duration: 200; easing.type: Easing.InQuad }
        NumberAnimation { target: frame; property: "reveal"; to: 1; duration: 620; easing.type: Easing.OutCubic }
        ScriptAction { script: { setup.visible = false; setup.finished() } }
    }
    Keys.onEscapePressed: back()

    // what the glass over setup refracts (Main's setupGlass): the zoomed, blurred app behind it
    readonly property alias backdropItem: frame
    // the app as a blurred window in the middle (reveal 0) -> the whole screen, sharp (reveal 1)
    Rectangle { anchors.fill: parent; color: Theme.bg; opacity: 1 - frame.reveal }
    Item {
        id: frame
        property real reveal: 0
        anchors.fill: parent
        ShaderEffectSource {
            id: appCopy
            anchors.fill: parent
            sourceItem: browse
            live: setup.visible
            hideSource: false
            textureSize: Qt.size(width / 2, height / 2)
            visible: false
        }
        Rectangle { id: round; anchors.fill: parent; radius: 60 * setup.u * (1 - frame.reveal); visible: false; layer.enabled: true }
        MultiEffect {
            anchors.fill: parent
            source: appCopy
            scale: 0.84 + 0.16 * frame.reveal
            blurEnabled: true
            blurMax: 64
            blur: 1 - frame.reveal
            maskEnabled: true
            maskSource: round
        }
        // darker by scaling, not subtracting: the empty app's grey placeholders still show
        Rectangle { anchors.fill: parent; color: "black"; opacity: 0.62 * (1 - frame.reveal) }
    }
    // the app behind takes no hover or clicks
    MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.AllButtons }

    Item {
        id: pane
        anchors.fill: parent
        transform: Translate { id: shift }
    Column {
        id: col
        anchors.centerIn: parent
        width: 1100 * setup.u
        spacing: 22 * setup.u
        Text {
            visible: !setup.termsOnly
            text: qsTr("Step %1 of %2").arg(setup.step + 1).arg(setup.steps.length)
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 23 * setup.u; weight: Font.Medium }
        }
        Text {
            width: parent.width
            text: setup.title[setup.name] || ""
            color: Theme.fg
            wrapMode: Text.WordWrap
            font { family: Theme.display; pixelSize: 56 * setup.u; weight: Font.Bold }
        }
        Text {
            width: parent.width
            text: setup.blurb[setup.name] || ""
            color: Theme.fg2
            wrapMode: Text.WordWrap
            font { family: Theme.text; pixelSize: 28 * setup.u }
        }
        Item { width: 1; height: 8 * setup.u }
        Item {
            width: parent.width
            height: setup.lines.length ? Math.min(530 * setup.u, list.contentHeight) + 32 * setup.u : 0
            visible: height > 0
            Glass { anchors.fill: parent; kind: "panel"; radius: 40 * setup.u }
            ListWheel { view: list }
            ListView {
                id: list
                anchors { fill: parent; margins: 16 * setup.u }
                clip: true
                model: setup.lines
                onModelChanged: {
                    var i = setup.keepIndex < 0 ? setup.firstLine() : Math.min(setup.keepIndex, setup.lines.length - 1)
                    // something just added: the focus goes to its row
                    var added = flow.focusAct ? setup.lines.findIndex(function (l) { return l.act === flow.focusAct }) : -1
                    if (added >= 0) { i = added; setup.keepIndex = added; flow.focusAct = "" }
                    while (i > 0 && setup.lines[i] && setup.lines[i].header) i--
                    currentIndex = i
                    Qt.callLater(function () { list.positionViewAtIndex(list.currentIndex, ListView.Contain) })
                }
                keyNavigationEnabled: true
                // two lines stay in view above and below the focus (except at the ends), and it keeps up
                highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
                preferredHighlightBegin: 2 * 92 * setup.u
                preferredHighlightEnd: height - 2 * 92 * setup.u
                highlightMoveDuration: 140
                highlightMoveVelocity: -1
                delegate: Loader {
                    required property var modelData
                    required property int index
                    width: list.width
                    sourceComponent: modelData.header ? headLine : toggleLine
                    Component {
                        id: headLine
                        Text {
                            height: 76 * setup.u
                            leftPadding: 30 * setup.u
                            bottomPadding: 12 * setup.u
                            verticalAlignment: Text.AlignBottom
                            text: modelData.label
                            color: Theme.fg2
                            font { family: Theme.display; pixelSize: 26 * setup.u; weight: Font.DemiBold }
                        }
                    }
                    Component {
                        id: toggleLine
                        Toggle {
                            label: modelData.label
                            detail: modelData.detail || ""
                            value: modelData.value || ""
                            checkable: !!modelData.checkable
                            checked: !!modelData.checked
                            badge: modelData.badge || ""
                            grow: 1
                            focused: list.currentIndex === index && list.activeFocus
                        }
                    }
                }
                Keys.onReturnPressed: if (setup.lines[currentIndex] && !setup.lines[currentIndex].header) setup.run(setup.lines[currentIndex])
                Keys.onUpPressed: function (e) { var i = currentIndex - 1; while (i >= 0 && setup.lines[i].header) i--; if (i >= 0) { currentIndex = i; setup.keepIndex = i } }
                Keys.onDownPressed: function (e) {
                    var i = currentIndex + 1
                    while (i < count && setup.lines[i].header) i++
                    if (i >= count) continueBtn.forceActiveFocus(); else { currentIndex = i; setup.keepIndex = i }
                }
                Keys.onRightPressed: continueBtn.forceActiveFocus()
            }
        }
        // the terms: plain reading, nothing to pick
        Item {
            width: parent.width
            height: setup.name === "terms" ? termsCol.height + 72 * setup.u : 0
            visible: height > 0
            Glass { anchors.fill: parent; kind: "panel"; radius: 40 * setup.u }
            Column {
                id: termsCol
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 46 * setup.u; rightMargin: 46 * setup.u }
                spacing: 24 * setup.u
                Repeater {
                    model: [
                        (Theme.android ? qsTr("Noonix TV is only a player. It comes with no videos and no sources: it plays the files on your device and whatever addons or extensions you add yourself.") : qsTr("Noonix TV is only a player. It comes with no videos and no sources: it plays the files on your PC and whatever addons or extensions you add yourself.")),
                        qsTr("You're responsible for what you watch and download with it. Only use videos you have the right to, and follow the laws where you live."),
                        qsTr("Noonix TV is free software (GNU GPL 3.0) and comes with no warranty. Full terms: github.com/dzeliks/noonix-tv › TERMS.md")
                    ]
                    Text {
                        width: termsCol.width
                        text: modelData
                        wrapMode: Text.WordWrap
                        color: index === 2 ? Theme.fg3 : Theme.fg2
                        lineHeight: 1.12
                        font { family: Theme.text; pixelSize: (index === 2 ? 24 : 28) * setup.u }
                    }
                }
            }
        }
        // the trakt code, big enough to read from the couch
        Item {
            width: parent.width
            height: setup.code ? codeCol.height + 64 * setup.u : 0
            visible: !!setup.code
            Glass { anchors.fill: parent; kind: "panel"; radius: 40 * setup.u }
            Column {
                id: codeCol
                anchors.centerIn: parent
                spacing: 12 * setup.u
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: setup.code ? qsTr("On your phone, open %1 and enter").arg(setup.code.verification_url) : ""
                    color: Theme.fg2
                    font { family: Theme.text; pixelSize: 27 * setup.u }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: setup.code ? setup.code.user_code : ""
                    color: Theme.fg
                    font { family: Theme.rounded; pixelSize: 84 * setup.u; weight: Font.Bold; letterSpacing: 8 * setup.u }
                }
                Spinner { anchors.horizontalCenter: parent.horizontalCenter; width: 44 * setup.u; height: width; running: !!setup.code }
            }
        }
        Item { width: 1; height: 10 * setup.u }
        Row {
            spacing: 24 * setup.u
            GlassButton {
                id: continueBtn
                primary: true
                text: setup.name === "done" ? qsTr("Start Watching") : setup.name === "welcome" ? qsTr("Get Started") : setup.name === "terms" ? qsTr("I Agree")
                    : setup.name === "trakt" && !((setup.info && setup.info.profiles) || []).some(function (p) { return p.trakt === "own" }) ? qsTr("Skip for Now") : qsTr("Continue")
                onClicked: setup.next()
                KeyNavigation.right: backBtn.visible ? backBtn : null
                Keys.onUpPressed: setup.enterList()
            }
            GlassButton {
                id: backBtn
                visible: setup.step > 0
                text: qsTr("Back")
                onClicked: setup.back()
                Keys.onUpPressed: setup.enterList()
            }
        }
    }

    }

    KeyEntry {
        id: entry
        anchors.fill: parent
        // what to do with the value once it's in (the next sheet, a refresh)
        property var after: null
        onCancel: { close(); after = null; list.forceActiveFocus() }
        onDone: function (v) {
            close()
            var f = after; after = null
            if (f) f(v)
            if (!isOpen) list.forceActiveFocus()
        }
    }
    SourcesFlow {
        id: flow
        anchors.fill: parent
        entry: entry
        enterKey: setup.enter
        onChanged: setup.refresh()
        onBack: list.forceActiveFocus()
    }
    SpeedCheck {
        id: speed
        parent: win.sheetLayer
        anchors.fill: parent
        onMeasured: setup.loadQuality()
        onClosed: continueBtn.forceActiveFocus()
    }
    ProfileAdd {
        id: add
        anchors.fill: parent
        onCancel: { visible = false; continueBtn.forceActiveFocus() }
        onDone: function (p) { visible = false; setup.refresh(); win.loadProfiles(); continueBtn.forceActiveFocus() }
    }
}
