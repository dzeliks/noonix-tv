import QtQuick
import "Pads.js" as Pads

// settings: sections on the left, the section on the right (tvos layout)
FocusScope {
    id: settings
    readonly property real u: Theme.u
    property int section: 0
    property bool copied: false
    Timer { id: copiedTimer; interval: 2200; onTriggered: settings.copied = false }
    readonly property var sectionIds: ["sources", "accounts", "profiles", "audio", "subtitles", "playback", "controls", "about"]
    readonly property var sections: [qsTr("Sources"), qsTr("Accounts"), qsTr("Profiles"), qsTr("Audio"), qsTr("Subtitles"), qsTr("Playback"), qsTr("Controls"), qsTr("About")]
    property var acc: ({})
    readonly property string sectionId: sectionIds[section] || ""
    property var patterns: null
    property var desktop: null
    property var prefs: null
    // the languages' order as the section opened (the chosen ones first): a line doesn't jump away
    // from the focus while it's ticked
    property var langSnap: null
    function takeSnap() { langSnap = prefs ? { languages: prefs.languages.slice(), subtitles: prefs.subtitles.slice() } : null }
    onSectionIdChanged: takeSnap()
    onPrefsChanged: if (!langSnap) takeSnap()
    property var langOptions: null
    property var quality: null
    property var app: ({})
    // what the screen was found to show (display.state)
    property var screen: ({})
    property var template: null
    property var update: null
    property string version: ""
    // "", "checking", "installing", "installed", or an error line
    property string updateState: ""
    property int updatePct: 0
    signal upFromTop()

    Connections {
        target: Api
        function onPushed(name, d) { if (name === "update.progress" && d) settings.updatePct = d.pct }
    }
    function checkUpdate(auto) {
        if (!auto) updateState = "checking"
        Api.call("update.check", { auto: auto }, function (ok, d) {
            if (ok) { settings.update = d; if (!auto) settings.updateState = "" }
            else if (!auto) settings.updateState = (d && d.error) ? qsTranslate("core", d.error) : qsTr("Couldn't check")
        })
    }

    function load() {
        flow.load()
        Api.call("patterns.get", {}, function (ok, d) { if (ok) settings.patterns = d })
        Api.call("desktop.status", {}, function (ok, d) { if (ok) settings.desktop = d })
        Api.call("sources.prefs", {}, function (ok, d) { if (ok) settings.prefs = d })
        Api.call("languages.options", {}, function (ok, d) { if (ok) settings.langOptions = d })
        Api.call("quality.options", {}, function (ok, d) { if (ok) settings.quality = d })
        Api.call("settings.app", {}, function (ok, d) { if (ok) settings.app = d })
        Api.call("display.state", {}, function (ok, d) { if (ok) settings.screen = d })
        Api.call("addons.formatter", {}, function (ok, d) { if (ok) settings.template = d })
        Api.call("ping", {}, function (ok, d) { if (ok) settings.version = d.version })
        checkUpdate(true)
        Api.call("setup.accounts", {}, function (ok, d) { if (ok) settings.acc = d })
    }
    Component.onCompleted: { syncRows(); load() }
    // built once and kept (main.qml warms it up): a visit shows what's loaded, load() only refreshes.
    // the rows wait for the first answers, so they never fill in one by one
    readonly property bool ready: (patterns !== null && prefs !== null && quality !== null && langOptions !== null) || readyLate.ran
    Timer { id: readyLate; property bool ran: false; interval: 1500; running: true; onTriggered: ran = true }
    onVisibleChanged: {
        if (visible) { load(); return }
        // the next visit starts at the top, like a fresh page
        swap.stop()
        page.opacity = 1
        section = 0
        menu.currentIndex = 0
        page.toTop()
    }

    // what the controls section lists, in this order (the remote's actions)
    readonly property var controlActions: [
        { id: "OK", label: qsTr("Select") }, { id: "BACK", label: qsTr("Back") }, { id: "MENU", label: qsTr("Options") },
        { id: "PLAYPAUSE", label: qsTr("Play / Pause") }, { id: "RW", label: qsTr("Rewind") }, { id: "FF", label: qsTr("Fast-forward") },
        { id: "CH_DOWN", label: qsTr("Back 30 seconds") }, { id: "CH_UP", label: qsTr("Forward 30 seconds") }, { id: "HOME", label: qsTr("Home") }
    ]
    function savePrefs(p) {
        prefs = p
        Api.call("sources.setPrefs", p)
    }
    function toggleLang(listName, code) {
        var p = JSON.parse(JSON.stringify(prefs)), l = p[listName] || []
        var i = l.indexOf(code)
        if (i >= 0) { if (l.length > 1) l.splice(i, 1) } else l.push(code)
        p[listName] = l
        savePrefs(p)
    }
    function appOn(key) { return app[key] !== false }
    function setApp(key, v) {
        var a = Object.assign({}, app); a[key] = v; app = a
        Api.call("settings.setApp", { key: key, value: v })
    }

    // sections
    ListWheel { view: menu }
    ListView {
        id: menu
        x: Theme.margin
        y: 200 * settings.u
        width: 420 * settings.u
        height: parent.height - y
        focus: true
        model: settings.sections
        spacing: 8 * settings.u
        keyNavigationEnabled: true
        // the page follows once the focus rests: running down the menu doesn't rebuild it per step.
        // under the mouse it waits for the click
        onCurrentIndexChanged: if (!Input.pointing) sectionLater.restart()
        Timer { id: sectionLater; interval: 140; onTriggered: if (settings.section !== menu.currentIndex) swap.restart() }
        Keys.onUpPressed: function (e) { if (currentIndex === 0) settings.upFromTop(); else decrementCurrentIndex() }
        Keys.onRightPressed: page.forceActiveFocus()
        Keys.onReturnPressed: if (settings.section !== currentIndex) swap.restart(); else page.forceActiveFocus()
        delegate: Toggle {
            required property var modelData
            required property int index
            width: menu.width
            label: modelData
            checkable: false
            value: "›"
            focused: ListView.isCurrentItem && menu.activeFocus
            opacity: settings.section === index || menu.activeFocus ? 1 : 0.6
        }
    }

    // the section's lines, one list model per section: {label, detail, value, checkable, checked, badge, act}
    readonly property var lines: {
        var out = []
        if (sectionId === "sources") {
            out = out.concat(flow.lines, flow.torrentLines)
            out.push({ header: true, label: qsTr("Release patterns") })
            var pt = patterns || {}
            out.push({ label: qsTr("Prefer"), value: "›", act: "patterns:preferred",
                       detail: (pt.preferred || []).length ? pt.preferred.join(", ") : qsTr("None. Words in a release name you like, best first, like REMUX or a language tag") })
            out.push({ label: qsTr("Hide"), value: "›", act: "patterns:excluded",
                       detail: (pt.excluded || []).length ? pt.excluded.join(", ") : qsTr("None. Releases with these words never show") })
            out.push({ header: true, label: qsTr("Advanced") })
            out.push({ label: qsTr("Noonix formatter for AIOStreams"), checkable: false, value: copied ? qsTr("Copied") : qsTr("Copy"),
                       detail: qsTr("If you run your own AIOStreams: paste it into its Formatter › Custom when a source says Unsupported formatting"), act: "copy-template" })
            if (prefs) {
                out.push({ label: qsTr("Show sources that need downloading"), checkable: true, checked: prefs.showUncached, act: "pref:showUncached" })
            }
            if (quality) {
                out.push({ label: qsTr("Picture quality"), checkable: false, header: true })
                out = out.concat(Theme.qualityLines(quality))
                var q = quality
                out.push({ label: qsTr("Speed check"), checkable: false, act: "bench", value: qsTr("Run"),
                           detail: q.mbps !== null && q.mbps !== undefined ? qsTr("Last time: %1 Mbit/s down, this device scored %2").arg(q.mbps).arg(q.device !== null && q.device !== undefined ? q.device : "–")
                                 : q.device !== null && q.device !== undefined ? qsTr("Last time: no internet reading, this device scored %1").arg(q.device)
                                 : qsTr("Not measured yet: the recommendation is a guess") })
            }
        } else if (sectionId === "accounts") {
            var os = acc.opensubtitles || {}, osOn = !!os.set && app.opensubtitles !== false
            out = out.concat(flow.debridLines)
            if (out.length) out.push({ header: true, label: qsTr("Other accounts") })
            // trakt belongs to the profile that's watching
            var me = win.profile || {}, traktOn = me.trakt === "own"
            out.push({ label: "Trakt", checkable: false, value: traktOn ? qsTr("Sign out") : qsTr("Sign in"), act: "trakt",
                       detail: traktOn ? qsTr("%1 is signed in: Up Next and watch history stay in sync").arg(me.name || "")
                                       : qsTr("Up Next and watch history for %1").arg(me.name || "") })
            // built in on release builds; your own key goes first and keeps home working if tmdb refuses that one
            var tm = acc.tmdb || {}
            out.push({ label: tm.builtin ? qsTr("Your own TMDB key") : qsTr("Movie and show info (TMDB)"), checkable: false, value: tm.own ? qsTr("Change") : qsTr("Add"), act: "cred:TMDB_API_KEY",
                       detail: tm.refused ? qsTr("TMDB refused the key in use: add your own (themoviedb.org › Settings › API)")
                             : tm.own ? tm.own : tm.builtin ? qsTr("Optional: Noonix TV's own key is built in") : qsTr("Not set: home stays empty") })
            out.push({ label: qsTr("Use my OpenSubtitles.com account"), detail: qsTr("Searches there first; otherwise Stremio's free OpenSubtitles addon"), checkable: true, checked: osOn, act: "os" })
            if (osOn) {
                out.push({ label: qsTr("OpenSubtitles API key"), detail: os.preview || "", checkable: false, value: qsTr("Change"), act: "cred:OPENSUBTITLES_API_KEY" })
                out.push({ label: qsTr("OpenSubtitles sign-in"), detail: os.user ? qsTr("Signed in as %1").arg(os.user) : qsTr("Optional: raises the daily limit"), checkable: false, value: os.user ? qsTr("Change") : "›", act: "oslogin" })
            }
        } else if (sectionId === "profiles") {
            for (var q = 0; q < win.profiles.length; ++q)
                out.push({ label: win.profiles[q].name, detail: qsTr("Name, colour and picture"), checkable: false, value: "›", act: "profile:" + q })
            out.push({ label: qsTr("Add profile"), checkable: false, value: "+", act: "profile-add" })
            out.push({ label: qsTr("Sign in automatically"), detail: qsTr("Open on the last profile without asking who's watching"),
                       checkable: true, checked: win.autoLogin, act: "auto-login" })
            out.push({ header: true, label: qsTr("Another computer"), checkable: false })
            out.push({ label: qsTr("Export this profile"), checkable: false, value: "›", act: "profile-export",
                       detail: qsTr("%1's languages, sources and history as a file, for Noonix TV on another computer").arg(win.profile ? win.profile.name : "") })
            out.push({ label: qsTr("Import a profile"), checkable: false, value: "+", act: "profile-import",
                       detail: qsTr("A .noonix file from another computer, as a new profile") })
        } else if (sectionId === "audio" && prefs && langOptions) {
            out.push({ label: qsTr("In order of preference: the first one a source has plays"), checkable: false, header: true })
            var opts = Theme.preferredFirst(langOptions.audio, (langSnap || prefs).languages)
            for (var j = 0; j < opts.length; ++j) {
                var r = prefs.languages.indexOf(opts[j].code)
                out.push({ label: qsTranslate("core", opts[j].name), checkable: true, checked: r >= 0, badge: r >= 0 ? String(r + 1) : "", act: "lang:languages:" + opts[j].code })
            }
        } else if (sectionId === "subtitles" && prefs && langOptions) {
            out.push({ label: qsTr("Balkan mode"), detail: qsTr("Treats Serbian, Croatian and Bosnian subtitles as one choice and always picks the best of them; sources that have them come first"),
                       checkable: true, checked: app.balkan_subs === true, act: "balkan" })
            out.push({ label: qsTr("In order of preference"), checkable: false, header: true })
            var so = Theme.preferredFirst(langOptions.subtitles, (langSnap || prefs).subtitles)
            for (var k = 0; k < so.length; ++k) {
                var r2 = prefs.subtitles.indexOf(so[k].code)
                out.push({ label: qsTranslate("core", so[k].name), checkable: true, checked: r2 >= 0, badge: r2 >= 0 ? String(r2 + 1) : "", act: "lang:subtitles:" + so[k].code,
                           detail: so[k].code === "balkan" ? qsTr("Whichever fits the release best, Serbian first on a tie") : "" })
            }
        } else if (sectionId === "playback") {
            var dk = desktop || {}
            // the language's own name, whichever one is on
            out.push({ label: qsTr("Language"), checkable: false, value: Desktop.language === "sr" ? "Srpski" : "English", act: "uilang" })
            if (!Theme.android) {
                out.push(dk.menuFixed ? { label: qsTr("In the app menu"), detail: qsTr("Installed with Noonix TV"), checkable: false }
                                      : { label: qsTr("Add to the app menu"), detail: qsTr("Find Noonix TV with your other apps"), checkable: true, checked: !!dk.menu, act: "desk:menu" })
                out.push({ label: qsTr("Open at login"), detail: qsTr("Starts Noonix TV when you sign in to this PC"), checkable: true, checked: !!dk.login, act: "desk:login" })
                out.push({ label: qsTr("Show the title bar"), detail: qsTr("A normal window with the title bar and its buttons"), checkable: true, checked: app.title_bar === true, act: "titlebar" })
                out.push({ label: qsTr("Match the TV's refresh rate"), detail: qsTr("Switches the TV to 24 / 25 / 50 / 60 Hz for each video (never the resolution or HDR)"), checkable: true, checked: app.refresh_match === true, act: "app:refresh_match" })
            }
            out.push({ label: qsTr("Find extra subtitles"), detail: qsTr("From OpenSubtitles, for your subtitle languages the file doesn't have"), checkable: true, checked: appOn("extra_subs"), act: "app:extra_subs" })
            var hs = app.hdr_screen || "auto"
            var found = screen.hdr === true ? qsTr("HDR") : screen.hdr === false ? qsTr("no HDR") : ""
            out.push({ label: qsTr("HDR on this screen"), detail: qsTr("Picks the sources that suit it best. Set it yourself if the screen is guessed wrong"), checkable: false,
                       value: hs === "on" ? qsTr("On") : hs === "off" ? qsTr("Off") : found ? qsTr("Automatic (%1)").arg(found) : qsTr("Automatic"), act: "hdrscreen" })
            if (!Theme.android)
                out.push({ label: qsTr("Dim the controllers while playing"), detail: qsTr("Lightbar off, player light low"), checkable: true, checked: appOn("pad_leds"), act: "app:pad_leds" })
        } else if (sectionId === "controls") {
            var b = Input.bindings, kind = Input.padKind
            var pos = { south: qsTr("Button 1"), east: qsTr("Button 2"), west: qsTr("Button 3"), north: qsTr("Button 4") }
            out.push({ label: qsTr("Controller"), checkable: false, header: true })
            controlActions.forEach(function (c) {
                out.push({ label: c.label, checkable: false, act: "bind:pad:" + c.id,
                           value: ((b.pad || {})[c.id] || []).map(function (x) { return Pads.text(kind, x, pos) }).join("  ·  ") || "–" })
            })
            out.push({ label: qsTr("Keyboard"), checkable: false, header: true })
            controlActions.forEach(function (c) {
                out.push({ label: c.label, checkable: false, act: "bind:keys:" + c.id,
                           value: ((b.keys || {})[c.id] || []).map(Pads.keyText).join("  ·  ") || "–" })
            })
            out.push({ label: qsTr("Built in"), checkable: false, header: true })
            out.push({ label: qsTr("Moving around"), detail: qsTr("The d-pad, the left stick and the arrow keys"), checkable: false })
            out.push({ label: qsTr("Mouse"), detail: qsTr("Point to move, click to select, right click goes back, the wheel scrolls"), checkable: false })
            out.push({ label: qsTr("Reset controls"), detail: qsTr("The controller and keyboard as they came"), checkable: false, value: qsTr("Reset"), act: "bind-reset" })
        } else if (sectionId === "about") {
            // who made it, with the website a press away (qr for the phone)
            out.push({ kind: "brand", label: "Noonix TV", value: version, checkable: false, act: "site" })
            var u = update, st = updateState, det, val
            if (st === "checking") { det = qsTr("Checking…"); val = "" }
            else if (st === "installing") { det = qsTr("Downloading %1").arg(u.latest); val = updatePct + "%" }
            else if (st === "installed") { det = qsTr("%1 is installed").arg(u.latest); val = qsTr("Restart") }
            else if (st !== "") { det = st; val = qsTr("Check") }
            else if (u && u.available && u.canInstall) { det = qsTr("%1 is out").arg(u.latest); val = qsTr("Install") }
            else if (u && u.available) { det = qsTr("%1 is out").arg(u.latest) + (u.why ? "  ·  " + qsTranslate("core", u.why) : ""); val = qsTr("Check") }
            else { det = u && u.latest ? qsTr("Up to date") : qsTr("Looks for a new version once a day"); val = qsTr("Check") }
            out.push({ label: qsTr("Updates"), detail: det, checkable: false, value: val, act: "update" })
            out.push({ label: qsTr("Run setup again"), detail: qsTr("Language, profiles, Trakt, sources, picture quality, subtitles"), checkable: false, value: "›", act: "setup" })
            // tmdb's terms: their logo and this exact notice
            out.push({ label: qsTr("License"), detail: qsTr("Free software under the GNU GPL 3.0 or later. Source: github.com/dzeliks/noonix-tv"), checkable: false })
            out.push({ label: qsTr("Terms"), detail: qsTr("A player for your own videos and the sources you add; you answer for what you watch. github.com/dzeliks/noonix-tv › TERMS.md"), checkable: false })
            out.push({ label: qsTr("Credits"), checkable: false, header: true })
            out.push({ label: "", icon: "qrc:/qml/assets/credits/tmdb.svg", checkable: false,
                       detail: qsTr("This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.") })
            out.push({ label: "Trakt", detail: qsTr("Up Next, watch history and scrobbling through the Trakt API. Not affiliated with Trakt."), checkable: false })
            out.push({ label: "OpenSubtitles.com", detail: qsTr("Extra subtitles"), checkable: false })
            out.push({ label: "IntroDB", detail: qsTr("Intro, recap and credits times"), checkable: false })
            out.push({ label: qsTr("Stremio addons"), detail: qsTr("Noonix TV ships no sources: videos come from your library and the addons and extensions you add"), checkable: false })
            out.push({ label: "mpv · FFmpeg", detail: qsTr("Video playback (GPL)"), checkable: false })
            out.push({ label: "Qt", detail: qsTr("The interface (LGPL-3.0)"), checkable: false })
            out.push({ label: "Inter", detail: qsTr("Font by Rasmus Andersson (SIL Open Font License)"), checkable: false })
            out.push({ label: qsTr("Licenses"), detail: qsTr("Every bundled library with its license and source: THIRD-PARTY.txt in the app's files"), checkable: false })
            return out
        }
        return out
    }
    function run(line) {
        var a = line.act || ""
        if (flow.run(a)) return
        if (a.indexOf("patterns:") === 0) {
            var which = a.slice(9), pt = patterns || { preferred: [], excluded: [] }
            entry.open({ title: which === "preferred" ? qsTr("Preferred release patterns") : qsTr("Hidden release patterns"),
                         placeholder: "REMUX, HDR10+, /\\bITA\\b/",
                         hint: qsTr("Commas between them. Words match whole words in any case; /…/ is a regular expression. Empty clears it"),
                         text: (pt[which] || []).join(", "), allowEmpty: true,
                         check: function (v, reply) {
                             var p = { preferred: pt.preferred || [], excluded: pt.excluded || [] }
                             p[which] = v.split(",").map(function (x) { return x.trim() }).filter(function (x) { return x !== "" })
                             Api.call("patterns.set", p, function (ok, d) {
                                 if (ok) settings.patterns = d
                                 reply(ok, ok ? qsTr("Saved") : ((d && d.error) || qsTr("Couldn't save it")))
                             })
                         } })
        } else if (a.indexOf("quality:") === 0) {
            Api.call("quality.set", { id: a.slice(8) }, function (ok, d) { if (ok) settings.quality = d })
        } else if (a === "bench") {
            speedCheck.open(true)
        } else if (a === "hdrscreen") {
            var seen = screen.hdr === true ? qsTr("HDR") : screen.hdr === false ? qsTr("no HDR") : ""
            choices.open({ title: qsTr("HDR on this screen"), detail: qsTr("Picks the sources that suit it best. Set it yourself if the screen is guessed wrong"),
                           current: app.hdr_screen || "auto",
                           options: [{ id: "auto", label: seen ? qsTr("Automatic (%1)").arg(seen) : qsTr("Automatic") }, { id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }],
                           pick: function (id) { settings.setApp("hdr_screen", id) } })
        } else if (a === "uilang") {
            var nl = Desktop.language === "sr" ? "en" : "sr"
            Desktop.setLanguage(nl)
            setApp("ui_lang", nl)
            // serbian: balkan mode for the subtitles too
            if (nl === "sr" && app.balkan_subs !== true) Api.call("setup.setBalkan", { on: true }, function () { settings.load() })
        } else if (a.indexOf("bind:") === 0) {
            var bp = a.split(":")
            bindSheet.open({ side: bp[1], action: bp[2], title: controlActions.filter(function (x) { return x.id === bp[2] })[0].label, custom: app.controls || {},
                             positions: { south: qsTr("Button 1"), east: qsTr("Button 2"), west: qsTr("Button 3"), north: qsTr("Button 4") } })
        } else if (a === "bind-reset") {
            setApp("controls", {})
            Input.setBindings({})
        } else if (a === "site") {
            siteCard.open("https://aleksa.sh", "aleksa.sh")
        } else if (a === "trakt") {
            var p = win.profile
            if (!p) return
            if (p.trakt === "own") Api.call("profiles.setTrakt", { id: p.id, mode: "none" }, function () { win.refreshProfiles() })
            else traktCode.open(p.id, p.name)
        } else if (a.indexOf("desk:") === 0) {
            Api.call("desktop.set", { what: a.slice(5), on: !line.checked }, function (ok, d) { if (ok) settings.desktop = d })
        } else if (a === "copy-template") {
            if (template) {
                Desktop.copy(template.name + "\n\n" + template.description)
                copied = true; copiedTimer.restart()
                toast.show(qsTr("Copied"))
            }
        } else if (a.indexOf("pref:") === 0) {
            var p = JSON.parse(JSON.stringify(prefs)); var key = a.slice(5); p[key] = !p[key]; savePrefs(p)
        } else if (a.indexOf("lang:") === 0) {
            var parts = a.split(":")
            // serbian, croatian or bosnian subtitles: balkan mode picks the best of the three
            if (parts[1] === "subtitles" && ["sr", "hr", "bs"].indexOf(parts[2]) >= 0 && app.balkan_subs !== true && !line.checked)
                Api.call("setup.setBalkan", { on: true }, function () { settings.load() })
            else toggleLang(parts[1], parts[2])
        } else if (a.indexOf("app:") === 0) {
            var k = a.slice(4); setApp(k, !appOn(k))
        } else if (a === "titlebar") {
            setApp("title_bar", app.title_bar !== true)
            Remote.setTitleBar(app.title_bar === true)
        } else if (a === "balkan") {
            var on = app.balkan_subs !== true
            Api.call("setup.setBalkan", { on: on }, function () { settings.load() })
        } else if (a === "update") {
            var u = update
            if (updateState === "installing" || updateState === "checking") return
            if (updateState === "installed") {
                Api.call("update.relaunch", {}, function (ok) { if (ok) Qt.quit() })
            } else if (updateState === "" && u && u.available && u.canInstall) {
                updatePct = 0; updateState = "installing"
                Api.call("update.install", {}, function (ok, d) {
                    settings.updateState = ok ? (d.installed ? "installed" : "") : ((d && d.error) || qsTr("Couldn't update"))
                })
            } else checkUpdate(false)
        } else if (a.indexOf("cred:") === 0) {
            enter(a.slice(5))
        } else if (a === "os") {
            var osWas = !!(acc.opensubtitles && acc.opensubtitles.set) && app.opensubtitles !== false
            setApp("opensubtitles", !osWas)
            if (!osWas && !(acc.opensubtitles && acc.opensubtitles.set)) enter("OPENSUBTITLES_API_KEY")
        } else if (a === "oslogin") {
            entry.open({ title: qsTr("OpenSubtitles username"), placeholder: qsTr("Username") })
            entry.after = function (user) {
                entry.open({ title: qsTr("OpenSubtitles password"), placeholder: qsTr("Password"), secret: true,
                             check: function (v, reply) {
                                 Api.call("setup.credential", { key: "OPENSUBTITLES_LOGIN", value: { username: user, password: v } }, function (ok, d) {
                                     reply(ok && d.ok, ok ? Theme.coreText(d.message, d.count) : qsTr("Couldn't save it"))
                                 })
                             } })
                entry.after = function () { settings.load() }
            }
        } else if (a === "setup") {
            win.openSetup()
        } else if (a.indexOf("profile:") === 0) {
            win.editProfile(win.profiles[Number(a.slice(8))], page)
        } else if (a === "profile-add") {
            win.addProfile(page)
        } else if (a === "profile-export") {
            if (win.profile) profileSheet.exportProfile(win.profile.id)
        } else if (a === "profile-import") {
            profilePick.open()
        } else if (a === "auto-login") {
            win.setAutoLogin(!win.autoLogin)
        }
    }

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
        entry.after = function () { settings.load() }
    }

    // the rows on screen follow `lines` in place: a value that changes (a load answering, a toggle)
    // updates its row instead of rebuilding the list, which flickered
    ListModel { id: rows }
    // another section: out, fresh rows (they start at their size, nothing reflows), in
    SequentialAnimation {
        id: swap
        NumberAnimation { target: page; property: "opacity"; to: 0; duration: 90; easing.type: Easing.InQuad }
        ScriptAction { script: { settings.section = menu.currentIndex; page.toTop() } }
        NumberAnimation { target: page; property: "opacity"; to: 1; duration: 180; easing.type: Easing.OutCubic }
    }
    property string shownSection: ""
    onLinesChanged: {
        if (sectionId !== shownSection) {
            shownSection = sectionId
            rows.clear()
        }
        syncRows()
    }
    function norm(l) {
        return { label: l.label || "", detail: l.detail || "", value: l.value || "", checkable: !!l.checkable, checked: !!l.checked,
                 badge: l.badge || "", act: l.act || "", header: !!l.header, icon: l.icon || "", kind: l.kind || "" }
    }
    function syncRows() {
        var L = lines
        for (var i = 0; i < L.length; ++i) {
            var n = norm(L[i])
            if (i >= rows.count) { rows.append(n); continue }
            var c = rows.get(i), same = true
            for (var k in n) if (c[k] !== n[k]) { same = false; break }
            if (!same) rows.set(i, n)
        }
        while (rows.count > L.length) rows.remove(rows.count - 1)
        // something just added: the focus goes to its row
        if (flow.focusAct) {
            var at = L.findIndex(function (l) { return l.act === flow.focusAct })
            if (at >= 0) { page.currentIndex = at; flow.focusAct = "" }
        }
    }

    ListWheel { view: page }
    ListView {
        id: page
        visible: settings.ready
        // the clip is wider than the rows: a lifted row keeps its rounded corners
        readonly property real pad: 24 * settings.u
        anchors { left: menu.right; leftMargin: 80 * settings.u - pad; right: parent.right; rightMargin: Theme.margin - pad; top: menu.top; bottom: parent.bottom }
        topMargin: 12 * settings.u
        bottomMargin: 40 * settings.u
        clip: true
        model: rows
        spacing: 6 * settings.u
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
        preferredHighlightBegin: 100 * settings.u
        preferredHighlightEnd: height - 160 * settings.u
        highlightMoveDuration: 180
        highlightMoveVelocity: -1
        // a whole section stays laid out: the rows' real heights are known, the origin doesn't drift
        cacheBuffer: 6000
        // positionViewAtBeginning() leaves out the top margin once the origin has moved: every
        // section has to start at the same height
        function toTop() {
            currentIndex = 0
            forceLayout()
            contentY = originY - topMargin
        }
        Keys.onLeftPressed: menu.forceActiveFocus()
        Keys.onReturnPressed: if (settings.lines[currentIndex] && !settings.lines[currentIndex].header) settings.run(settings.lines[currentIndex])
        // headers are only titles: the focus steps over them
        function step(d) {
            var i = currentIndex + d
            while (i >= 0 && i < count && settings.lines[i].header) i += d
            if (i < 0 || i >= count) return false
            currentIndex = i
            return true
        }
        Keys.onUpPressed: if (!step(-1)) settings.upFromTop()
        Keys.onDownPressed: step(1)
        onActiveFocusChanged: if (activeFocus && settings.lines[currentIndex] && settings.lines[currentIndex].header) step(1)
        // the view puts its delegates at x 0: the inset (room for the lift) goes on the line inside
        delegate: Item {
            required property var model
            required property int index
            width: page.width
            height: line.height
            Loader {
                id: line
                x: page.pad
                width: page.width - 2 * page.pad
                sourceComponent: model.header ? headerLine : model.kind === "brand" ? brandLine : toggleLine
            }
            Component {
                id: headerLine
                // a section that opens with a header starts where the others' first row does
                Text {
                    height: (index === 0 ? 52 : 90) * settings.u + bottomPadding
                    bottomPadding: 14 * settings.u
                    verticalAlignment: Text.AlignBottom
                    text: model.label
                    color: Theme.fg2
                    font { family: Theme.display; pixelSize: 26 * settings.u; weight: Font.DemiBold }
                }
            }
            Component {
                id: brandLine
                Item {
                    id: br
                    readonly property bool foc: page.currentIndex === index && page.activeFocus
                    readonly property real u: settings.u
                    height: 220 * u
                    Rectangle {
                        anchors.fill: parent
                        radius: 34 * br.u
                        color: br.foc ? "white" : Qt.rgba(1, 1, 1, 0.06)
                        scale: br.foc ? 1.02 : 1
                        Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
                    }
                    Image {
                        id: appIcon
                        x: 34 * br.u
                        anchors.verticalCenter: parent.verticalCenter
                        width: 140 * br.u; height: width
                        source: "qrc:/noonix-tv.svg"
                        sourceSize: Qt.size(width, height)
                    }
                    Column {
                        anchors { left: appIcon.right; leftMargin: 36 * br.u; right: parent.right; rightMargin: 40 * br.u; verticalCenter: parent.verticalCenter }
                        spacing: 6 * br.u
                        Text {
                            text: model.label
                            color: br.foc ? Theme.focusFg : Theme.fg
                            font { family: Theme.display; pixelSize: 44 * br.u; weight: Font.Bold }
                        }
                        Text {
                            visible: model.value !== ""
                            text: qsTr("Version %1").arg(model.value)
                            color: br.foc ? Qt.rgba(0.1, 0.1, 0.12, 0.6) : Theme.fg3
                            font { family: Theme.text; pixelSize: 22 * br.u }
                        }
                        Item { width: 1; height: 8 * br.u }
                        // "created by" in the ui's words, the name always as it's written
                        Text {
                            textFormat: Text.StyledText
                            text: qsTr("Created by %1").arg("<b>aleksa.sh</b>")
                            color: br.foc ? Theme.focusFg : Theme.fg2
                            font { family: Theme.text; pixelSize: 26 * br.u }
                        }
                    }
                    Text {
                        anchors { right: parent.right; rightMargin: 40 * br.u; verticalCenter: parent.verticalCenter }
                        text: "›"
                        color: br.foc ? Theme.focusFg : Theme.fg2
                        font { family: Theme.text; pixelSize: 34 * br.u }
                    }
                    Pointer {}
                }
            }
            Component {
                id: toggleLine
                Toggle {
                    label: model.label
                    detail: model.detail
                    value: model.value
                    checkable: model.checkable
                    checked: model.checked
                    badge: model.badge
                    icon: model.icon
                    focused: page.currentIndex === index && page.activeFocus
                }
            }
        }
    }

    SpeedCheck {
        id: speedCheck
        parent: win.sheetLayer
        anchors.fill: parent
        onMeasured: Api.call("quality.options", {}, function (ok, d) { if (ok) settings.quality = d })
        onClosed: page.forceActiveFocus()
    }

    Choices {
        id: choices
        parent: win.sheetLayer
        anchors.fill: parent
        onClosed: page.forceActiveFocus()
    }

    BindSheet {
        id: bindSheet
        parent: win.sheetLayer
        anchors.fill: parent
        onClosed: page.forceActiveFocus()
        onSaved: function (c) { settings.setApp("controls", c) }
    }

    SiteCard {
        id: siteCard
        parent: win.sheetLayer
        anchors.fill: parent
        onClosed: page.forceActiveFocus()
    }

    TraktCode {
        id: traktCode
        parent: win.sheetLayer
        anchors.fill: parent
        onDone: function (ok) { win.refreshProfiles(); page.forceActiveFocus() }
    }

    SourcesFlow {
        id: flow
        parent: win.sheetLayer
        anchors.fill: parent
        entry: entry
        enterKey: settings.enter
        onBack: page.forceActiveFocus()
    }

    FolderPicker {
        id: profilePick
        parent: win.sheetLayer
        anchors.fill: parent
        files: ["noonix"]
        caption: qsTr("Import a profile")
        onPicked: function (path) { profileSheet.importFile(path) }
        onClosed: if (!profileSheet.visible) page.forceActiveFocus()
    }

    ProfileSheet {
        id: profileSheet
        parent: win.sheetLayer
        anchors.fill: parent
        onClosed: page.forceActiveFocus()
        onImported: { win.refreshProfiles(); settings.load() }
    }

    KeyEntry {
        id: entry
        parent: win.sheetLayer
        anchors.fill: parent
        property var after: null
        onCancel: { close(); after = null; page.forceActiveFocus() }
        onDone: function (v) {
            close()
            var f = after; after = null
            if (f) f(v)
            if (!isOpen) page.forceActiveFocus()
        }
    }
}
