import QtQuick

// spotlight of the focused item (kodi skin style): textless backdrop, logo, a meta line
// with "ends at", the plot. details load after the focus rests for a moment
Item {
    id: hero
    property var item: null
    property var details: null
    property var known: ({})              // details home fetched ahead of the focus
    property int knownVersion: 0
    readonly property real u: Theme.u
    // grid units between the top bar (with air under it) and the info's bottom: a short screen
    // gets a smaller logo and fewer lines of story instead of text running into the bar
    readonly property real room: (height - infoBottom) / u - 165
    readonly property real logoHeight: Math.max(Theme.short ? 64 : 96, Math.min(190, room - 95 - (curEpisode ? 45 : 0))) * u
    readonly property bool episode: item && item.kind === "episode"
    readonly property string kind: !item ? "" : (item.kind === "movie" ? "movie" : "show")
    readonly property int tmdbId: !item ? 0 : (episode ? item.show : item.id) || 0
    property int shown: 0

    readonly property string key: tmdbId ? kind + ":" + tmdbId : ""
    onKeyChanged: {
        var d = known[key]
        if (d) { details = d; settle.stop() } else { details = null; settle.restart() }
    }
    onKnownVersionChanged: if (!details && known[key]) { details = known[key]; settle.stop() }

    // what the text shows: the logo, meta and story fade out, swap, fade back in.
    // moving fast keeps them down until the focus rests
    property var cur: null
    property var curDetails: null
    property string curKey: ""
    function keyOf(it) { return !it ? "" : (it.kind === "movie" ? "movie:" + it.id : "show:" + (it.kind === "episode" ? it.show : it.id)) }
    onItemChanged: {
        if (!cur || !item) { swapIn(); return }
        if (item === cur) return
        swap.restart()
    }
    onDetailsChanged: if (details && key === curKey) curDetails = details
    function swapIn() {
        cur = item
        curKey = keyOf(item)
        curDetails = details && key === curKey ? details : (known[curKey] || null)
    }
    property real textOpacity: 1
    SequentialAnimation {
        id: swap
        NumberAnimation { target: hero; property: "textOpacity"; to: 0; duration: 120; easing.type: Easing.InQuad }
        PauseAnimation { duration: 60 }
        ScriptAction { script: hero.swapIn() }
        NumberAnimation { target: hero; property: "textOpacity"; to: 1; duration: 260; easing.type: Easing.OutCubic }
    }
    readonly property bool curEpisode: cur && cur.kind === "episode"
    Timer {
        id: settle
        interval: 240
        onTriggered: {
            if (!hero.tmdbId) return
            var want = hero.tmdbId
            Api.call("tmdb.details", { kind: hero.kind, id: want }, function (ok, d) {
                if (ok && want === hero.tmdbId) hero.details = d
            })
        }
    }

    // two layers take turns so a new backdrop fades over the old one
    readonly property url wanted: details && details.backdrop ? details.backdrop : (item ? item.backdrop || "" : "")
    onWantedChanged: follow()
    // the layers register as they're built: a picture asked for before that waits for them
    onB1Changed: follow()
    function follow() {
        if (!b0 || !b1) return
        var front = shown === 0 ? b0 : b1, next = shown === 0 ? b1 : b0
        if (front.source == wanted) return
        // back to the picture the other layer still holds: no load, so no status change to wait for
        if (next.source == wanted && next.status === Image.Ready) { show(shown === 0 ? 1 : 0); return }
        next.source = wanted
    }
    // a new picture before the last fade finished: snap to it, no pile of half fades
    property bool snap: false
    property double lastSwap: 0
    function show(i) {
        var now = Date.now()
        snap = now - lastSwap < 520
        lastSwap = now
        shown = i
    }
    Repeater {
        model: 2
        Image {
            id: layer
            readonly property bool front: hero.shown === index
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: hero.width
            opacity: front ? 1 : 0
            Behavior on opacity { enabled: !hero.snap; NumberAnimation { duration: 520; easing.type: Easing.InOutQuad } }
            onStatusChanged: if (status === Image.Ready && !front && source == hero.wanted) hero.show(index)
            Component.onCompleted: index === 0 ? hero.b0 = layer : hero.b1 = layer
        }
    }
    property Image b0
    property Image b1

    // legibility: dark from the left and towards the rows
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.82) }
            GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0.45) }
            GradientStop { position: 0.8; color: Qt.rgba(0, 0, 0, 0.0) }
        }
    }
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: parent.height * 0.72
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
            GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0.55) }
            GradientStop { position: 0.75; color: Qt.rgba(0, 0, 0, 0.9) }
            GradientStop { position: 1.0; color: Theme.bg }
        }
    }

    // left: who/what (logo, episode, meta). right: the story and a little more, room for it all
    readonly property string overview: cur ? (cur.overview || cur.showOverview || "") : ""
    readonly property string cast: {
        var c = curDetails && curDetails.cast ? curDetails.cast.slice(0, 3).map(function (p) { return p.name }) : []
        return c.length ? qsTr("Starring %1").arg(c.join(", ")) : ""
    }
    readonly property string facts: {
        var d = curDetails
        if (!d) return ""
        var f = []
        if (d.network) f.push(d.network)
        if (d.nextAir && d.nextAir.airDate)
            f.push(qsTr("New episode %1").arg(Theme.day(d.nextAir.airDate)))
        else if (d.status && d.status !== "Released" && d.status !== "Returning Series") f.push(qsTranslate("core", d.status))
        return f.join("  ·  ")
    }
    // the rows' share of the page (home makes it larger on a short screen)
    property real band: height * 0.475
    readonly property real infoBottom: parent ? band + (Theme.short ? 16 : 34) * u : 0

    // nothing to show yet (no profile, no keys, still loading): the layout in grey
    Item {
        anchors.fill: parent
        visible: opacity > 0
        opacity: hero.cur ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Column {
            x: Theme.margin
            anchors { bottom: parent.bottom; bottomMargin: hero.infoBottom }
            spacing: 26 * hero.u
            Rectangle { width: 460 * hero.u; height: 120 * hero.u; radius: 26 * hero.u; color: Theme.skeleton }
            Rectangle { width: 380 * hero.u; height: 26 * hero.u; radius: height / 2; color: Theme.skeleton }
        }
        Column {
            anchors { right: parent.right; rightMargin: Theme.margin; bottom: parent.bottom; bottomMargin: hero.infoBottom }
            width: parent.width * 0.42
            spacing: 18 * hero.u
            Repeater {
                model: [1, 0.96, 0.98, 0.9, 0.6]
                Rectangle { required property real modelData; width: parent.width * modelData; height: 22 * hero.u; radius: height / 2; color: Theme.skeleton }
            }
        }
    }

    Column {
        id: info
        x: Theme.margin
        anchors { bottom: parent.bottom; bottomMargin: hero.infoBottom }
        width: parent.width * 0.42
        spacing: 16 * hero.u
        opacity: hero.cur ? hero.textOpacity : 0

        // every logo gets the same box (wide ones and tall ones read alike), centred in it
        // room under the logo: a tall one doesn't sit on the line below
        Logo {
            width: 560 * hero.u
            height: hero.logoHeight + 16 * hero.u
            bottomPad: 16 * hero.u
            source: hero.curDetails && hero.curDetails.logo ? hero.curDetails.logo : ""
            loading: !hero.curDetails
            title: hero.cur ? (hero.curEpisode ? hero.cur.showTitle : hero.cur.title) || "" : ""
        }
        Text {
            visible: hero.curEpisode
            topPadding: 4 * hero.u
            text: hero.curEpisode ? "S" + hero.cur.season + " · E" + hero.cur.episode + (hero.cur.episodeTitle ? "  " + hero.cur.episodeTitle : "") : ""
            color: Theme.fg
            font { family: Theme.display; pixelSize: 31 * hero.u; weight: Font.DemiBold }
        }
        MetaLine {
            item: hero.cur
            details: hero.curDetails
            maxWidth: info.width
        }
    }

    // the story always reads, whatever the artwork is doing behind it
    Scrim {
        x: story.x - story.width * 0.45
        y: story.y - story.height * 0.8 - 80 * hero.u
        width: story.width * 1.9 + Theme.margin
        height: story.height * 2.6 + 160 * hero.u
        // (a white backdrop under the plot still has to read)
        strength: 0.7
        opacity: story.opacity
    }
    Column {
        id: story
        anchors { right: parent.right; rightMargin: Theme.margin; bottom: parent.bottom; bottomMargin: hero.infoBottom }
        width: parent.width * 0.42
        spacing: 14 * hero.u
        opacity: hero.cur && hero.overview ? hero.textOpacity : 0
        Text {
            width: parent.width
            text: hero.overview
            color: Theme.fg
            opacity: 0.93
            font { family: Theme.text; pixelSize: 24 * hero.u }
            lineHeight: 1.16
            wrapMode: Text.WordWrap
            maximumLineCount: Math.max(2, Math.min(7, Math.floor((hero.room - 78) / 28)))
            elide: Text.ElideRight
            style: Text.Raised
            styleColor: Qt.rgba(0, 0, 0, 0.45)
        }
        Text {
            width: parent.width
            visible: text !== ""
            text: hero.cast
            color: Theme.fg2
            elide: Text.ElideRight
            font { family: Theme.text; pixelSize: 21 * hero.u }
        }
        Text {
            width: parent.width
            visible: text !== ""
            text: hero.facts
            color: Theme.fg2
            elide: Text.ElideRight
            font { family: Theme.text; pixelSize: 21 * hero.u; weight: Font.Medium }
        }
    }
}
