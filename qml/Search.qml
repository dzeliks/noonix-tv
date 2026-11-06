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
    // real keyboards type here wherever the focus is: the input bindings leave it alone
    readonly property bool typing: true
    readonly property bool searching: query.trim().length > 1
    readonly property var shown: searching ? results : popular
    property var suggested: []
    // terminal metrics on the 1080 grid
    readonly property real columnW: 575 * u
    readonly property real columnX: width - Theme.margin - columnW
    readonly property real topY: 150 * u
    // touch on android: the phone's own keyboard types, ours goes away. the layout ends where it starts
    readonly property bool ime: Theme.touch
    readonly property real imeTop: Math.min(height, mapFromItem(null, 0, imeIn.keyboardTop).y)
    readonly property real bottomY: Math.min(height, imeTop) - 44 * u
    readonly property real gridGap: 40 * u
    // phone / tablet with its own keyboard: one column over the full width (field, suggestion
    // chips, results). a docked keyboard leaves less than a row: the results become one row
    // sideways right above it
    readonly property real fullW: width - 2 * Theme.margin
    readonly property int imeCols: Math.max(4, Math.min(8, Math.round((fullW + gridGap) / (230 * u + gridGap))))
    readonly property real listTop: (chips.visible ? chips.y + chips.height : field.y + field.height) + 26 * u
    readonly property real fullPosterW: (fullW - (imeCols - 1) * gridGap) / imeCols
    readonly property bool squeezed: ime && bottomY - listTop < gridTitle.height + 18 * u + 10 * u + fullPosterW * 1.5 + gridGap
    readonly property real rowPosterW: (bottomY - listTop - 26 * u) / 1.5
    // too little even for that (a docked keyboard on a phone): the field and the chips only, the
    // results come back when the keyboard goes (a chip tap sends it away)
    readonly property bool tight: squeezed && rowPosterW < 110 * u
    readonly property real posterW: !ime ? (columnX - 64 * u - Theme.margin - 3 * gridGap) / 4
        : squeezed ? Math.max(110 * u, Math.min(fullPosterW, rowPosterW))
        : fullPosterW
    readonly property var suggestions: {
        // typing: what people likely mean, from the core's ranking; else what's trending
        var src = searching ? suggested : trending.map(function (x) { return x.title }), out = []
        for (var i = 0; i < src.length && out.length < 6; ++i) {
            var t = src[i]
            if (t && out.indexOf(t) < 0 && t.toLowerCase() !== query.trim().toLowerCase()) out.push(t)
        }
        return out
    }
    signal open(var item)
    signal menu(var item, string rowId, rect at)
    signal upFromTop()
    property var menuItem: null

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
    // a real keyboard's first letter, typed while the bar still has the focus
    function typeFromBar(t) {
        zone = "keys"
        keys.forceActiveFocus()
        query += t
    }
    // a key anywhere on the page: letters and backspace go to the query, and the keys take over
    function typeKey(e) {
        if (e.key === Qt.Key_Backspace) { query = query.slice(0, -1); e.accepted = true; return }
        if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) {
            typeFromBar(e.text)
            e.accepted = true
        }
    }
    // back from a title or the bar: where the focus was (the results, a suggestion or the keys)
    onActiveFocusChanged: {
        if (!activeFocus) return
        if (zone === "grid" && shown.length) grid.forceActiveFocus()
        else if (zone === "suggestions" && suggestions.length) sugBox.forceActiveFocus()
        else keys.forceActiveFocus()
    }

    // busy from the first letter on: the wait isn't "no results"
    onQueryChanged: {
        var q = query.trim()
        if (q.length < 2) { results = []; suggested = []; busy = false; debounce.stop(); return }
        busy = true
        debounce.restart()
    }
    Timer {
        id: debounce
        interval: 320
        onTriggered: {
            var q = search.query.trim()
            if (q.length < 2) return
            Api.call("tmdb.search", { query: q }, function (ok, d) {
                if (q !== search.query.trim()) return
                search.busy = false
                search.results = ok ? (d.results || d || []) : []
            })
            Api.call("tmdb.suggest", { query: q }, function (ok, d) {
                if (q === search.query.trim()) search.suggested = ok ? d : []
            })
        }
    }

    // like a home row's title
    component Section: Text {
        font { family: Theme.display; pixelSize: 31 * search.u; weight: Font.DemiBold }
        color: Theme.fg2
    }

    // ---- left: results
    Section {
        id: gridTitle
        x: Theme.margin
        // touch: under the field (a docked keyboard's single row goes without it)
        y: search.ime ? search.listTop : search.topY
        visible: !search.squeezed
        text: search.busy ? qsTr("Searching…") : search.searching ? (search.results.length ? qsTr("Top results") : qsTr("No results")) : qsTr("Popular")
    }
    // new results on the way over the old ones
    Spinner {
        anchors { left: gridTitle.right; leftMargin: 18 * search.u; verticalCenter: gridTitle.verticalCenter }
        width: 30 * search.u; height: width
        color: Theme.fg2
        visible: search.busy && search.results.length > 0
        running: visible && search.visible
    }
    ListWheel { view: grid; cards: true }
    GridView {
        id: grid
        // one row: it runs to the screen's edges, starting in line with the field
        x: search.squeezed ? 0 : Theme.margin - search.gridGap / 2
        leftMargin: search.squeezed ? Theme.margin - search.gridGap / 2 : 0
        rightMargin: leftMargin
        y: search.squeezed ? search.listTop - 8 * search.u : gridTitle.y + gridTitle.height + 18 * search.u
        width: search.squeezed ? search.width : search.ime ? search.fullW + search.gridGap : cols * cellWidth
        height: search.squeezed ? cellHeight : search.bottomY - y
        readonly property int cols: search.ime ? search.imeCols : 4
        flow: search.squeezed ? GridView.FlowTopToBottom : GridView.FlowLeftToRight
        visible: opacity > 0
        opacity: search.tight ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 160 } }
        cellWidth: search.posterW + search.gridGap
        cellHeight: search.posterW * 1.5 + (search.squeezed ? 24 * search.u : search.gridGap)
        // the wheel stops at any pixel: nothing over the title
        clip: Input.pointing
        model: search.shown.length
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? GridView.NoHighlightRange : GridView.ApplyRange
        preferredHighlightBegin: 30 * search.u
        preferredHighlightEnd: height - 60 * search.u
        highlightMoveDuration: 320
        cacheBuffer: 600 * search.u
        focus: search.zone === "grid"
        onActiveFocusChanged: if (activeFocus) search.zone = "grid"
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
                focused: parent.GridView.isCurrentItem && (grid.activeFocus || search.menuItem === modelData)
            }
        }
        Keys.onRightPressed: function (e) {
            if (currentIndex % cols === cols - 1 || currentIndex === count - 1) search.focusColumn(currentItem ? currentItem.y - contentY : 0)
            else moveCurrentIndexRight()
        }
        Keys.onUpPressed: function (e) { if (currentIndex < cols) search.upFromTop(); else moveCurrentIndexUp() }
        Keys.onReturnPressed: if (search.shown.length) search.open(search.shown[currentIndex])
        Keys.onMenuPressed: function (event) {
            if (!currentItem || !search.shown.length) { event.accepted = false; return }
            var w = search.posterW, h = w * 1.5
            var p = currentItem.mapToItem(null, (grid.cellWidth - w) / 2 - w * 0.05, 10 * search.u - h * 0.05)
            search.menu(search.shown[currentIndex], "", Qt.rect(p.x, p.y, w * 1.1, h * 1.1))
        }
        Keys.onPressed: function (e) { search.typeKey(e) }
    }

    // popular on its way: placeholder posters where they'll be
    Grid {
        x: Theme.margin
        y: grid.y + 10 * search.u
        columns: grid.cols
        columnSpacing: search.gridGap
        rowSpacing: search.gridGap
        visible: opacity > 0
        opacity: !search.searching && search.shown.length === 0 && !search.popularKnown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Repeater {
            model: grid.cols * (search.squeezed ? 1 : 2)
            Skeleton { cardW: search.posterW }
        }
    }
    // the first results on their way
    Spinner {
        anchors.horizontalCenter: grid.horizontalCenter
        y: grid.y + (search.squeezed ? grid.height / 2 - 36 * search.u : 240 * search.u)
        width: 72 * search.u; height: width
        visible: search.busy && search.results.length === 0 && !search.tight
        running: visible && search.visible
    }
    // nothing found: say so where the results would be
    Column {
        visible: search.searching && !search.busy && search.results.length === 0 && !search.tight
        anchors.horizontalCenter: grid.horizontalCenter
        y: grid.y + (search.squeezed ? 40 : 160) * search.u
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
        x: search.ime ? Theme.margin : search.columnX
        y: search.topY - 8 * search.u
        width: search.ime ? search.fullW : search.columnW
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
            text: search.ime ? imeIn.displayText : search.query
            placeholder: qsTr("Movies and shows")
            active: search.visible && (!search.ime || imeIn.activeFocus)
            size: 26 * search.u
        }
        ImeInput {
            id: imeIn
            value: search.query
            EnterKey.type: Qt.EnterKeySearch
            onEdited: function (t) { search.query = t }
            onDone: if (search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() }
            Keys.onUpPressed: search.upFromTop()
        }
        Pointer {
            okKey: false
            takesFocus: false
            cursorShape: Qt.IBeamCursor
            onTapped: { if (search.ime) search.imeOpen(); else { search.zone = "keys"; keys.forceActiveFocus() } }
        }
    }
    function imeOpen() { zone = "keys"; imeIn.open() }
    // opened by touch: typing is what search is for
    onVisibleChanged: if (visible && ime) Qt.callLater(imeOpen)

    // touch: the suggestions as one row of chips under the field
    ListView {
        id: chips
        visible: search.ime && search.suggestions.length > 0
        y: field.y + field.height + 18 * search.u
        width: search.width
        leftMargin: Theme.margin
        rightMargin: Theme.margin
        height: 56 * search.u
        orientation: ListView.Horizontal
        spacing: 12 * search.u
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: visible ? search.suggestions : []
        delegate: KeyCap {
            id: chip
            required property var modelData
            u: search.u / 2
            fn: true
            radius: height / 2
            width: chipText.implicitWidth + 48 * search.u
            height: chips.height
            Pointer {
                okKey: false
                onTapped: { chip.pop(); search.query = chip.modelData; Qt.inputMethod.hide() }
            }
            Text {
                id: chipText
                anchors.centerIn: parent
                text: chip.modelData
                font { family: Theme.display; pixelSize: 24 * search.u; weight: Font.Medium }
                color: "white"
            }
        }
    }

    FocusScope {
        id: sugBox
        visible: !search.ime
        x: search.columnX
        y: search.ime ? search.topY : field.y + field.height + 30 * search.u
        width: search.columnW
        height: (search.ime ? search.bottomY : kb.y - 22 * search.u) - y
        focus: search.zone === "suggestions"
        onActiveFocusChanged: if (activeFocus) search.zone = "suggestions"
        // as many as fit at a size a finger hits (all six when there's room)
        readonly property int fits: Math.max(1, Math.min(search.suggestions.length, Math.floor((height - sugTitle.height - 12 * search.u + 8 * search.u) / ((search.ime ? 58 : 46) * search.u + 8 * search.u))))
        readonly property real chipH: Math.min(62 * search.u, (height - sugTitle.height - 12 * search.u - (fits - 1) * 8 * search.u) / fits)
        Section { id: sugTitle; text: qsTr("Suggestions"); visible: search.suggestions.length > 0 }
        Repeater {
            model: search.suggestions.slice(0, sugBox.fits)
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
                Pointer {
                    okKey: false
                    onPointed: { search.suggestion = sug.index; sugBox.forceActiveFocus() }
                    onTapped: search.query = sug.modelData
                }
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
            if (search.suggestion < sugBox.fits - 1) search.suggestion++
            else { search.zone = "keys"; kb.enterAt("top", 0.5); keys.forceActiveFocus() }
        }
        Keys.onLeftPressed: if (search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() }
        Keys.onReturnPressed: if (search.suggestions.length) search.query = search.suggestions[search.suggestion]
        Keys.onPressed: function (e) { search.typeKey(e) }
    }

    FocusScope {
        id: keys
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
                if (typed && Input.realKey()) { if (search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() } }
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
        visible: !search.ime
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
                if (search.suggestions.length) { search.zone = "suggestions"; search.suggestion = sugBox.fits - 1; sugBox.forceActiveFocus() }
                else search.upFromTop()
            } else if (dir === "left" && search.shown.length) {
                search.zone = "grid"
                grid.forceActiveFocus()
            }
        }
    }
}
