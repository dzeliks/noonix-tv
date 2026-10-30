import QtQuick

// search, laid out like the tv terminal: results on the left, a right column with the query,
// suggestions and the keyboard at the bottom, all over the frosted tv wallpaper
FocusScope {
    id: search
    property string query: ""
    property var results: []
    property var popular: []
    property var trending: []
    property bool popularKnown: false
    property bool busy: false
    property string zone: "keys"             // keys | suggestions | grid
    property int suggestion: 0
    readonly property real u: Theme.u
    readonly property bool typing: query.trim().length > 1
    readonly property var shown: typing ? results : popular
    // terminal metrics on the 1080 grid
    readonly property real columnW: 575 * u
    readonly property real columnX: width - Theme.margin - columnW
    readonly property real topY: 150 * u
    readonly property real bottomY: height - 44 * u
    readonly property real gridGap: 40 * u
    readonly property real posterW: (columnX - 64 * u - Theme.margin - 3 * gridGap) / 4
    readonly property var suggestions: {
        var src = typing ? results : trending, out = []
        for (var i = 0; i < src.length && out.length < 6; ++i) {
            var t = src[i].title
            if (t && out.indexOf(t) < 0 && t.toLowerCase() !== query.trim().toLowerCase()) out.push(t)
        }
        return out
    }
    signal open(var item)
    signal upFromTop()

    Component.onCompleted: {
        Api.call("home.row", { id: "popular-movie" }, function (ok, m) {
            Api.call("home.row", { id: "popular-tv" }, function (ok2, t) {
                var a = ok ? m : [], b = ok2 ? t : [], mix = []
                for (var i = 0; i < Math.max(a.length, b.length); ++i) {
                    if (i < b.length) mix.push(b[i])
                    if (i < a.length) mix.push(a[i])
                }
                search.popular = mix
                search.popularKnown = true
            })
        })
        Api.call("home.row", { id: "trending-tv" }, function (ok, d) { if (ok) search.trending = d })
    }
    // back from a title or the bar: where the focus was (the results, a suggestion or the keys)
    onActiveFocusChanged: {
        if (!activeFocus) return
        if (zone === "grid" && shown.length) grid.forceActiveFocus()
        else if (zone === "suggestions" && suggestions.length) sugBox.forceActiveFocus()
        else keys.forceActiveFocus()
    }

    onQueryChanged: debounce.restart()
    Timer {
        id: debounce
        interval: 320
        onTriggered: {
            var q = search.query.trim()
            if (q.length < 2) { search.results = []; search.busy = false; return }
            search.busy = true
            Api.call("tmdb.search", { query: q }, function (ok, d) {
                if (q !== search.query.trim()) return
                search.busy = false
                search.results = ok ? (d.results || d || []) : []
            })
        }
    }

    component Section: Text {
        font { family: Theme.display; pixelSize: 19 * search.u; weight: Font.DemiBold; letterSpacing: 1.1 * search.u }
        color: Qt.rgba(1, 1, 1, 0.5)
    }

    // ---- left: results
    Section {
        id: gridTitle
        x: Theme.margin
        y: search.topY
        text: search.busy ? qsTr("SEARCHING…") : search.typing ? (search.results.length ? qsTr("TOP RESULTS") : qsTr("NO RESULTS")) : qsTr("POPULAR")
    }
    GridView {
        id: grid
        x: Theme.margin - search.gridGap / 2
        y: gridTitle.y + gridTitle.height + 18 * search.u
        width: cols * cellWidth
        height: search.bottomY - y
        readonly property int cols: 4
        cellWidth: search.posterW + search.gridGap
        cellHeight: search.posterW * 1.5 + search.gridGap
        clip: false
        model: search.shown.length
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? GridView.NoHighlightRange : GridView.ApplyRange
        preferredHighlightBegin: 30 * search.u
        preferredHighlightEnd: height - 60 * search.u
        highlightMoveDuration: 320
        cacheBuffer: 600 * search.u
        focus: search.zone === "grid"
        delegate: Item {
            required property int index
            readonly property var modelData: search.shown[index] || ({})
            width: grid.cellWidth
            height: grid.cellHeight
            Card {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 10 * search.u
                posterW: search.posterW
                media: modelData
                focused: parent.GridView.isCurrentItem && grid.activeFocus
            }
        }
        Keys.onRightPressed: function (e) {
            if (currentIndex % cols === cols - 1 || currentIndex === count - 1) search.focusColumn(currentItem ? currentItem.y - contentY : 0)
            else moveCurrentIndexRight()
        }
        Keys.onUpPressed: function (e) { if (currentIndex < cols) search.upFromTop(); else moveCurrentIndexUp() }
        Keys.onReturnPressed: if (search.shown.length) search.open(search.shown[currentIndex])
    }

    // popular or the results on their way: placeholder posters where they'll be
    Grid {
        x: grid.x + search.gridGap / 2
        y: grid.y + 10 * search.u
        columns: grid.cols
        columnSpacing: search.gridGap
        rowSpacing: search.gridGap
        visible: opacity > 0
        opacity: search.shown.length === 0 && (search.typing ? search.busy : !search.popularKnown) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Repeater {
            model: grid.cols * 2
            Skeleton { cardW: search.posterW }
        }
    }
    // nothing found: say so where the results would be
    Column {
        visible: search.typing && !search.busy && search.results.length === 0
        anchors.horizontalCenter: grid.horizontalCenter
        y: grid.y + 160 * search.u
        spacing: 22 * search.u
        Symbol {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 96 * search.u; height: width
            name: "search"; weight: 1.6
            color: Theme.fg3
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, grid.width - 80 * search.u)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: qsTr("No results for “%1”").arg(search.query.trim())
            color: Theme.fg
            font { family: Theme.display; pixelSize: 34 * search.u; weight: Font.DemiBold }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Check the spelling, or try the original title")
            color: Theme.fg2
            font { family: Theme.text; pixelSize: 25 * search.u }
        }
    }

    // the right column takes the focus back at the height it came from
    function focusColumn(y) {
        if (suggestions.length && y < sugBox.y + sugBox.height - grid.y) { zone = "suggestions"; sugBox.forceActiveFocus() }
        else { zone = "keys"; keys.forceActiveFocus() }
    }

    // ---- right column: query, suggestions, keyboard
    Rectangle {
        id: field
        x: search.columnX
        y: search.topY - 8 * search.u
        width: search.columnW
        height: 64 * search.u
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.1)
        border.width: 1 * search.u
        border.color: Qt.rgba(1, 1, 1, 0.14)
        Symbol {
            id: glassIcon
            anchors { left: parent.left; leftMargin: 24 * search.u; verticalCenter: parent.verticalCenter }
            width: 26 * search.u; height: width; name: "search"; weight: 2.2; color: Theme.fg2
        }
        FieldText {
            anchors { left: glassIcon.right; leftMargin: 16 * search.u; right: parent.right; rightMargin: 24 * search.u; verticalCenter: parent.verticalCenter }
            text: search.query
            placeholder: qsTr("Movies and shows")
            active: keys.activeFocus
            size: 26 * search.u
        }
    }

    FocusScope {
        id: sugBox
        x: search.columnX
        y: field.y + field.height + 30 * search.u
        width: search.columnW
        height: kb.y - 22 * search.u - y
        focus: search.zone === "suggestions"
        readonly property real chipH: Math.min(62 * search.u, (height - sugTitle.height - 12 * search.u - 5 * 8 * search.u) / 6)
        Section { id: sugTitle; text: qsTr("SUGGESTIONS"); visible: search.suggestions.length > 0 }
        Repeater {
            model: search.suggestions
            KeyCap {
                id: sug
                required property var modelData
                required property int index
                u: search.u / 2
                fn: true
                grow: 1.04
                radius: 14 * search.u
                y: sugTitle.height + 12 * search.u + index * (sugBox.chipH + 8 * search.u)
                width: sugBox.width
                height: sugBox.chipH
                focused: sugBox.activeFocus && search.suggestion === index
                z: focused ? 1 : 0
                Marquee {
                    anchors { left: parent.left; leftMargin: 22 * search.u; right: parent.right; rightMargin: 22 * search.u; verticalCenter: parent.verticalCenter }
                    text: modelData
                    active: sug.focused
                    font { family: Theme.display; pixelSize: 25 * search.u; weight: Font.Medium }
                    color: sug.focused ? Theme.focusFg : "white"
                }
            }
        }
        Keys.onUpPressed: { if (search.suggestion > 0) search.suggestion--; else search.upFromTop() }
        Keys.onDownPressed: {
            if (search.suggestion < search.suggestions.length - 1) search.suggestion++
            else { search.zone = "keys"; kb.enterAt("top", 0.5); keys.forceActiveFocus() }
        }
        Keys.onLeftPressed: if (search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() }
        Keys.onReturnPressed: if (search.suggestions.length) search.query = search.suggestions[search.suggestion]
    }

    FocusScope {
        id: keys
        // real keyboards type here: the input bindings leave it alone
        readonly property bool typing: true
        x: search.columnX
        y: kb.y
        width: search.columnW
        height: kb.height
        focus: search.zone === "keys"
        // letters came from a real keyboard: its enter goes to the results (a remote's ok presses the focused key)
        property bool typed: false
        onActiveFocusChanged: if (activeFocus) search.zone = "keys"; else typed = false
        Keys.onPressed: function (e) {
            var map = {}
            map[Qt.Key_Up] = "UP"; map[Qt.Key_Down] = "DOWN"; map[Qt.Key_Left] = "LEFT"; map[Qt.Key_Right] = "RIGHT"
            if (map[e.key]) { kb.key(map[e.key]); e.accepted = true; return }
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                if (typed && e.nativeScanCode !== 0) { if (search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() } }
                else kb.key("OK")
                e.accepted = true; return
            }
            if (e.key === Qt.Key_Backspace) { search.query = search.query.slice(0, -1); e.accepted = true; return }
            // a real keyboard works too
            if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) { search.query += e.text; typed = true; e.accepted = true }
        }
    }
    Keyboard {
        id: kb
        x: search.columnX
        y: search.bottomY - height
        width: search.columnW
        u: search.u / 2                 // drawn on the terminal's 2160 grid
        enterLabel: qsTr("search")
        active: keys.activeFocus
        onPointed: keys.forceActiveFocus()
        onTyped: function (t) { search.query += t }
        onSpecial: function (name) {
            if (name === "backspace") search.query = search.query.slice(0, -1)
            else if (name === "clear") search.query = ""
            else if (name === "enter" && search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() }
        }
        onLeave: function (dir) {
            if (dir === "up") {
                if (search.suggestions.length) { search.zone = "suggestions"; search.suggestion = search.suggestions.length - 1; sugBox.forceActiveFocus() }
                else search.upFromTop()
            } else if (dir === "left" && search.shown.length) {
                search.zone = "grid"
                grid.forceActiveFocus()
            }
        }
    }
}
