import QtQuick

// home / movies / shows: hero of the focused item over the rows (kodi order)
FocusScope {
    id: home
    property string page: "home"
    property int profileId: 0
    property int generation: 0
    property var specs: []
    property bool known: false        // home.rows answered
    property var cache: ({})          // row id -> items, survives delegate reuse
    property int version: 0           // bumped when cache changes
    property var menuItem: null
    readonly property real u: Theme.u
    readonly property var current: rows.currentItem ? rows.currentItem.current : null
    // the wheel running cards past a resting mouse: the hero and what's fetched wait for the page to stop
    property var shownItem: null
    function settle() { shownItem = current; Qt.callLater(preloadAround) }
    onCurrentChanged: if (wheel.running) settleLater.restart(); else settle()
    Timer { id: settleLater; interval: 160; onTriggered: if (wheel.running) restart(); else home.settle() }
    signal open(var item)
    signal menu(var item, string rowId, rect at)
    signal upFromTop()

    // ---- the wheel: hero and rows are one page that moves in pixels. keys take it over as it is and
    // follow the selection; at the top row it's the tv's page again, the hero and one row
    property bool scrolled: false
    // the rows don't follow the current row: the mouse has the page, or the keys and the glide do. it
    // ends only once the page is where the tv's rows have it: strict range picks the current row from
    // wherever the view is
    property bool free: false
    // the row at the top for the keys (those above hide behind the hero): the mouse picking one doesn't change it
    property int topRow: 0
    readonly property real pageY: rows.contentY - rows.originY
    readonly property real heroY: scrolled ? pageY : 0
    // below the bar and the fade
    readonly property real clearY: 210 * u
    PageWheel {
        id: wheel
        view: rows
        onRunningChanged: if (!running) home.free = Input.pointing || home.scrolled
    }
    function wheelScroll(w) {
        scrolled = true
        free = true
        wheel.scroll(w)
    }
    onPageYChanged: if (scrolled && pageY < 0.5 && (Input.pointing || rows.currentIndex === 0)) { scrolled = false; topRow = 0 }
    Connections {
        target: Input
        function onPointingChanged() {
            if (Input.pointing) { home.free = true; return }
            var i = home.rowInView()
            if (rows.activeFocus && !win.pointedCard) Input.holdKey()
            rows.currentIndex = i
            home.reveal(i)
        }
    }
    // a key after the mouse: the selection if it's still in view, else the first row in view
    function rowInView() {
        var it = rows.currentItem
        if (it) {
            var y = rows.y + it.y - rows.contentY
            if (Math.min(y + it.height, height) - Math.max(y, clearY) >= it.height / 2) return rows.currentIndex
        }
        var at = Math.max(rows.originY, scrolled ? rows.contentY - rows.y + clearY : rows.contentY)
        var i = rows.indexAt(rows.width / 2, at + 100 * u)
        return i >= 0 ? i : rows.currentIndex
    }
    // the keys' way with the free page: the row comes in whole, the top row takes it all the way up
    function reveal(i) {
        var it = rows.itemAtIndex(i)
        if (!it) return
        var to = rows.contentY
        if (!scrolled) { to = it.y; topRow = i }
        else if (i === 0) to = rows.originY
        else if (it.y < to - rows.y + clearY) to = it.y + rows.y - clearY
        else if (it.y + it.height > to + rows.height) to = it.y + it.height - rows.height
        wheel.goal = wheel.clamp(to)
        wheel.start()
    }

    function load() {
        Api.call("home.rows", { page: page }, function (ok, d) { home.known = true; if (ok) { home.specs = d; home.updateShown() } })
    }
    // personal rows step aside while they're empty (a new profile starts on the catalog rows)
    readonly property var personal: ["upnext", "continue", "continue-movie", "recent", "library", "library-movie", "library-show"]
    property var shown: []
    function updateShown() {
        var out = specs.filter(function (r) {
            var c = cache[r.id]
            return personal.indexOf(r.id) < 0 || c === undefined || c.length > 0
        })
        if (out.map(function (r) { return r.id }).join() === shown.map(function (r) { return r.id }).join()) return
        var was = rows.currentIndex >= 0 && shown[rows.currentIndex] ? shown[rows.currentIndex].id : ""
        shown = out
        for (var i = 0; i < out.length; ++i) if (out[i].id === was) { rows.currentIndex = i; rows.positionViewAtIndex(i, ListView.Beginning); break }
    }
    property bool marked: false
    function loadRow(id) {
        var request = generation
        Api.call("home.row", { id: id }, function (ok, d) {
            if (!ok || request !== home.generation) return
            if (!home.marked && d && d.length) { home.marked = true; Desktop.mark("first row: " + home.page) }
            Desktop.mark("row " + id)
            var c = home.cache
            c[id] = d
            home.cache = c
            home.version++
            home.updateShown()
        })
    }
    onProfileIdChanged: {
        generation++
        for (var i = 0; i < specs.length; ++i) loadRow(specs[i].id)
        details = {}; detailsVersion++
        Qt.callLater(preloadAround)
    }
    // after playback or a dismiss: the personal rows change, the catalog ones don't
    function refreshPersonal() {
        for (var i = 0; i < specs.length; ++i)
            if (personal.indexOf(specs[i].id) >= 0) loadRow(specs[i].id)
    }
    function removeLocal(rowId, item) {
        // by what it is: the item came through a signal, it isn't the same object any more
        var c = cache, key = [item.kind, item.id, item.show, item.season, item.episode].join(":")
        c[rowId] = (c[rowId] || []).filter(function (x) { return [x.kind, x.id, x.show, x.season, x.episode].join(":") !== key })
        cache = c
        version++
        updateShown()
    }
    Component.onCompleted: { free = Input.pointing; load() }

    // ---- ahead of the focus: details, logo and backdrop of the 3 next items in every direction
    // (same row both ways, the focused card of the 3 rows above and below), so the hero is instant
    property var details: ({})        // "show:123" -> tmdb details (null while asked)
    property int detailsVersion: 0
    property var ahead: []
    function keyOf(it) {
        if (!it) return ""
        return it.kind === "movie" ? "movie:" + it.id : "show:" + (it.kind === "episode" ? it.show : it.id)
    }
    function prefetch(it) {
        var k = keyOf(it)
        if (!k || details[k] !== undefined) return
        details[k] = null
        var p = k.split(":"), request = generation
        Api.call("tmdb.details", { kind: p[0], id: Number(p[1]) }, function (ok, d) {
            if (request !== home.generation) return
            if (ok) home.details[k] = d; else delete home.details[k]
            home.detailsVersion++
        })
    }
    function preloadAround() {
        var row = rows.currentItem
        if (!row) return
        var out = [], c = row.currentIndex, items = row.items
        for (var d = 1; d <= 3; ++d) {
            if (items[c + d]) out.push(items[c + d])
            if (c - d >= 0 && items[c - d]) out.push(items[c - d])
            for (var side = -1; side <= 1; side += 2) {
                var r = rows.currentIndex + side * d
                if (r < 0 || r >= shown.length) continue
                var other = rows.itemAtIndex(r), list = cache[shown[r].id] || []
                var it = list[other ? Math.min(other.currentIndex, list.length - 1) : 0]
                if (it) out.push(it)
            }
        }
        prefetch(current)
        out.forEach(prefetch)
        ahead = out
    }
    onVersionChanged: Qt.callLater(preloadAround)
    readonly property var aheadDetails: {
        var v = detailsVersion, out = []
        for (var i = 0; i < ahead.length; ++i) {
            var d = details[keyOf(ahead[i])]
            if (d) out.push(d)
        }
        return out
    }
    // invisible images keep the decoded pixmaps in qt's cache at the hero's exact sizes. the model is
    // a count: a list of detail maps as the model regenerated (and converted) them on every move
    Repeater {
        model: home.aheadDetails.length
        Item {
            required property int index
            readonly property var d: home.aheadDetails[index] || ({})
            Image { visible: false; asynchronous: true; source: d.logo || ""; sourceSize.height: hero.logoHeight }
            Image { visible: false; asynchronous: true; source: d.backdrop || ""; sourceSize.width: hero.width }
        }
    }

    Hero {
        id: hero
        anchors.fill: parent
        item: home.shownItem
        known: home.details
        knownVersion: home.detailsVersion
        visible: home.heroY < height
        transform: Translate { y: -home.heroY }
    }

    ListView {
        id: rows
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: parent.height * 0.47
        focus: true
        clip: false
        model: home.shown
        spacing: 8 * home.u
        // every row built ahead while idle (about ten): one built on the way down costs ~25 ms
        cacheBuffer: 6 * parent.height
        // the view is the bottom half of the page: drawn up to the top of the window, or a row
        // would vanish as it leaves the view
        displayMarginBeginning: y
        keyNavigationEnabled: true
        onCurrentIndexChanged: {
            if (!home.free) home.topRow = currentIndex
            else if (!Input.pointing) home.reveal(currentIndex)
        }
        // free: a range nothing leaves, so the view stays put and the highlight keeps up
        highlightRangeMode: home.free ? ListView.ApplyRange : ListView.StrictlyEnforceRange
        preferredHighlightBegin: home.free ? -100000 : 0
        preferredHighlightEnd: home.free ? 100000 : 80 * home.u
        // an invisible highlight: without one the view follows the current row directly and
        // jumps, the move duration only animates a highlight
        highlight: Item {}
        highlightMoveDuration: 420
        highlightMoveVelocity: -1
        boundsBehavior: Flickable.StopAtBounds
        Keys.onUpPressed: function (e) { if (currentIndex === 0) home.upFromTop(); else decrementCurrentIndex() }
        delegate: MediaRow {
            id: homeRow
            required property var modelData
            required property int index
            width: rows.width
            rowId: modelData.id
            optionsEnabled: true
            menuItem: home.menuItem
            title: qsTranslate("core", modelData.title)
            style: modelData.style
            items: (home.version, home.cache[modelData.id] || [])
            loading: (home.version, home.cache[modelData.id] === undefined)
            // rows above the focus hide behind the hero: one leaving is gone at once, one coming
            // back fades in with its slide (a behavior would pick the duration of the old state)
            readonly property bool above: index < home.topRow && !home.scrolled
            opacity: 1
            onAboveChanged: {
                fade.stop()
                fade.to = above ? 0 : 1
                fade.duration = above ? 100 : 450
                fade.easing.type = above ? Easing.OutQuad : Easing.InQuad
                fade.start()
            }
            NumberAnimation { id: fade; target: homeRow; property: "opacity" }
            Component.onCompleted: {
                opacity = above ? 0 : 1
                if (home.cache[modelData.id] === undefined) home.loadRow(modelData.id)
            }
            onActivated: function (item) { home.open(item) }
            onMenu: function (item, index, at) { home.menu(item, modelData.id, at) }
        }
    }
    // scrolled: the page fades into the black before it gets to the bar and the profile
    Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 300 * home.u
        visible: opacity > 0
        opacity: Math.min(1, home.heroY / (120 * home.u))
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.bg }
            GradientStop { position: 0.46; color: Theme.bg }
            GradientStop { position: 0.62; color: Qt.rgba(0, 0, 0, 0.8) }
            GradientStop { position: 0.8; color: Qt.rgba(0, 0, 0, 0.32) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0) }
        }
        // what's fading out takes no hover
        MouseArea { width: parent.width; height: parent.height * 0.62; hoverEnabled: true; acceptedButtons: Qt.NoButton }
    }
    // the rows before the page has them: placeholders where they'll be
    Column {
        anchors { left: rows.left; right: rows.right; top: rows.top }
        spacing: rows.spacing
        visible: !home.known
        Repeater {
            model: ["landscape", "poster"]
            MediaRow { required property string modelData; width: parent.width; style: modelData; loading: true }
        }
    }
}
