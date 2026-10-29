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
    signal open(var item)
    signal menu(var item, string rowId, rect at)
    signal upFromTop()

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
        var c = cache, list = (c[rowId] || []).slice()
        var i = list.indexOf(item)
        if (i >= 0) list.splice(i, 1)
        c[rowId] = list
        cache = c
        version++
        updateShown()
    }
    Component.onCompleted: load()

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
    onCurrentChanged: Qt.callLater(preloadAround)
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
        item: home.current
        known: home.details
        knownVersion: home.detailsVersion
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
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.StrictlyEnforceRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: 80 * home.u
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
            readonly property bool above: index < rows.currentIndex
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
