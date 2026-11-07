import QtQuick

// a movie or a show: backdrop, logo, meta, actions, seasons + episodes, more like this
FocusScope {
    id: page
    property var item: null              // row item (movie, show or episode)
    property var details: null
    property var season: null
    property int seasonNo: 1
    readonly property real u: Theme.u
    // a phone in landscape: the episode cards and their two lines still fit the first screen,
    // the logo gives up the room, the plot runs down beside the buttons
    readonly property bool tight: Theme.short
    // under the episode row's lines: the focused card's lift pushes them down
    readonly property real edge: (tight ? 36 : 44) * u
    // tight: smaller buttons and pills rather than the story moving up; one even gap between the rows
    readonly property real bu: u * (tight ? 0.85 : 1)
    readonly property real cardW: 400 * u
    readonly property bool isMovie: item && item.kind === "movie"
    readonly property int tmdbId: !item ? 0 : (item.kind === "episode" ? item.show : item.id)
    property bool inLibrary: false
    property bool libraryReady: false
    property bool libraryBusy: false
    property bool ready: false
    property int revision: 0
    property int libraryRequest: 0
    function loadLibrary() {
        libraryReady = false
        var request = ++libraryRequest, want = tmdbId
        if (!want) return
        Api.call("library.state", { kind: isMovie ? "movie" : "show", tmdb: want }, function (ok, d) {
            if (request !== page.libraryRequest) return
            page.libraryReady = ok
            if (ok) page.inLibrary = d.inLibrary
        })
    }
    function toggleLibrary() {
        if (libraryBusy) return
        if (!libraryReady) { loadLibrary(); return }
        var on = !inLibrary, request = ++libraryRequest
        libraryBusy = true
        Api.call("library.set", { kind: isMovie ? "movie" : "show", tmdb: tmdbId, on: on }, function (ok) {
            if (request !== page.libraryRequest) return
            page.libraryBusy = false
            if (ok) page.inLibrary = on
            else page.notice(qsTr("Couldn't update Library. Try again."))
        })
    }
    // once the bindings on item (tmdbId, isMovie) caught up: a handler runs before them
    onItemChanged: if (ready) Qt.callLater(reload)
    readonly property var next: details && details.next ? details.next : null
    // the episode the story talks about: the one in focus in the row, else the one continue plays
    readonly property var episodeShown: {
        var eps = season ? season.episodes || [] : []
        if (episodes.activeFocus && eps[episodes.currentIndex]) return eps[episodes.currentIndex]
        if (!item || item.kind !== "episode") return null
        var t = playTarget()
        for (var i = 0; i < eps.length; ++i)
            if (eps[i].season === t.season && eps[i].episode === t.episode) return eps[i]
        return null
    }
    signal play(var target, var stream)
    signal sources(var target)
    signal open(var item)
    signal menu(var item, rect at)
    signal back()
    signal notice(string message)
    property var menuItem: null

    // the wheel moves the page in pixels, the focus stays. a key brings what has the focus back
    property bool wheeled: false
    PageWheel { id: wheel; view: scroller }
    function wheelScroll(w) {
        wheeled = true
        snap = true
        wheel.scroll(w)
        snap = false
    }
    Connections {
        target: Input
        function onPointingChanged() {
            if (Input.pointing || !page.wheeled) return
            wheel.stop()
            page.wheeled = false
            // what has the focus if it's still in view, else the first thing in view
            var all = [actions, seasonsRow, episodes, more].filter(function (s) { return s.visible })
            var seen = all.filter(function (s) {
                var mid = s.y + s.height / 2
                return mid >= scroller.contentY && mid <= scroller.contentY + page.height
            })
            var to = all.filter(function (s) { return s.activeFocus })[0] || null
            if (seen.length && seen.indexOf(to) < 0) {
                to = seen[0]
                to.forceActiveFocus()
                Input.holdKey()
            }
            scroller.contentY = page.restY(to)
        }
    }

    function playTarget() {
        if (isMovie) return { kind: "movie", tmdb: tmdbId }
        var n = item.kind === "episode" ? item : next
        // the episode we came for got watched meanwhile: go on from it
        var eps = season ? season.episodes || [] : []
        if (item.kind === "episode") {
            for (var i = 0; i < eps.length; ++i) {
                if (eps[i].season !== item.season || eps[i].episode !== item.episode || eps[i].watched !== true) continue
                if (next && (next.season > item.season || (next.season === item.season && next.episode > item.episode))) n = next
                else if (eps[i + 1]) n = eps[i + 1]
                break
            }
        }
        return { kind: "show", tmdb: tmdbId, season: n ? n.season : 1, episode: n ? n.episode : 1 }
    }
    // back from playback: progress, watched marks and the next episode, without blanking the page
    function refresh() {
        var request = revision
        loadLibrary()
        if (!tmdbId) return
        Api.call("tmdb.details", { kind: isMovie ? "movie" : "show", id: tmdbId }, function (ok, d) {
            if (!ok || request !== page.revision) return
            page.details = d
            if (!page.isMovie) page.loadSeason(page.seasonNo)
        })
    }
    function reload() {
        var request = ++revision
        details = null; season = null; libraryBusy = false
        loadLibrary()
        if (!tmdbId) return
        Api.call("tmdb.details", { kind: isMovie ? "movie" : "show", id: tmdbId }, function (ok, d) {
            if (!ok || request !== page.revision) return
            var back = page.comeBack
            if (back) { more.keepKey = back.key; more.keepIndex = back.index }
            page.details = d
            if (!page.isMovie)
                page.loadSeason(back && (back.zone === "episodes" || back.zone === "seasons") ? back.season : page.playTarget().season)
            // the rows that don't wait for a season
            if (back && (page.isMovie || back.zone === "more" || back.zone === "actions")) page.landBack()
        })
    }
    function loadSeason(n) {
        seasonNo = n
        var request = revision
        Api.call("tmdb.season", { show: tmdbId, season: n }, function (ok, d) {
            if (!ok || request !== page.revision || n !== page.seasonNo) return
            page.season = d
            var t = page.playTarget()
            var eps = d.episodes || []
            for (var i = 0; i < eps.length; ++i)
                if (eps[i].season === t.season && eps[i].episode === t.episode) { episodes.currentIndex = i; break }
            // stepped over from the season next to it: its first episode (or the last, going back)
            if (page.landAt) {
                var last = page.landAt === "last"
                page.landAt = ""
                episodes.currentIndex = last ? eps.length - 1 : 0
                // once the new cards are laid out, margins kept (positionViewAt* drops them)
                Qt.callLater(function () {
                    episodes.contentX = last ? episodes.originX + episodes.contentWidth - episodes.width + episodes.rightMargin
                                             : episodes.originX - episodes.leftMargin
                })
            }
            if (page.comeBack && page.comeBack.zone === "episodes") episodes.currentIndex = Math.min(page.comeBack.episode, eps.length - 1)
            if (page.comeBack) page.landBack()
        })
    }
    // past a season's last episode (or before its first): the season next to it
    property string landAt: ""
    function stepSeason(dir) {
        var all = seasonsRow.seasons
        for (var i = 0; i < all.length; ++i) {
            if (all[i].number !== seasonNo) continue
            var to = all[i + dir]
            if (!to) return false
            landAt = dir > 0 ? "first" : "last"
            seasonsRow.currentIndex = i + dir
            loadSeason(to.number)
            return true
        }
        return false
    }
    // where the page rests for a row with the focus: the buttons, seasons and episodes keep the page as it
    // opened (episodes the bottom row, the whole story above them), only the row below them scrolls it
    function restY(to) { return to === more ? Math.max(0, more.y - page.height * 0.3) : 0 }
    // a title opened from this one: where the focus was, so back lands on it again
    property var comeBack: null
    function mark() {
        return { zone: more.activeFocus ? "more" : episodes.activeFocus ? "episodes" : seasonsRow.activeFocus ? "seasons" : "actions",
                 key: more.keyOf(more.current), index: more.currentIndex, episode: episodes.currentIndex, season: seasonNo }
    }
    function landBack() {
        var back = comeBack
        comeBack = null
        if (!back) return
        var to = back.zone === "more" ? more : back.zone === "episodes" ? episodes : back.zone === "seasons" ? seasonsRow : actions
        if (!to.visible) return
        snap = true
        to.forceActiveFocus()
        snap = false
        Qt.callLater(function () {
            body.forceLayout()
            snap = true
            scroller.contentY = page.restY(to)
            snap = false
        })
    }
    Component.onCompleted: { ready = true; reload() }
    // the page is built once and kept: a new visit starts at the top, on the first button
    property bool snap: false
    function opened() {
        // a new title's rows start at their first card
        more.keepKey = ""
        more.keepIndex = 0
        snap = true
        scroller.contentY = 0
        snap = false
        playBtn.focus = true
        actions.focus = true
    }

    // the artwork and its shading: also what the buttons' glass refracts
    Item {
        id: art
        anchors.fill: parent
        Image {
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: width
            source: page.details && page.details.backdrop ? page.details.backdrop : (page.item ? page.item.backdrop || "" : "")
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 400 } }
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.88) }
                GradientStop { position: 0.55; color: Qt.rgba(0, 0, 0, 0.5) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.15) }
            }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: parent.height * 0.55
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
                GradientStop { position: 0.6; color: Qt.rgba(0, 0, 0, 0.9) }
                GradientStop { position: 1.0; color: Theme.bg }
            }
        }
    }
    GlassSource { id: artGlass; sourceItem: art; live: page.visible }

    Flickable {
        id: scroller
        anchors.fill: parent
        contentHeight: body.height
        interactive: false
        Behavior on contentY { enabled: !page.snap && !wheel.running; NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }

        Column {
            id: body
            width: parent.width
            spacing: (page.tight ? 22 : 34) * page.u
            // shows: the episode row's two text lines end a margin above the screen edge, whatever
            // the plot's length (never a sliver of the second line peeking in)
            readonly property real underInfo: actions.height + seasonsRow.height + page.cardW * 9 / 16 + 92 * page.u + 4 * body.spacing
            readonly property real headroom: (page.tight ? 36 : 60) * page.u
            Item {
                width: 1
                height: !seasonsRow.visible ? page.height * 0.2
                        : Math.max(body.headroom, page.height - page.edge - (info.height + body.underInfo))
            }

            // identity on the left, the story on the right (room for the whole plot)
            Item {
                id: info
                width: page.width
                // tight: the story's end sits beside the buttons when they leave it the room
                readonly property real lend: page.tight && Theme.margin + actionsRow.width + 40 * page.u < story.x
                                             ? actions.height + body.spacing : 0
                height: Math.max(identity.height, story.height - lend)
                Column {
                    id: identity
                    x: Theme.margin
                    anchors.bottom: parent.bottom
                    width: page.width * 0.44
                    spacing: (page.tight ? 14 : 20) * page.u
                    // room under the logo: a tall one doesn't sit on the line below.
                    // tight: as tall as what's left over the episode row (never under 90)
                    Logo {
                        width: (page.tight ? 460 : 600) * page.u
                        height: !page.tight ? 226 * page.u : !seasonsRow.visible ? 170 * page.u
                                : Math.max(90 * page.u, Math.min(200 * page.u, page.height - page.edge - body.headroom - body.underInfo
                                                                 - identity.spacing - metaLine.height))
                        bottomPad: (page.tight ? 8 : 16) * page.u
                        source: page.details && page.details.logo ? page.details.logo : ""
                        loading: !page.details
                        title: page.details ? page.details.title : (page.item ? page.item.showTitle || page.item.title || "" : "")
                        titleSize: (page.tight ? 56 : 72) * page.u
                    }
                    MetaLine {
                        id: metaLine
                        item: page.details ? Object.assign({}, page.details, page.isMovie && page.details.position ? { position: page.details.position, duration: page.details.duration } : {}) : null
                        details: page.details
                        // up to the story
                        maxWidth: story.x - identity.x - 24 * page.u
                    }
                }

                Scrim {
                    // sized for the tallest plot: a shorter one doesn't make the shade jump
                    readonly property real h: story.height - plot.height + plot.full
                    x: story.x - story.width * 0.45
                    y: story.y + story.height - h * 1.8 - 80 * page.u
                    width: story.width * 1.9 + Theme.margin
                    height: h * 2.6 + 160 * page.u
                    strength: 0.55
                }
                Column {
                    id: story
                    anchors { right: parent.right; rightMargin: Theme.margin; bottom: parent.bottom; bottomMargin: -info.lend }
                    width: page.width * 0.36
                    spacing: 14 * page.u
                    // the lines round the plot (tight: the plot gets what they leave)
                    readonly property real fixedH: (tagLine.visible ? tagLine.height + spacing : 0)
                                                   + (starLine.visible ? starLine.height + spacing : 0)
                                                   + (netLine.visible ? netLine.height + spacing : 0)
                    // a show keeps this line's place whether an episode is on or not
                    Text {
                        id: tagLine
                        visible: seasonsRow.visible || text !== ""
                        width: parent.width
                        height: seasonsRow.visible ? 34 * page.u : implicitHeight
                        elide: Text.ElideRight
                        wrapMode: seasonsRow.visible ? Text.NoWrap : Text.WordWrap
                        text: page.episodeShown ? qsTr("Season %1, Episode %2").arg(page.episodeShown.season).arg(page.episodeShown.episode)
                                                  + (page.episodeShown.episodeTitle ? "  ·  " + page.episodeShown.episodeTitle : "")
                                                : page.details ? page.details.tagline || "" : ""
                        color: Theme.fg
                        font { family: Theme.display; pixelSize: 26 * page.u; weight: Font.DemiBold }
                    }
                    // the plot sits on the starring line and grows up; past seven lines (fewer on a phone) it
                    // scrolls slowly inside its box and comes back
                    Item {
                        id: plot
                        width: parent.width
                        // whole lines, measured: the font's line is taller than its pixel size
                        readonly property real line: plotText.lineCount ? plotText.implicitHeight / plotText.lineCount : 32 * page.u
                        readonly property real pad: 14 * page.u
                        // tight with episodes: as many lines as fit above them (two at least)
                        readonly property real room: page.height - page.edge - body.headroom - body.underInfo + info.lend - story.fixedH
                        readonly property real full: !page.tight ? 7 * line + 2 * pad
                                                     : !seasonsRow.visible ? 4 * line + 2 * pad
                                                     : Math.max(2 * line, Math.min(7 * line, Math.floor((room - 2 * pad) / line) * line)) + 2 * pad
                        readonly property real tall: plotText.implicitHeight + 2 * pad
                        height: Math.min(tall, full)
                        clip: true
                        readonly property real over: Math.max(0, tall - height)
                        layer.enabled: over > 1
                        layer.effect: ShaderEffect {
                            readonly property real edge: plot.pad / plot.height
                            fragmentShader: "qrc:/shaders/fade.frag.qsb"
                        }
                        Item {
                            id: plotRoll
                            width: parent.width
                            height: plotText.implicitHeight + 2 * plot.pad
                            Text {
                                id: plotText
                                y: plot.pad
                                width: parent.width
                                text: page.episodeShown && page.episodeShown.overview ? page.episodeShown.overview : page.details ? page.details.overview || "" : ""
                                color: Theme.fg
                                opacity: 0.86
                                font { family: Theme.text; pixelSize: 24 * page.u }
                                lineHeight: 1.16
                                wrapMode: Text.WordWrap
                            }
                        }
                        // read, roll down, wait, come back: one animator at a time, the timer in between idles
                        readonly property bool rolling: on && over > 1 && page.visible
                        property bool atEnd: false
                        YAnimator {
                            id: rollAnim
                            target: plotRoll
                            easing.type: Easing.InOutSine
                            onFinished: if (plot.rolling) rollWait.restart()
                        }
                        Timer {
                            id: rollWait
                            interval: plot.atEnd ? 3000 : 4500
                            onTriggered: {
                                rollAnim.to = plot.atEnd ? 0 : -plot.over
                                rollAnim.duration = plot.atEnd ? 800 : plot.over / page.u * 55
                                plot.atEnd = !plot.atEnd
                                rollAnim.start()
                            }
                        }
                        onRollingChanged: {
                            rollAnim.stop()
                            rollWait.stop()
                            atEnd = false
                            plotRoll.y = 0
                            if (rolling) rollWait.start()
                        }
                        property bool on: true
                        function reset() { on = false; Qt.callLater(function () { plot.on = true }) }
                        onOverChanged: reset()
                        Connections { target: plotText; function onTextChanged() { plot.reset() } }
                    }
                    Text {
                        id: starLine
                        width: parent.width
                        visible: text !== ""
                        elide: Text.ElideRight
                        color: Theme.fg2
                        font { family: Theme.text; pixelSize: 21 * page.u }
                        text: {
                            var c = page.details && page.details.cast ? page.details.cast.slice(0, 4).map(function (p) { return p.name }) : []
                            return c.length ? qsTr("Starring %1").arg(c.join(", ")) : ""
                        }
                    }
                    Text {
                        id: netLine
                        width: parent.width
                        visible: text !== ""
                        elide: Text.ElideRight
                        color: Theme.fg2
                        font { family: Theme.text; pixelSize: 21 * page.u; weight: Font.Medium }
                        text: {
                            var d = page.details, f = []
                            if (!d) return ""
                            if (d.network) f.push(d.network)
                            if (d.seasons && d.seasons.length) f.push(Theme.counted(qsTr("%n season(s)", "", d.seasons.length), d.seasons.length))
                            if (d.nextAir && d.nextAir.airDate) f.push(qsTr("New episode %1").arg(Theme.day(d.nextAir.airDate)))
                            else if (d.status && d.status !== "Released" && d.status !== "Returning Series") f.push(qsTranslate("core", d.status))
                            return f.join("  ·  ")
                        }
                    }
                }
            }

            // actions
            FocusScope {
                id: actions
                x: Theme.margin
                width: page.width - 2 * Theme.margin
                height: (page.tight ? 66 : 90) * page.u
                focus: true
                // back up on the buttons: the page's top (title and all) in view again
                onActiveFocusChanged: if (activeFocus && !Input.pointing) scroller.contentY = 0
                Row {
                    id: actionsRow
                    spacing: 26 * page.bu
                    anchors.verticalCenter: parent.verticalCenter
                    // the way back on the page itself (the pointer's; the remote has its own key too).
                    // the focus starts on play, left of it is this
                    GlassButton {
                        id: backBtn
                        // a phone has its own back (gesture or key)
                        visible: !Theme.touch
                        glass: true
                        source: artGlass
                        u: page.bu
                        icon: "arrowleft"
                        text: qsTr("Back")
                        KeyNavigation.right: playBtn
                        onClicked: page.back()
                    }
                    GlassButton {
                        id: playBtn
                        // a finger: the white one (a remote shows it by focus)
                        primary: Theme.touch
                        glass: true
                        source: artGlass
                        u: page.bu
                        focus: true
                        icon: "play"
                        text: {
                            if (!page.details) return qsTr("Play")
                            if (page.isMovie) return page.details.position > 60 ? qsTr("Resume") : qsTr("Play")
                            var t = page.playTarget()
                            return (t.season === 1 && t.episode === 1 ? qsTr("Play") : qsTr("Continue")) + "  S" + t.season + " E" + t.episode
                        }
                        KeyNavigation.left: backBtn.visible ? backBtn : null
                        KeyNavigation.right: overBtn.visible ? overBtn : srcBtn
                        onClicked: page.play(page.playTarget(), null)
                    }
                    GlassButton {
                        id: overBtn
                        glass: true
                        source: artGlass
                        u: page.bu
                        visible: !!(page.isMovie && page.details && page.details.position > 60)
                        icon: "back10"
                        text: qsTr("Start Over")
                        KeyNavigation.left: playBtn
                        KeyNavigation.right: srcBtn
                        onClicked: page.play({ kind: "movie", tmdb: page.tmdbId, start: 0 }, null)
                    }
                    GlassButton {
                        id: srcBtn
                        glass: true
                        source: artGlass
                        u: page.bu
                        icon: "list"
                        text: qsTr("Sources")
                        KeyNavigation.left: overBtn.visible ? overBtn : playBtn
                        KeyNavigation.right: wlBtn
                        onClicked: page.sources(page.playTarget())
                    }
                    GlassButton {
                        id: wlBtn
                        glass: true
                        source: artGlass
                        u: page.bu
                        icon: page.inLibrary ? "check" : "plus"
                        text: qsTr("Library")
                        opacity: page.libraryBusy || !page.libraryReady ? 0.5 : 1
                        onClicked: page.toggleLibrary()
                    }
                }
                Keys.onDownPressed: (seasonsRow.visible ? seasonsRow : more).forceActiveFocus()
            }

            // seasons: text pills
            ListView {
                id: seasonsRow
                visible: !page.isMovie && page.details && (page.details.seasons || []).length > 0
                x: Theme.margin
                width: page.width - Theme.margin
                height: visible ? (page.tight ? 46 : 60) * page.u : 0
                orientation: ListView.Horizontal
                spacing: 16 * page.bu
                readonly property var seasons: page.details ? page.details.seasons || [] : []
                model: seasons.length
                keyNavigationEnabled: true
                onActiveFocusChanged: {
                    if (!activeFocus) return
                    if (!Input.pointing) scroller.contentY = 0
                    // land on the season that's open, not the first one
                    if (!Input.pointing) for (var i = 0; i < seasons.length; ++i)
                        if (seasons[i].number === page.seasonNo) { currentIndex = i; break }
                }
                delegate: Rectangle {
                    required property int index
                    readonly property var modelData: seasonsRow.seasons[index] || ({})
                    readonly property bool sel: modelData.number === page.seasonNo
                    readonly property bool foc: ListView.isCurrentItem && seasonsRow.activeFocus
                    readonly property bool lit: foc && (!Input.pointing || sp.containsMouse)
                    height: (page.tight ? 44 : 56) * page.u
                    width: sLabel.implicitWidth + 44 * page.bu
                    radius: height / 2
                    color: lit ? "white" : sel ? Qt.rgba(1, 1, 1, 0.22) : "transparent"
                    Pointer { id: sp }
                    Text {
                        id: sLabel
                        anchors.centerIn: parent
                        text: !modelData.name || /^Season \d+$/.test(modelData.name) ? qsTr("Season %1").arg(modelData.number) : modelData.name
                        color: parent.lit ? Theme.focusFg : parent.sel ? Theme.fg : Theme.fg2
                        font { family: Theme.display; pixelSize: 25 * page.bu; weight: Font.DemiBold }
                    }
                }
                Keys.onReturnPressed: page.loadSeason(seasons[currentIndex].number)
                Keys.onUpPressed: { actions.forceActiveFocus(); scroller.contentY = 0 }
                Keys.onDownPressed: episodes.forceActiveFocus()
            }

            ListWheel { view: seasonsRow; across: true }
            ListWheel { id: epWheel; view: episodes; across: true; cards: true; restX: Theme.margin + page.cardW + 44 * page.u; cardW: page.cardW }
            ListView {
                id: episodes
                visible: seasonsRow.visible
                width: page.width
                height: visible ? page.cardW * 9 / 16 + 150 * page.u : 0
                orientation: ListView.Horizontal
                leftMargin: Theme.margin
                rightMargin: Theme.margin
                spacing: 44 * page.u
                readonly property var eps: page.season ? page.season.episodes || [] : []
                model: eps.length
                cacheBuffer: 1200 * page.u
                keyNavigationEnabled: true
                // the focus rests on the second card, so the one before stays in view
                highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
                preferredHighlightBegin: epWheel.heldAt >= 0 ? epWheel.heldAt : epWheel.restX
                preferredHighlightEnd: preferredHighlightBegin + page.cardW
                highlightMoveDuration: 380
                highlightMoveVelocity: -1
                onActiveFocusChanged: if (activeFocus && !Input.pointing) scroller.contentY = 0
                delegate: Item {
                    required property int index
                    readonly property var modelData: episodes.eps[index] || ({})
                    width: page.cardW
                    height: episodes.height
                    Card {
                        id: epCard
                        style: "episode"
                        wideW: page.cardW
                        media: Object.assign({ kind: "episode" }, modelData, {
                            label: modelData.episode + ".  " + (modelData.episodeTitle || qsTr("Episode %1").arg(modelData.episode)),
                            sublabel: [modelData.runtime ? Theme.runtime(modelData.runtime) : "", modelData.airDate ? Qt.formatDate(new Date(modelData.airDate), "d MMM yyyy") : ""].filter(function (x) { return x }).join("  ·  ")
                        })
                        focused: parent.ListView.isCurrentItem && episodes.activeFocus
                    }
                    Rectangle {
                        visible: modelData.watched === true
                        anchors { right: parent.right; top: parent.top; margins: 14 * page.u }
                        width: 40 * page.u; height: width; radius: width / 2
                        color: Qt.rgba(0, 0, 0, 0.55)
                        scale: epCard.lifted ? 1.1 : 1
                        Symbol { anchors.centerIn: parent; width: 26 * page.u; height: width; name: "check"; weight: 2.6; color: "white" }
                    }
                }
                Keys.onReturnPressed: {
                    var e = eps[currentIndex]
                    page.play({ kind: "show", tmdb: page.tmdbId, season: e.season, episode: e.episode }, null)
                }
                Keys.onMenuPressed: {
                    if (toast.trigger()) return     // menu = the toast's undo first
                    var e = eps[currentIndex]
                    page.sources({ kind: "show", tmdb: page.tmdbId, season: e.season, episode: e.episode })
                }
                Keys.onUpPressed: seasonsRow.forceActiveFocus()
                Keys.onDownPressed: more.forceActiveFocus()
                Keys.onRightPressed: function (e) { e.accepted = currentIndex === count - 1 && page.stepSeason(1) }
                Keys.onLeftPressed: function (e) { e.accepted = currentIndex === 0 && page.stepSeason(-1) }
                // a finger pulling on past either end
                onDragEnded: {
                    if (horizontalOvershoot > 90 * page.u) page.stepSeason(1)
                    else if (horizontalOvershoot < -90 * page.u) page.stepSeason(-1)
                }
            }

            MediaRow {
                id: more
                width: page.width
                title: qsTr("More Like This")
                style: "poster"
                optionsEnabled: true
                menuItem: page.menuItem
                onMenu: function (it, index, at) { page.menu(it, at) }
                items: page.details ? page.details.more || [] : []
                visible: items.length > 0
                onActiveFocusChanged: if (activeFocus && !Input.pointing) scroller.contentY = Math.max(0, y - page.height * 0.3)
                onActivated: function (it) { page.open(it) }
                Keys.onUpPressed: (episodes.visible ? episodes : actions).forceActiveFocus()
            }
            Item { width: 1; height: 80 * page.u }
        }
        // over the column (not in it): the episodes' page arrows
        RowArrows {
            view: episodes
            visible: episodes.visible
            restSlot: 1
            cardW: page.cardW
            artH: page.cardW * 9 / 16
        }
    }
}
