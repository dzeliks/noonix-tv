import QtQuick
import QtQuick.Window
import Noonix.Core
import Noonix.Video

// noonix tv: browse ui over a black scene; during playback the window is transparent and the
// video subsurface below shows through, only the osd draws (windows: the video is drawn in the
// scene, under the ui, and the window stays opaque)
Window {
    id: win
    width: 1920
    height: 1080
    visible: false
    // windows draws the video in the scene (black behind), unless mpv has its own window under
    // this one (hdr): then see-through while video is up
    color: Qt.platform.os === "windows" && !(Video.native && videoUp) ? "black" : "transparent"
    onVideoUpChanged: Video.showNative(videoUp)
    title: "Noonix TV"

    // dev: NOONIX_DEBUG=1 logs where the focus goes
    onActiveFocusItemChanged: if (Desktop.debug) console.log("focus:", activeFocusItem, "active:", active)
    // the 1920x1080 grid fits either way: a 4:3 or 16:10 tablet gets more height, not a narrower page.
    // a narrow window keeps the size until the grid is Theme.minGridW wide (compact layouts below 1200)
    readonly property real u: Math.min(height / 1080 * Desktop.boost, width / Theme.minGridW)
    onUChanged: { Theme.u = u; Theme.gw = width / u; Theme.gh = height / u }
    Binding { target: Theme; property: "minGridW"; value: Desktop.gridW > 0 ? Desktop.gridW : 1920 / Desktop.boost }
    Binding { target: Theme; property: "pointing"; value: Input.pointing === true }
    Binding { target: Theme; property: "dpr"; value: Math.max(1, Screen.devicePixelRatio) }
    Binding { target: Theme; property: "mouseMode"; value: Input.mouseMode === true }
    Timer { interval: 30000; repeat: true; running: true; onTriggered: Theme.nap++ }
    // the window's safe area: backgrounds still go under a cutout, the side margins clear it
    Item { id: safeProbe; anchors.fill: parent }
    Binding { target: Theme; property: "safeSide"; value: Math.max(safeProbe.SafeArea.margins.left, safeProbe.SafeArea.margins.right) }
    Binding { target: Theme; property: "safeBottom"; value: safeProbe.SafeArea.margins.bottom }
    onWidthChanged: Theme.gw = width / u
    onHeightChanged: Theme.gh = height / u

    // ---- state
    property string page: "home"
    property var detailStack: []
    property var profiles: []
    property var profile: null
    readonly property bool playing: Player.state !== "idle"
    property bool videoUp: false          // ui hidden, video visible
    property var playTarget: null
    // the card or page it came from (its title for the sources sheet)
    property var playFrom: null
    property var fallbacks: []            // ranked sources left for one automatic retry
    property bool retried: false
    property string autoReq: ""
    property bool setupDone: true
    property bool autoLogin: false       // off: "who's watching?" after the launch splash
    property bool matchTipOff: true      // "don't show again" on the match tip (settings say otherwise)
    property bool matchTipShown: false   // ok: once per launch
    property bool tipPaused: false
    property bool switchingSource: false // "picture or sound problem": until the next source plays
    property string sourceAddon: ""      // the addon filter on the sources list when one was picked

    function loadProfiles() {
        Api.call("profiles.list", {}, function (ok, d) {
            if (!ok) return
            win.profiles = d.profiles
            for (var i = 0; i < d.profiles.length; ++i) if (d.profiles[i].id === d.current) win.profile = d.profiles[i]
            win.prepareLaunch()
        })
    }
    // the profiles' names and logins changed (settings), nothing else
    function refreshProfiles() {
        Api.call("profiles.list", {}, function (ok, d) {
            if (!ok) return
            win.profiles = d.profiles
            for (var i = 0; i < d.profiles.length; ++i) if (d.profiles[i].id === d.current) win.profile = d.profiles[i]
        })
    }
    Component.onCompleted: {
        Theme.u = u
        Theme.gw = width / u
        Theme.gh = height / u
        loadProfiles()
        Api.call("setup.state", {}, function (ok, d) {
            if (!ok) return
            // nothing else starts: setup on an empty db would only be lost again
            if (d.dataError) { dataError.error = d.dataError; return }
            // set up before but the terms are new: those first, then on as usual
            win.setupDone = d.done && d.termsAgreed
            win.setupKnown = true
            if (!d.done) win.openSetup()
            else if (!d.termsAgreed) setupView.open(true)
            // trakt used to come from a file on the pc: one sign-in inside noonix tv
            win.prepareLaunch()
        })
        Api.call("settings.app", {}, function (ok, d) {
            if (ok) win.autoLogin = !!d.auto_login
            if (ok) win.matchTipOff = !!d.match_tip_off
            if (ok) Theme.lowMode = d.low_memory || "auto"
            // the core keeps playback to 1080p in low memory mode: it needs to know what automatic found
            if (ok && (d.low_ram === true) !== Desktop.lowRam) Api.call("settings.setApp", { key: "low_ram", value: Desktop.lowRam })
            if (ok && d.controls) Input.setBindings(d.controls)
            // the language picked in setup, else what the pc's locale says
            Desktop.setLanguage(ok && d.ui_lang ? d.ui_lang : Desktop.systemLanguage)
            win.settingsKnown = true
            win.prepareLaunch()
        })
        if (splash.visible) splash.forceActiveFocus()
        Api.call("local.start", {})      // whatever this build brings along, in the background
        Api.call("library.scan", {})     // new files in the library folders
        updateCheck.start()
        // a turn later: the player is wired to the core only after the qml has loaded
        if (Desktop.devPlay) Qt.callLater(function () { var dp = JSON.parse(Desktop.devPlay); win.startPlay(dp, dp.stream || null, null) })
    }

    // ---- tv wallpaper: animate it only while our glass shows it, pause it behind opaque pages / video
    readonly property bool wallShown: (page === "search" || page === "settings" || page === "library") && !detailStack.length && !videoUp
    readonly property bool coversWall: visible && visibility !== Window.Minimized && !wallShown
    // only that screen's wallpaper: noonix tv on another monitor leaves it alone
    readonly property bool onTv: !!screen && Desktop.wallpaperOutput !== "" && screen.name === Desktop.wallpaperOutput
    readonly property bool coversTv: coversWall && onTv
    onCoversTvChanged: Remote.setCovered(coversTv)
    // our glass shows the wallpaper: the screensaver's clock steps aside
    readonly property bool glassOnTv: wallShown && onTv && visible && visibility !== Window.Minimized
    onGlassOnTvChanged: Remote.setGlass(glassOnTv)
    onActiveChanged: {
        if (Desktop.debug) console.log("window active:", active)
        if (active && onTv) { Remote.setCovered(coversTv); Remote.setGlass(glassOnTv) }   // someone else may have said otherwise meanwhile
    }

    // ---- glass backdrop: the browse scene at quarter size + a tiny blurred copy (the overlay's pipeline).
    // over video it's the video surface's own quarter-size copy, at most 30 updates a second
    property alias backdropTex: bdTex
    property alias sheetLayer: sheetLayer
    property alias frostTex: frostV
    readonly property bool videoGlass: videoUp && (osd.glassUp || tracks.visible || subPick.visible || sources.visible || matchSheet.visible || timing.visible || matchTip.visible
                                                || toast.visible || switching.visible)
    // android hdr from the decoder has no frames for the glass (it'd keep a stale one)
    readonly property bool backdropOn: !videoUp || (vglass.ready && Video.colour.decoder !== true)
    // the decoder draws under a see-through window: no frames to frost, the video shows through
    readonly property bool videoThrough: videoUp && Video.colour.decoder === true
    readonly property bool backdropLive: !videoUp || videoGlass
    VideoLayer { anchors.fill: parent }
    VideoGlass {
        id: vglass
        surface: Video
        running: win.videoGlass
        onReadyChanged: if (Desktop.debug) console.log("video glass ready:", ready)
        onRunningChanged: if (Desktop.debug) console.log("video glass running:", running)
        width: Math.max(1, Math.round(win.width / 4)); height: Math.max(1, Math.round(win.height / 4))
        visible: false
    }
    ShaderEffect {
        id: vtone
        width: vglass.width; height: vglass.height; visible: false
        property variant source: ShaderEffectSource { sourceItem: vglass; hideSource: true; live: win.videoGlass }
        property real mode: Video.colour.transfer === "pq" ? 1 : Video.colour.transfer === "hlg" ? 2 : 0
        fragmentShader: "qrc:/shaders/vidtone.frag.qsb"
    }
    ShaderEffectSource {
        id: bdTex
        sourceItem: win.videoUp ? vtone : scene
        hideSource: false
        live: win.backdropLive
        mipmap: true
        smooth: true
        // the frost blurs it anyway: a ~1000 px copy keeps animations cheap at 4k
        textureSize: Theme.copySize(win.width, win.height)
        visible: false
    }
    ShaderEffect {
        id: blurH
        width: 240; height: 135; visible: false
        property variant source: bdTex
        property vector2d dir: Qt.vector2d(1 / 240, 0)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: blurHTex; sourceItem: blurH; hideSource: true; live: win.backdropLive; smooth: true; textureSize: Theme.frostSize; visible: false }
    ShaderEffect {
        id: blurV
        width: 240; height: 135; visible: false
        property variant source: blurHTex
        property vector2d dir: Qt.vector2d(0, 1 / 135)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: frostV; sourceItem: blurV; hideSource: true; live: win.backdropLive; smooth: true; textureSize: Theme.frostSize; visible: false }
    // while setup is up, the glass over it refracts its zoomed copy of the app; the app's own glass
    // (the bar) still refracts the app, or it would show a piece of the zoomed copy
    GlassSource { id: setupGlass; sourceItem: setupView.backdropItem; live: setupView.visible }
    function inBrowse(it) {
        for (var p = it; p; p = p.parent) if (p === browse) return true
        return false
    }
    function glassTex(it) { return setupView.visible && !inBrowse(it) ? setupGlass.tex : bdTex }
    function glassFrost(it) { return setupView.visible && !inBrowse(it) ? setupGlass.frost : frostV }

    // ---- browse
    FocusScope {
        id: browse
        anchors.fill: parent
        visible: !win.videoUp
        focus: !win.playing
        Keys.onMenuPressed: function (event) { event.accepted = toast.trigger() }

        Item {
            id: scene
            anchors.fill: parent
            Rectangle { anchors.fill: parent; color: Theme.bg }
            // search and settings sit on the frosted tv wallpaper, like the terminal
            WallGlass {
                anchors.fill: parent
                readonly property bool wanted: win.wallShown
                running: wanted
                hold: !win.playing && win.visible
            }

            // pages take the focus only when it goes down into them (focusPage): a page picked in
            // the bar would pull the focus through all its rows and back, starting every focus
            // animation on the way
            Loader {
                id: homeL
                anchors.fill: parent
                active: true
                visible: win.page === "home" && !win.detailStack.length
                focus: visible && !nav.activeFocus
                sourceComponent: Home {
                    focus: true
                    page: "home"
                    profileId: win.profile ? win.profile.id : 0
                    onOpen: function (it) { win.openItem(it) }
                    onPlay: function (it) { win.playNext(it) }
                    onMenu: function (it, rowId, at) { win.rowMenu(it, rowId, homeL.item, at) }
                    onUpFromTop: nav.forceActiveFocus()
                }
            }
            Loader {
                id: moviesL
                anchors.fill: parent
                active: win.page === "movies" || (!Theme.lowMemory && (item !== null || win.warmed >= 1))
                asynchronous: win.page !== "movies"
                visible: win.page === "movies" && !win.detailStack.length
                focus: visible && !nav.activeFocus
                sourceComponent: Home {
                    focus: true
                    page: "movies"
                    profileId: win.profile ? win.profile.id : 0
                    onOpen: function (it) { win.openItem(it) }
                    onPlay: function (it) { win.playNext(it) }
                    onMenu: function (it, rowId, at) { win.rowMenu(it, rowId, moviesL.item, at) }
                    onUpFromTop: nav.forceActiveFocus()
                }
            }
            Loader {
                id: showsL
                anchors.fill: parent
                active: win.page === "shows" || (!Theme.lowMemory && (item !== null || win.warmed >= 2))
                asynchronous: win.page !== "shows"
                visible: win.page === "shows" && !win.detailStack.length
                focus: visible && !nav.activeFocus
                sourceComponent: Home {
                    focus: true
                    page: "shows"
                    profileId: win.profile ? win.profile.id : 0
                    onOpen: function (it) { win.openItem(it) }
                    onPlay: function (it) { win.playNext(it) }
                    onMenu: function (it, rowId, at) { win.rowMenu(it, rowId, showsL.item, at) }
                    onUpFromTop: nav.forceActiveFocus()
                }
            }
            Loader {
                id: searchL
                anchors.fill: parent
                active: win.page === "search" || (!Theme.lowMemory && (item !== null || win.warmed >= 4))
                asynchronous: win.page !== "search"
                visible: win.page === "search" && !win.detailStack.length
                focus: visible && !nav.activeFocus
                sourceComponent: Search {
                    focus: true
                    onOpen: function (it) { win.openItem(it) }
                    onMenu: function (it, rowId, at) { win.rowMenu(it, rowId, searchL.item, at) }
                    onUpFromTop: nav.forceActiveFocus()
                }
            }
            Loader {
                id: settingsL
                anchors.fill: parent
                active: win.page === "settings" || (!Theme.lowMemory && (item !== null || win.warmed >= 5))
                asynchronous: win.page !== "settings"
                visible: win.page === "settings" && !win.detailStack.length
                focus: visible && !nav.activeFocus
                sourceComponent: Settings { focus: true; onUpFromTop: nav.forceActiveFocus() }
            }
            Loader {
                id: libraryL
                anchors.fill: parent
                active: win.page === "library" || (!Theme.lowMemory && (item !== null || win.warmed >= 3))
                asynchronous: win.page !== "library"
                visible: win.page === "library" && !win.detailStack.length
                focus: visible && !nav.activeFocus
                sourceComponent: Library {
                    focus: true
                    profileId: win.profile ? win.profile.id : 0
                    onOpen: function (it) { win.openItem(it) }
                    onMenu: function (it, rowId, at) { win.rowMenu(it, rowId, libraryL.item, at) }
                    onUpFromTop: nav.forceActiveFocus()
                }
            }
            // built once (warmed with the pages) and kept: opening a title swaps its item, closing
            // fades it out over the page with its content still there
            Loader {
                id: detailsL
                anchors.fill: parent
                readonly property bool shown: win.detailStack.length > 0
                property var shownItem: null
                active: shown || item !== null || win.warmed >= 6
                asynchronous: !shown
                focus: shown
                visible: opacity > 0
                opacity: shown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 220 } }
                sourceComponent: Details {
                    focus: true
                    item: detailsL.shownItem
                    onPlay: function (t, s) { win.startPlay(t, s) }
                    onSources: function (t) { win.openSources(t) }
                    onOpen: function (it) { win.openItem(it) }
                    onMenu: function (it, at) { win.rowMenu(it, "", detailsL.item, at) }
                    onNotice: function (message) { toast.show(message) }
                    onBack: win.back()
                }
            }
        }

        TopNav {
            id: nav
            width: parent.width
            page: win.page
            profile: win.profile
            visible: !win.detailStack.length
            // the page behind changes, focus stays in the bar until down
            onChosen: function (p) { Desktop.mark("page " + p); win.page = p; nav.forceActiveFocus() }
            onProfileRequested: profilePicker.open()
            onEntered: win.focusPage()
            Keys.onDownPressed: win.focusPage()
            // on search the keyboard types: letters go in, backspace is still back
            readonly property bool typing: activeFocus && win.page === "search"
            Keys.onPressed: function (e) {
                if (!typing) return
                if (e.key === Qt.Key_Backspace) {
                    if (searchL.item && searchL.item.query) searchL.item.query = searchL.item.query.slice(0, -1)
                    else win.back()
                    e.accepted = true
                    return
                }
                if (e.text.length === 1 && e.text > " " && !(e.modifiers & Qt.ControlModifier) && searchL.item) {
                    searchL.item.typeFromBar(e.text)
                    e.accepted = true
                }
            }
        }
        // sheets a page opens (qr card, key entry): over the scene, never in it, or their
        // glass would blur their own white parts back in as a glow
        Item { id: sheetLayer; anchors.fill: parent; z: 50 }
        Confirm {
            id: confirmClear
            parent: sheetLayer
            anchors.fill: parent
            onClosed: win.focusPage()
        }

        Keys.onEscapePressed: win.back()
        Keys.onBackPressed: win.back()
    }

    function currentPage() {
        if (detailStack.length) return detailsL
        return { home: homeL, movies: moviesL, shows: showsL, search: searchL, library: libraryL, settings: settingsL }[page] || homeL
    }
    function focusPage() { var l = currentPage(); if (l) l.forceActiveFocus() }
    onPageChanged: {
        if (!nav.activeFocus) focusPage()
        if (Theme.lowMemory) trimLater.restart()
    }
    // low memory: the page just left is gone, its memory back to the system once it's torn down
    Timer { id: trimLater; interval: 2500; onTriggered: Player.trimMemory() }
    Binding { target: Player; property: "lowMemory"; value: Theme.lowMemory }

    function back() {
        if (sources.visible) { sources.close(); return }
        if (menuPopup.visible) { menuPopup.visible = false; focusPage(); return }
        if (profileAdd.visible) { profileAdd.visible = false; profileReturn.forceActiveFocus(); return }
        if (profilePicker.visible) { profilePicker.close(); nav.forceActiveFocus(); return }
        if (detailStack.length) {
            var s = detailStack.slice(); s.pop(); detailStack = s
            focusPage()
            return
        }
        // a finger never sees the focus: back goes straight on
        if (!nav.activeFocus && !Theme.touch) { nav.forceActiveFocus(); return }
        if (page !== "home") { page = "home"; nav.forceActiveFocus(); return }
        if (Theme.touch) { Input.toBackground(); return }
        exitPrompt.open()
    }

    property int detailDepth: 0
    // where each title below the shown one had the focus (the page is one, reused)
    property var detailMarks: []
    onDetailStackChanged: {
        var n = detailStack.length, d = detailsL.item
        if (n) {
            if (detailDepth === 0) {
                // the same title again still loads afresh
                detailsL.shownItem = null
                detailMarks = []
                if (d) d.opened()
            } else if (n > detailDepth) {
                // a title from this one (more like this): it starts at the top, on play
                if (d) { detailMarks = detailMarks.concat([d.mark()]); d.opened() }
            } else if (d) {
                var m = detailMarks.slice()
                d.comeBack = m.pop() || null
                detailMarks = m
            }
            detailsL.shownItem = detailStack[n - 1]
        }
        detailDepth = n
    }

    function openItem(it) {
        // an episode card opens its show on that episode (info, the ones around it, more like
        // this); continue is the first button there
        detailStack = detailStack.concat([it])
    }

    // ---- card options (menu / the pad's create): go to the show, library, remove from a row
    property var menuItem: null
    property string menuRow: ""
    property var menuHome: null
    property rect menuAt: Qt.rect(0, 0, 0, 0)
    property int libraryState: -1          // -1 asking, 0 no, 1 in the library
    property int menuRequest: 0
    readonly property bool menuEpisode: !!menuItem && menuItem.kind === "episode"
    readonly property string menuTitle: !menuItem ? "" : menuEpisode
        ? (menuItem.showTitle || "") + "  ·  S" + menuItem.season + " · E" + menuItem.episode
        : menuItem.title || menuItem.name || ""
    readonly property var menuOptions: {
        var it = menuItem, o = []
        if (!it) return o
        if (menuEpisode) o.push({ label: qsTr("Go to Show"), act: "open" })
        else if (it.kind === "movie") o.push({ label: qsTr("Play"), act: "play" })
        // resume is the default everywhere (apple tv); starting over is one menu away
        if ((it.kind === "episode" || it.kind === "movie") && (it.progress || 0) > 0.01)
            o.push({ label: qsTr("Play from Beginning"), act: "restart" })
        o.push({ label: libraryState === -1 ? qsTr("Checking Library…") : libraryState === -2 ? qsTr("Retry Library") : libraryState === 1 ? qsTr("Remove from Library") : qsTr("Add to Library"), act: "library" })
        var rm = { upnext: qsTr("Remove from Up Next"), "continue": qsTr("Remove from Continue Watching"), "continue-movie": qsTr("Remove from Continue Watching"), recent: qsTr("Remove from Recently Played") }[menuRow]
        if (rm) o.push({ label: rm, act: "dismiss" })
        // watching it starts over: the progress and the plays go (here and on trakt)
        if (it.kind === "movie" || it.kind === "episode" || it.kind === "show") o.push({ label: qsTr("Clear Watch Progress"), act: "clear" })
        return o
    }
    function libraryTarget(it) {
        return { profile: profile ? profile.id : 0, kind: it.kind === "movie" ? "movie" : "show", tmdb: it.kind === "episode" ? it.show : it.id }
    }
    function rowMenu(it, rowId, home, at) {
        if (toast.trigger()) return
        if (!it) return
        menuItem = it; menuRow = rowId; menuHome = home; menuAt = at || Qt.rect(Theme.margin, height / 2, 440 * u, 0)
        if (menuHome) menuHome.menuItem = it
        loadMenuLibrary()
        menuList.currentIndex = 0
        menuPopup.visible = true
        menuList.forceActiveFocus()
    }
    function loadMenuLibrary() {
        libraryState = -1
        var request = ++menuRequest, t = libraryTarget(menuItem)
        Api.call("library.state", t, function (ok, d) {
            if (request === win.menuRequest) win.libraryState = ok ? (d.inLibrary ? 1 : 0) : -2
        })
    }
    function menuRun(o) {
        var it = menuItem
        if (!o || !it) return
        if (o.act === "library" && libraryState < 0) {
            if (libraryState === -2) loadMenuLibrary()
            return
        }
        if (o.act === "dismiss") { dismiss(); return }
        if (o.act === "clear") { clearProgress(); return }
        menuPopup.visible = false
        focusPage()
        if (o.act === "open") {
            detailStack = detailStack.concat([{ kind: "show", id: it.show, title: it.showTitle, backdrop: it.backdrop, poster: it.poster }])
        } else if (o.act === "play") {
            startPlay({ kind: "movie", tmdb: it.id }, null, it)
        } else if (o.act === "restart") {
            startPlay(it.kind === "movie" ? { kind: "movie", tmdb: it.id, start: 0 }
                                          : { kind: "show", tmdb: it.show, season: it.season, episode: it.episode, start: 0 }, null, it)
        } else if (o.act === "library") {
            var t = libraryTarget(it), on = libraryState !== 1
            if (!on && menuHome && menuHome.removeLocal && menuRow.indexOf("library") === 0) menuHome.removeLocal(menuRow, it)
            Api.call("library.set", Object.assign({ on: on }, t), function (ok) {
                refreshLists()
                if (!ok) { toast.show(on ? qsTr("Couldn't add it") : qsTr("Couldn't remove it")); return }
                toast.show(on ? qsTr("Added to Library") : qsTr("Removed from Library"), qsTr("Undo"), function () {
                    Api.call("library.set", Object.assign({ on: !on }, t), function (ok) {
                        if (ok) refreshLists()
                        else toast.show(qsTr("Couldn't undo that change"))
                    })
                })
            })
        }
    }
    // the same title can sit in rows on every page and in the library
    function refreshRows() {
        [homeL, moviesL, showsL].forEach(function (l) { if (l.item) l.item.refreshPersonal() })
    }
    function refreshLists() {
        refreshRows()
        if (libraryL.item) libraryL.item.load()
    }
    // menu > remove: the tile stays and waits out its undo time (cards draw it), then it goes
    property var removals: ({})
    property int removalsVersion: 0
    readonly property int removeMs: 6000
    // as the core hides it: an episode stands for its show, in every row at once
    function itemKey(it) { return !it ? "" : it.kind === "episode" ? "show:" + it.show : it.kind + ":" + it.id }
    function removalOf(it) { return it ? (removals[itemKey(it)] || null) : null }
    function setRemovals(r) { removals = r; removalsVersion++ }
    function dismiss() {
        var it = menuItem
        menuPopup.visible = false
        focusPage()
        var r = removals, k = itemKey(it)
        if (r[k]) return
        r[k] = { item: it, profile: profile.id, total: removeMs, until: Date.now() + removeMs, done: false }
        setRemovals(r)
        armRemovals()
    }
    // in a personal row the tile counts down like a removal; anywhere else a toast holds the undo
    function clearProgress() {
        var it = menuItem, t = libraryTarget(it)
        menuPopup.visible = false
        focusPage()
        // signed in to trakt: its plays go there too, so ask first (and no undo after)
        if (profile && profile.trakt && profile.trakt !== "none") {
            confirmClear.open({
                title: qsTr("Clear Watch Progress?"),
                detail: qsTr("%1 starts over here, and its plays and paused spot are removed from Trakt too.").arg(menuTitle),
                ok: qsTr("Clear"),
                yes: function () {
                    Api.call("progress.clear", t, function (ok) {
                        toast.show(ok ? qsTr("Watch progress cleared") : qsTr("Couldn't clear the progress"))
                        win.refreshLists()
                    })
                }
            })
            return
        }
        if (["upnext", "continue", "continue-movie", "recent"].indexOf(menuRow) >= 0) {
            var r = removals, k = itemKey(it)
            if (r[k]) return
            r[k] = { item: it, profile: profile.id, total: removeMs, until: Date.now() + removeMs, done: false, clear: t }
            setRemovals(r)
            armRemovals()
            return
        }
        toast.show(qsTr("Watch progress cleared"), qsTr("Undo"), function () {}, 6, function () {
            Api.call("progress.clear", t, function (ok) {
                if (!ok) toast.show(qsTr("Couldn't clear the progress"))
                win.refreshLists()
            })
        })
    }
    function undoRemoval(it) {
        var r = removals, k = itemKey(it)
        if (!r[k] || r[k].done) return
        delete r[k]
        setRemovals(r)
        armRemovals()
    }
    function armRemovals() {
        var next = -1
        for (var k in removals) if (!removals[k].done && (next < 0 || removals[k].until < next)) next = removals[k].until
        if (next < 0) { removalTimer.stop(); return }
        removalTimer.interval = Math.max(1, next - Date.now())
        removalTimer.restart()
    }
    Timer {
        id: removalTimer
        onTriggered: {
            var now = Date.now()
            for (var k in win.removals) if (!win.removals[k].done && win.removals[k].until <= now + 20) win.commitRemoval(k)
            win.armRemovals()
        }
    }
    // the line ran out: the title leaves its rows and is hidden here (trakt keeps it) until it's played
    function commitRemoval(k) {
        var rec = removals[k], it = rec.item
        rec.done = true
        ;[homeL, moviesL, showsL].forEach(function (l) { if (l.item) l.item.leave(it) })
        Api.call(rec.clear ? "progress.clear" : "home.dismiss", rec.clear || { item: it, profile: rec.profile }, function (ok) {
            if (ok) return
            toast.show(rec.clear ? qsTr("Couldn't clear the progress") : qsTr("Couldn't remove it"))
            var r = win.removals; delete r[k]; win.setRemovals(r)
            refreshRows()
        })
        forgetLater.start()
    }
    // every row has had time to animate it out
    Timer {
        id: forgetLater
        interval: 900
        onTriggered: {
            var r = win.removals, any = false
            for (var k in r) if (r[k].done) { delete r[k]; any = true }
            if (any) { win.setRemovals(r); win.refreshRows() }
        }
    }

    // ---- sources sheet
    function openSources(t, known) {
        playTarget = t
        var d = detailStack.length ? detailStack[detailStack.length - 1] : null
        var f = playFrom || {}
        var label = d ? (d.title || d.showTitle || "") : (f.showTitle || f.title || "")
        if (t.season) label += (label ? "  ·  " : "") + "S" + t.season + " · E" + t.episode
        sources.visible = true
        sources.start(t, label, known)
    }

    // ---- the match sheet's answers: remember a good one, fix a bad one
    function openTiming() {
        osd.hide()
        timing.open()
    }
    function matchAction(what) {
        if (what === "timing") { openTiming(); return }
        if (what === "good") {
            Api.call("match.rate", { verdict: "good" }, function (ok) {
                toast.show(ok ? qsTr("Saved · Noonix TV picks these again") : qsTr("Couldn't save that"))
            })
            return
        }
        Api.call("match.rate", { verdict: "bad", reason: what }, function (ok) {
            if (!ok) { toast.show(qsTr("Couldn't save that")); return }
            if (what === "av") nextSource(); else nextSubs(what)
        })
    }
    function nextSubs(why) {
        switching.start(qsTr("Finding other subtitles…"))
        Api.call("match.nextSub", { tracks: Player.subtitleTracks }, function (ok, d) {
            switching.stop()
            var more = d && d.left > 0 ? "  ·  " + qsTr("%n more to try", "", d.left) : ""
            if (!ok) toast.show(qsTr("Couldn't look for other subtitles"))
            else if (d.select) { Player.setSubtitleTrack(d.select); toast.show(qsTr("Subtitles switched") + more) }
            else if (d.added) toast.show(qsTr("Subtitles switched") + more)
            // nothing else fits: the timing by hand
            else if (why === "sync") { toast.show(qsTr("No other subtitles · set the timing")); openTiming() }
            else toast.show(qsTr("No other subtitles in your languages"))
        })
    }
    function nextSource(why, keepIfNone) {
        // why: the app's own reason (an error clip); a report needs none. keepIfNone: nothing else
        // left keeps this one playing (dolby vision 5 still plays, only the colours are off)
        if (why) toast.show(why)
        switching.start(qsTr("Switching source…"))
        Api.call("match.nextSource", { position: Player.position, addon: win.sourceAddon }, function (ok, d) {
            if (ok && d.stream) {
                win.playTarget = d.target
                win.retried = true
                win.switchingSource = true
                Player.play(Object.assign({}, d.target, { stream: d.stream, start: d.start }))
            } else {
                switching.stop()
                if (keepIfNone) { toast.show(qsTr("No other version left: the colours may look off")); return }
                toast.show(qsTr("No other source left"))
                if (d && d.target) win.playTarget = d.target
                if (win.playTarget) win.openSources(win.playTarget)
            }
        })
    }

    // ---- playback
    // up next: the next episode on the source that was playing, or the ranked best
    function playNext(it) {
        if (it.kind === "movie") startPlay({ kind: "movie", tmdb: it.id }, null, it)
        else startPlay({ kind: "show", tmdb: it.show, season: it.season, episode: it.episode }, null, it)
    }
    function startPlay(t, stream, from) {
        playTarget = t
        playFrom = from || null
        // played before its line ran out: it isn't going anywhere
        var pending = removals[(t.kind === "movie" ? "movie:" : "show:") + t.tmdb]
        if (pending) undoRemoval(pending.item)
        retried = false
        sourceAddon = ""
        if (stream) { fallbacks = []; begin(stream); return }
        finder.open(t, from, true)
        autoReq = "auto-" + Date.now()
        var req = autoReq
        Api.call("streams.list", Object.assign({ req: req }, t), function (ok, d) {
            if (req !== win.autoReq) return
            var list = ok && d ? d.streams || [] : []
            if (!list.length) {
                finder.close()
                toast.show(qsTr("No sources found"))
                openSources(t, ok && d && d.done ? d : null)
                return
            }
            win.fallbacks = list.slice(1, 4)
            win.begin(list[0])
        })
    }
    function begin(stream) {
        if (!finder.active) finder.open(playTarget)
        finder.starting(stream)
        Player.play(Object.assign({}, playTarget, { stream: stream }))
    }
    function cancelFind() {
        autoReq = ""
        if (Player.state !== "idle") Player.stop()
        finder.close()
        browse.forceActiveFocus()
        focusPage()
    }
    function closePickers() {
        if (tracks.visible) tracks.close()
        if (subPick.visible) subPick.close()
        if (matchSheet.visible) matchSheet.close()
    }
    function stopPlayback() {
        closePickers()
        if (timing.visible) timing.finish(false)
        switching.stop()
        switchingSource = false
        tipTimer.stop()
        matchTip.close()
        Player.stop()
        win.videoUp = false
        cover.opacity = 1
        coverOut.restart()
        browse.forceActiveFocus()
        focusPage()
        if (homeL.item) homeL.item.refreshPersonal()
        if (detailsL.item) detailsL.item.refresh()
    }
    Connections {
        target: Player
        function onStateChanged() {
            var s = Player.state
            if (win.switchingSource && (s === "playing" || s === "error")) {
                win.switchingSource = false
                switching.stop()
                // what it switched to, as the match sheet names it
                if (s === "playing") Api.call("match.state", {}, function (ok, d) {
                    var label = ok && d && d.release ? d.release.label : ""
                    toast.show(label ? qsTr("Switched to %1").arg(label) : qsTr("Source switched"))
                })
            }
            if (s === "playing" && !win.videoUp) {
                // cut, never fade: hdr video under a fading window dips (kwin blends in linear light)
                win.videoUp = true
                cover.opacity = 0
                finder.close()
                osd.forceActiveFocus()
                if (!win.matchTipOff && !win.matchTipShown) tipTimer.restart()
            } else if (s === "error") {
                if (!win.retried && win.fallbacks.length) {
                    win.retried = true
                    toast.show(qsTr("That source didn't play, trying another"))
                    var next = win.fallbacks.shift()
                    win.begin(next)
                } else {
                    finder.close()
                    toast.show(qsTr("Couldn't play this source"))
                    win.stopPlayback()
                    if (win.playTarget) win.openSources(win.playTarget)
                }
            }
        }
    }

    // black between the ui and the video (both ways)
    Rectangle {
        id: cover
        anchors.fill: parent
        color: "black"
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { enabled: !win.videoUp; NumberAnimation { duration: 240 } }
        Timer { id: coverOut; interval: 60; onTriggered: cover.opacity = 0 }
    }

    // the glass can't frost this picture: a sheet over it would show the line through it
    SubText {
        anchors.fill: parent
        covered: tracks.visible || subPick.visible || sources.visible || matchSheet.visible || matchTip.visible || switching.visible
    }

    Osd {
        id: osd
        anchors.fill: parent
        // the tip pauses the video: no controls behind it
        visible: win.videoUp && !matchTip.visible
        focus: win.playing
        onExit: win.stopPlayback()
        // one picker at a time, its own button closes it
        onPickTracks: function (kind, x, w) {
            var same = tracks.visible && tracks.kind === kind
            win.closePickers()
            if (!same) tracks.open(kind, x, w)
        }
        onRateMatch: function (x, w) {
            var same = matchSheet.visible
            win.closePickers()
            if (!same) matchSheet.open(x, w)
        }
        pickerOpen: tracks.visible || subPick.visible || matchSheet.visible
    }
    Finder {
        id: finder
        anchors.fill: parent
        onCancel: win.cancelFind()
    }
    Tracks {
        id: tracks
        anchors.fill: parent
        onClosed: osd.forceActiveFocus()
        onAddFile: win.addSubFile()
    }
    FolderPicker {
        id: subPick
        anchors.fill: parent
        z: 5
        files: ["srt", "ass", "ssa", "vtt", "sub"]
        media: true
        caption: qsTr("Add a subtitle file")
        onClosed: {
            if (win.videoUp) osd.forceActiveFocus()
            win.releaseSubs()
        }
        onPicked: function (path) { win.importSub(path) }
    }
    Match {
        id: matchSheet
        anchors.fill: parent
        onClosed: if (!timing.visible) osd.forceActiveFocus()
        onChosen: function (what) { win.matchAction(what) }
    }
    Timing {
        id: timing
        anchors.fill: parent
        onClosed: function (saved) {
            osd.forceActiveFocus()
            if (saved) Api.call("match.offset", { ms: Math.round(Player.subDelay * 1000) }, function (ok) {
                toast.show(ok ? qsTr("Timing kept for these subtitles") : qsTr("Couldn't keep the timing"))
            })
        }
    }
    // the first play: what the match button is for, once the picture has settled
    Timer {
        id: tipTimer
        interval: 2500
        onTriggered: {
            if (Player.state !== "playing" || matchSheet.visible || timing.visible || tracks.visible || sources.visible) return
            win.matchTipShown = true
            win.tipPaused = !Player.paused
            if (win.tipPaused) Player.setPaused(true)
            osd.hide()
            matchTip.open()
        }
    }
    MatchTip {
        id: matchTip
        anchors.fill: parent
        onDone: function (forever) {
            if (forever) {
                win.matchTipOff = true
                Api.call("settings.setApp", { key: "match_tip_off", value: true })
            }
            if (win.tipPaused) Player.setPaused(false)
            win.tipPaused = false
            osd.forceActiveFocus()
        }
    }
    Connections {
        target: Player
        function onNotice(text) { toast.show(text) }
        // played on by hand meanwhile: not held any more
        function onPausedChanged() { if (!Player.paused) win.subHeld = false }
    }
    // a subtitle search or file pick holds the picture, and plays on after if it was playing
    property int subHolds: 0
    property bool subHeld: false
    function holdForSubs() {
        if (subHolds++ === 0 && !Player.paused) {
            Player.setPaused(true)
            subHeld = true
        }
    }
    function releaseSubs() {
        if (subHolds === 0 || --subHolds > 0) return
        if (subHeld && win.videoUp) Player.setPaused(false)
        subHeld = false
    }
    // android: the system's picker (the in-app browser can't see files outside media folders there)
    readonly property bool systemFiles: Theme.android && Input.canPickFile()
    function addSubFile() {
        holdForSubs()
        if (systemFiles) Input.pickFile("sub", 8 << 20)
        else subPick.open()
    }
    function importSub(path) {
        Api.call("playback.importSub", { path: path }, function (ok) {
            if (!ok) toast.show(qsTr("Couldn't read that file"))
        })
    }
    Connections {
        target: Api
        // the source sent an error clip instead of the title: the next one, like a report
        function onPushed(name, d) {
            if (!win.playing) return
            if (name === "playback.dud") win.nextSource(qsTr("That source sent an error clip · trying another"))
            else if (name === "playback.dv") win.nextSource(qsTr("Dolby Vision without HDR10 · switching to another version"), true)
        }
    }

    Sources {
        id: sources
        anchors.fill: parent
        visible: false
        function close() { visible = false; win.focusPage() }
        onPick: function (s) {
            visible = false
            win.sourceAddon = sources.only
            win.retried = true
            win.begin(s)
        }
        Keys.onEscapePressed: close()
        Keys.onBackPressed: close()
    }

    // options for a card (menu key / the pad's create button): a glass popover above the card
    Item {
        id: menuPopup
        anchors.fill: parent
        visible: false
        onVisibleChanged: {
            if (!visible && win.menuHome) win.menuHome.menuItem = null
            if (visible) popIn.restart()
        }
        readonly property real u: win.u
        // it grows out of the card it's for
        property real pop: 1
        NumberAnimation { id: popIn; target: menuPopup; property: "pop"; from: 0; to: 1; duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
        opacity: Math.min(1, pop * 2)
        transform: Scale {
            origin.x: Math.max(optPanel.x, Math.min(optPanel.x + optPanel.width, win.menuAt.x + win.menuAt.width / 2))
            origin.y: optPanel.y > win.menuAt.y ? optPanel.y : optPanel.y + optPanel.height
            xScale: 0.88 + 0.12 * menuPopup.pop; yScale: xScale
        }
        // a click beside it only closes it
        Shield { onOutside: win.back() }
        Glass {
            id: optPanel
            width: Math.max(440 * win.u, win.menuAt.width)
            height: optHead.height + menuList.height + 2 * 16 * win.u
            // above the card, left edges aligned; below it when there's no room
            x: Math.max(40 * win.u, Math.min(win.menuAt.x, win.width - width - 40 * win.u))
            y: Math.max(120 * win.u, Math.min(win.height - height - 40 * win.u,
                win.menuAt.y - height - 20 * win.u > 120 * win.u ? win.menuAt.y - height - 20 * win.u : win.menuAt.y + win.menuAt.height + 20 * win.u))
            radius: 40 * win.u                 // rows 24 + inset 16
            kind: "panel"
        }
        MouseArea { anchors.fill: optPanel; hoverEnabled: true; acceptedButtons: Qt.AllButtons }
        Text {
            id: optHead
            x: optPanel.x + 16 * win.u + 30 * win.u
            y: optPanel.y + 16 * win.u
            width: optPanel.width - 2 * (16 + 30) * win.u
            height: 64 * win.u
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: win.menuTitle
            color: Theme.fg2
            font { family: Theme.display; pixelSize: 24 * win.u; weight: Font.DemiBold }
        }
        ListView {
            id: menuList
            x: optPanel.x + 16 * win.u
            y: optHead.y + optHead.height
            width: optPanel.width - 32 * win.u
            height: win.menuOptions.reduce(function (h, o) { return h + (o.act === "dismiss" ? 108 : 84) * win.u }, 0)
            interactive: false
            model: win.menuOptions
            keyNavigationEnabled: true
            delegate: Toggle {
                required property var modelData
                required property int index
                width: menuList.width
                height: (modelData.act === "dismiss" ? 108 : 84) * win.u
                label: modelData.label
                wrapLabel: true
                opacity: modelData.act === "library" && win.libraryState === -1 ? 0.5 : 1
                checkable: false
                grow: 1
                focused: ListView.isCurrentItem && menuList.activeFocus
            }
            Keys.onReturnPressed: win.menuRun(win.menuOptions[currentIndex])
            Keys.onEnterPressed: win.menuRun(win.menuOptions[currentIndex])
            Keys.onEscapePressed: win.back()
            Keys.onMenuPressed: win.back()
        }
    }

    // profiles
    Item {
        id: profilePicker
        anchors.fill: parent
        visible: false
        function open(noFocus) {
            for (var i = 0; i < win.profiles.length; ++i) if (win.profile && win.profiles[i].id === win.profile.id) profList.currentIndex = i
            pickerFade.stop()
            pickerFade.to = 1
            visible = true
            pickerFade.start()
            if (!noFocus) profList.forceActiveFocus()
        }
        function close() {
            pickerFade.stop()
            pickerFade.to = 0
            pickerFade.start()
        }
        opacity: 0
        NumberAnimation {
            id: pickerFade
            target: profilePicker; property: "opacity"; duration: 240; easing.type: Easing.OutCubic
            onFinished: if (to === 0) profilePicker.visible = false
        }
        // the page behind, frosted
        Glass { anchors.fill: parent; kind: "panel"; radius: 0; refraction: 0; dim: Theme.veil }
        Shield {}
        Text {
            anchors { horizontalCenter: parent.horizontalCenter; bottom: profList.top; bottomMargin: (Theme.short ? 72 : 96) * win.u }
            text: qsTr("Who's watching?")
            color: Theme.fg
            font { family: Theme.display; pixelSize: 56 * win.u; weight: Font.Bold }
        }
        ListWheel { view: profList; across: true }
        ListView {
            id: profList
            anchors.centerIn: parent
            orientation: ListView.Horizontal
            width: Math.min(parent.width - 2 * Theme.margin, count * 240 * win.u + (count - 1) * 60 * win.u)
            // short screens: no slack under the names, so the gaps above and below match
            height: (Theme.short ? 270 : 320) * win.u
            spacing: 60 * win.u
            model: win.profiles.concat([{ id: -1 }])
            keyNavigationEnabled: true
            // the profiles, then "add profile"
            delegate: Column {
                required property var modelData
                required property int index
                readonly property bool foc: ListView.isCurrentItem && Theme.lit(profList.activeFocus, profPt)
                readonly property bool adder: modelData.id === -1
                readonly property bool current: !!win.profile && win.profile.id === modelData.id
                width: 240 * win.u
                spacing: 24 * win.u
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 200 * win.u; height: width
                    Pointer { id: profPt }
                    scale: parent.foc ? 1.12 : 1
                    Behavior on scale { SpringAnimation { spring: Theme.springK; damping: Theme.springDamp; epsilon: 0.0005 } }
                    Avatar {
                        visible: !parent.parent.adder
                        size: parent.width
                        colour: modelData.color || "green"
                        image: modelData.avatar || ""
                        letter: (modelData.name || "").charAt(0).toUpperCase()
                    }
                    Rectangle {
                        visible: parent.parent.adder
                        anchors.fill: parent
                        radius: width / 2
                        color: Qt.rgba(1, 1, 1, parent.parent.foc ? 0.22 : 0.1)
                        Symbol { anchors.centerIn: parent; width: parent.width * 0.36; height: width; name: "plus"; weight: 2.4; color: Theme.fg }
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.width: 6 * win.u
                        border.color: "white"
                        opacity: parent.parent.foc ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 140 } }
                    }
                    // who is watching now
                    Rectangle {
                        visible: parent.parent.current
                        anchors { right: parent.right; bottom: parent.bottom; margins: 4 * win.u }
                        width: 52 * win.u; height: width; radius: width / 2
                        color: "white"
                        Symbol { anchors.centerIn: parent; width: 30 * win.u; height: width; name: "check"; weight: 3; color: Theme.focusFg }
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: parent.adder ? qsTr("Add Profile") : modelData.name
                    color: parent.foc || Theme.touch ? Theme.fg : Theme.fg2
                    font { family: Theme.display; pixelSize: 32 * win.u; weight: Font.DemiBold }
                }
            }
            Keys.onReturnPressed: {
                if (currentIndex === win.profiles.length) {
                    win.addProfile(profList)
                    return
                }
                var p = win.profiles[currentIndex]
                if (!p) return
                Api.call("profiles.select", { id: p.id }, function (ok) {
                    if (!ok) { toast.show(qsTr("Couldn't switch profile")); return }
                    toast.shown = false
                    win.profile = p
                    profilePicker.close()
                    win.detailStack = []
                    nav.forceActiveFocus()
                })
            }
            Keys.onEscapePressed: win.back()
            Keys.onMenuPressed: {
                var p = win.profiles[currentIndex]
                if (p) win.editProfile(p, profList)
            }
            Keys.onDownPressed: autoLoginLine.forceActiveFocus()
        }
        // on: noonix tv opens straight on the last profile; off: it asks here every time
        Toggle {
            id: autoLoginLine
            anchors { horizontalCenter: parent.horizontalCenter; top: profList.bottom; topMargin: (Theme.short ? 24 : 64) * win.u }
            u: win.u * 1.25
            width: 800 * win.u
            label: qsTr("Sign in automatically")
            detail: qsTr("Open on the last profile without asking")
            checked: win.autoLogin
            focused: activeFocus
            Keys.onUpPressed: profList.forceActiveFocus()
            Keys.onEscapePressed: win.back()
            Keys.onReturnPressed: win.setAutoLogin(!win.autoLogin)
            Keys.onEnterPressed: win.setAutoLogin(!win.autoLogin)
        }
    }

    function openSetup() { setupView.open() }
    Setup {
        id: setupView
        anchors.fill: parent
        onFinished: {
            // the terms only, at launch: who's watching comes after them
            if (!win.setupDone) {
                win.setupDone = true
                if (setupView.termsOnly && !win.autoLogin && win.profiles.length) { profilePicker.open(); return }
            }
            win.loadProfiles()
            if (homeL.item) homeL.item.refreshPersonal()
            browse.forceActiveFocus()
            win.focusPage()
        }
    }

    // profiles are edited from the picker (menu on one) and from settings > profiles
    property Item profileReturn: profList
    function editProfile(p, from) { if (!p) return; profileReturn = from; profileAdd.openEdit(p) }
    function addProfile(from) { profileReturn = from; profileAdd.open(profiles.map(function (p) { return p.color })) }
    function setAutoLogin(on) {
        autoLogin = on
        Api.call("settings.setApp", { key: "auto_login", value: on })
    }
    // the scene's backdrop doesn't have the picker: the card over it gets its own copy to refract
    readonly property bool pickerGlass: profileAdd.visible && profilePicker.visible
    ShaderEffectSource {
        id: pickerTex
        sourceItem: profilePicker
        live: win.pickerGlass
        mipmap: true
        smooth: true
        textureSize: Theme.copySize(win.width, win.height)
        visible: false
    }
    ShaderEffect {
        id: pickerBlurH
        width: 240; height: 135; visible: false
        property variant source: pickerTex
        property vector2d dir: Qt.vector2d(1 / 240, 0)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: pickerBlurHTex; sourceItem: pickerBlurH; hideSource: true; live: win.pickerGlass; smooth: true; textureSize: Theme.frostSize; visible: false }
    ShaderEffect {
        id: pickerBlurV
        width: 240; height: 135; visible: false
        property variant source: pickerBlurHTex
        property vector2d dir: Qt.vector2d(0, 1 / 135)
        property real sigma: 2.8
        fragmentShader: "qrc:/shaders/blur.frag.qsb"
    }
    ShaderEffectSource { id: pickerFrost; sourceItem: pickerBlurV; hideSource: true; live: win.pickerGlass; smooth: true; textureSize: Theme.frostSize; visible: false }
    ProfileAdd {
        id: profileAdd
        anchors.fill: parent
        backdrop: win.pickerGlass ? pickerTex : win.glassTex(profileAdd)
        frost: win.pickerGlass ? pickerFrost : win.glassFrost(profileAdd)
        onCancel: { visible = false; win.profileReturn.forceActiveFocus() }
        onDone: function (p) {
            visible = false
            var edited = !!editId
            win.loadProfiles()
            if (edited && win.profile && win.profile.id === p.id) win.profile = Object.assign({}, win.profile, p)
            win.profileReturn.forceActiveFocus()
            if (!edited) toast.show(qsTr("Added %1").arg(p.name))
        }
    }

    // the page the wheel scrolls in pixels: nothing over it, and it knows how
    function wheelPage() {
        if (win.videoUp || win.playing || finder.visible || sources.visible || profilePicker.visible || profileAdd.visible
                || setupView.visible || exitPrompt.visible || splash.visible)
            return null
        var l = currentPage()
        return l && l.item && l.item.wheelScroll ? l.item : null
    }
    // the card under the mouse (card options on right click); covered by a sheet there's none
    property var pointedCard: null
    // the mouse everywhere: right click (or the side back button) is back, or a card's options, the
    // wheel moves the list under the mouse or the page, never the focus (only over the video it's the arrows)
    Item {
        anchors.fill: parent
        z: 20
        TapHandler {
            // a mouse's right or back button; a touch has no buttons, every tap would count
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            acceptedButtons: Qt.RightButton | Qt.BackButton
            onTapped: function (point, button) {
                if (button === Qt.RightButton && win.pointedCard) {
                    win.pointedCard.go()
                    Remote.pointerKey("MENU")
                } else {
                    Remote.pointerKey("BACK")
                }
            }
        }
        // one handler sees one orientation only: a sideways swipe or tilt needs its own
        WheelHandler {
            id: wheelUpDown
            property real acc: 0
            property real accX: 0
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            function step(w) {
                // scrolling away from the options closes them
                if (menuPopup.visible) { win.back(); return }
                var across = w.angleDelta.y === 0 || (w.modifiers & Qt.ShiftModifier) !== 0
                var list = across ? Theme.wheelRow : Theme.wheelList
                if (list && list.view.visible) { list.scroll(w); return }
                var page = across ? null : win.wheelPage()
                if (page) { page.wheelScroll(w); return }
                if (!win.videoUp && !win.playing) return
                // a touchpad coasting after the fingers lift would keep stepping on its own
                if (w.phase === Qt.ScrollMomentum) return
                var dx = w.angleDelta.x, dy = w.angleDelta.y
                if (w.modifiers & Qt.ShiftModifier) { dx = dy; dy = 0 }
                acc += dy; accX += dx
                // over the video the mouse stays the mouse: up and down turn the volume (like its slider),
                // sideways seeks 10 s
                var vol = Player.muted ? 0 : Player.volume
                while (acc >= 120) { acc -= 120; vol += 5 }
                while (acc <= -120) { acc += 120; vol -= 5 }
                if (vol !== (Player.muted ? 0 : Player.volume)) Player.setVolume(vol)
                while (accX >= 120) { accX -= 120; Player.seek(-10) }
                while (accX <= -120) { accX += 120; Player.seek(10) }
                osd.show()
            }
            onWheel: function (w) { step(w) }
        }
        WheelHandler {
            orientation: Qt.Horizontal
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function (w) { if (w.angleDelta.y === 0) wheelUpDown.step(w) }
        }
    }

    ExitPrompt {
        id: exitPrompt
        anchors.fill: parent
        z: 9
        onStay: { close(); nav.forceActiveFocus() }
        onLeave: Qt.quit()
    }
    // holding back (keyboard, pad) leaves from anywhere
    Connections {
        target: Input
        function onHoldBack() { Qt.quit() }
        function onFilePicked(tag, path) {
            if (tag !== "sub") return
            if (path === "!big") toast.show(qsTr("That file is too big"))
            else if (path === "!fail") toast.show(qsTr("Couldn't read that file"))
            else if (path && win.videoUp) win.importSub(path)
            win.releaseSubs()
            if (win.videoUp) osd.forceActiveFocus()
        }
    }
    // a word from the core (tmdb refused the key, ...)
    Connections {
        target: Api
        function onPushed(name, d) {
            if (name === "notice" && d && d.message) toast.notify(qsTranslate("core", d.message))
            // a library scan finished: its rows follow
            if (name === "library") refreshRows()
            // a tv wants this computer's torrents: allowed once, by address
            if (name === "tvServer.ask" && d && d.ip) {
                var who = d.device === "lg" ? qsTr("An LG TV") : d.device === "samsung" ? qsTr("A Samsung TV") : qsTr("A device")
                tvAsk.back = win.activeFocusItem
                tvAsk.open({ title: qsTr("Allow this TV?"), ok: qsTr("Allow"),
                    detail: qsTr("%1 at %2 wants to play torrents through this computer. Allow only TVs in your home: what they download is your responsibility, as if you watched it here.").arg(who).arg(d.ip),
                    yes: function () { Api.call("tvServer.allow", { ip: d.ip, allow: true }, function () {}) },
                    no: function () { Api.call("tvServer.allow", { ip: d.ip, allow: false }, function () {}) } })
            }
        }
    }

    // a tv asking for this computer's torrents: over everything, focus goes back where it was
    Confirm {
        id: tvAsk
        property Item back: null
        anchors.fill: parent
        z: 9
        onClosed: { if (back) back.forceActiveFocus(); else win.focusPage(); back = null }
    }

    TraktChoice {
        id: traktChoice
        anchors.fill: parent
        z: 9
        onChosen: win.refreshLists()
    }
    Toast {
        id: toast
        z: 10
        held: !win.watching
        // under the bar, or under the player's clock and end time
        atY: (win.videoUp ? 168 : 140) * u
    }
    // someone is watching: setup is done, the splash and "who's watching?" are gone. from then on
    // news can show; a profile chosen with a trakt login to redo hears about it (that one only)
    readonly property bool watchingNow: setupDone && !!profile && !splash.visible && !profilePicker.visible
    property bool watching: false
    onWatchingNowChanged: if (watchingNow) { watching = true; reloginCheck() }
    onProfileChanged: { removalTimer.stop(); setRemovals({}); if (watching) reloginCheck() }
    function reloginCheck() {
        reloginHint.stop()
        if (profile && profile.traktRelogin) reloginHint.start()
    }
    Switching {
        id: switching
        anchors.centerIn: parent
        z: 9
    }
    Timer {
        id: reloginHint
        interval: 3000
        onTriggered: if (!win.videoUp && win.profile && win.profile.traktRelogin) toast.notify(qsTr("Sign in to Trakt once more: Settings › Accounts"))
    }
    // a new release: one quiet line after launch, never over a video
    Timer {
        id: updateCheck
        interval: 20000
        onTriggered: Api.call("update.check", { auto: true }, function (ok, d) {
            if (ok && d.available && !win.videoUp)
                toast.notify(qsTr("Noonix TV %1 is out  ·  Settings › About").arg(d.latest))
        })
    }

    // launch splash over everything until it has played; then home, setup or "who's watching?"
    Splash {
        id: splash
        z: 30
        anchors.fill: parent
        visible: Desktop.splash
        fast: Core.appFlag("fast_intro")
        ui: win.launchPicker ? profilePicker : browse
        ready: win.homeReady || setupView.visible
        onFinished: {
            if (setupView.visible) return
            if (win.launchPicker && profilePicker.visible) profList.forceActiveFocus()
            else { browse.forceActiveFocus(); win.focusPage() }
        }
    }
    // over the splash too: the launch stops here
    DataError {
        id: dataError
        z: 31
        anchors.fill: parent
        onLeave: Qt.quit()
    }
    // the page the splash reveals is set up underneath while it still holds: home, or
    // "who's watching?" (no glimpse of home first, no hitch when it starts moving)
    property bool launchPicker: false
    property bool setupKnown: false
    property bool settingsKnown: false
    function prepareLaunch() {
        if (!splash.visible || splash.phase !== "waiting" || launchPicker) return
        if (!setupKnown || !settingsKnown || !profiles.length) return
        if (setupDone && !autoLogin) {
            launchPicker = true
            profilePicker.open(true)
        }
    }
    readonly property bool homeReady: homeL.item ? homeL.item.marked : false
    // the other pages build one by one while home sits idle, so a first visit doesn't stall
    property int warmed: 0
    Timer {
        interval: 1500
        repeat: true
        running: win.warmed < 6 && win.homeReady && !!win.profile && !win.playing && !splash.visible && !Theme.lowMemory
        onTriggered: win.warmed++
    }
    // every face the ui draws with, opened while home sits idle: a first use (details, settings)
    // otherwise reads the font file from disk mid-frame. one every 150 ms
    readonly property var faces: {
        var out = [], fams = [Theme.display, Theme.text, Theme.rounded], ws = [Font.Normal, Font.Medium, Font.DemiBold, Font.Bold]
        for (var f = 0; f < fams.length; ++f) for (var w = 0; w < ws.length; ++w) out.push({ family: fams[f], weight: ws[w] })
        return out
    }
    property int facesWarm: 0
    Timer {
        interval: 150
        repeat: true
        running: win.facesWarm < win.faces.length && win.homeReady && !win.playing
        onTriggered: win.facesWarm++
    }
    Repeater {
        model: win.facesWarm
        Text {
            required property int index
            opacity: 0
            text: "Ag"
            font { family: win.faces[index].family; weight: win.faces[index].weight; pixelSize: 26 * win.u }
        }
    }
    Connections {
        target: Remote
        function onRevealed() { splash.revealed = true }
    }
    // no launch card on a desk monitor or with the intro; with the fast splash on the tv the
    // overlay says when its card is gone, else (started some other way) go anyway
    onVisibleChanged: if (visible && splash.visible) revealLater.start()
    Timer { id: revealLater; interval: win.onTv && Desktop.splashFast ? 2000 : 0; onTriggered: { splash.revealed = true; readyLater.start() } }
    Timer { id: readyLater; interval: 3000; onTriggered: splash.ready = true }
}
