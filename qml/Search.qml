import QtQuick

// search. a remote or a pad gets the tv terminal: results on the left, a right column with the
// query, suggestions and the on-screen keyboard. a mouse, a keyboard or a finger get one column:
// a real field to type in (select, copy, paste), suggestion chips, then the results. results come
// in two rows, shows then movies, each scrolling sideways
FocusScope {
    id: search
    property string query: ""
    property var results: []
    property var popTv: []
    property var popMovies: []
    property bool popularKnown: false
    property bool busy: false
    property string zone: "keys"             // keys | suggestions | field | chips | rows | grid
    property int suggestion: 0
    readonly property real u: Theme.u
    // real keyboards type here wherever the focus is: the input bindings leave it alone
    readonly property bool typing: true
    readonly property bool searching: query.trim().length > 1
    readonly property var showList: searching ? results.filter(function (x) { return x.kind === "show" }) : popTv
    readonly property var movieList: searching ? results.filter(function (x) { return x.kind === "movie" }) : popMovies
    // one list for the single sideways row a docked phone keyboard leaves room for; the pill
    // beside the field picks all, shows or movies (all each time search opens)
    property string kind: "all"
    readonly property var shown: kind === "show" ? showList : kind === "movie" ? movieList : showList.concat(movieList)
    onKindChanged: grid.positionViewAtBeginning()
    property var suggested: []

    // the on-screen keyboard is for a remote or a pad only: picked by what came into search, and it
    // comes up when one takes over while here (a real keyboard typing sends it away)
    property bool osk: false
    readonly property bool remoteish: Remote.inputKind === "remote" || Remote.inputKind === "pad"
    function pickKeyboard() { setOsk(!Theme.touch && !Theme.mouse && remoteish) }
    function setOsk(on) {
        if (on === osk) return
        osk = on
        if (!search.activeFocus) { zone = on ? "keys" : "field"; return }
        if (on && (zone === "field" || zone === "chips")) { zone = "keys"; keys.forceActiveFocus() }
        else if (!on && (zone === "keys" || zone === "suggestions")) focusField()
    }
    Connections {
        target: win
        function onPageChanged() { if (win.page === "search") search.pickKeyboard() }
    }
    Connections {
        target: Remote
        function onInputKindChanged() {
            if (!search.visible) return
            if (search.remoteish && !Theme.mouse && !Theme.touch) search.setOsk(true)
            else if (Remote.inputKind === "keyboard") search.setOsk(false)
        }
    }
    Connections {
        target: Theme
        function onMouseModeChanged() { if (search.visible && !Theme.mouse && search.remoteish && !Theme.touch) search.setOsk(true) }
    }

    // terminal metrics on the 1080 grid
    readonly property real columnW: 575 * u
    readonly property real columnX: width - Theme.margin - columnW
    readonly property real topY: 150 * u
    // touch on android: the phone's own keyboard types, ours goes away. the layout ends where it starts
    readonly property bool ime: Theme.touch
    readonly property bool flat: !osk
    // a pc's own field (a finger types through the hidden ime one)
    readonly property bool editable: flat && !ime
    readonly property real imeTop: Math.min(height, mapFromItem(null, 0, imeIn.keyboardTop).y)
    readonly property real bottomY: Math.min(height, imeTop) - 44 * u
    readonly property real gridGap: 40 * u
    readonly property real fullW: width - 2 * Theme.margin
    readonly property real listTop: (chips.visible ? chips.y + chips.height : field.y + field.height) + 26 * u
    // the results' box: left of the column with the keyboard, under the field without it
    readonly property real areaTop: osk ? topY : listTop
    readonly property real areaRight: osk ? columnX - 56 * u : width
    // the rows fade out where they run on (into the keyboard column, or off the screen)
    readonly property real fadeEnd: (osk ? 150 : 190) * u
    readonly property real rowGap: (Theme.short ? 18 : 40) * u
    readonly property int rowCount: (showList.length ? 1 : 0) + (movieList.length ? 1 : 0)
    // two rows share the height (a lone row gets the same size: nothing jumps between searches)
    readonly property real rowPoster: Math.min(214, ((bottomY - areaTop) / 2 - 38 * u - rowGap - 30 * u) / 1.5 / u)
    // a docked phone keyboard leaves less than two rows: one row of both, sideways, right above it
    readonly property real rowPosterW: (bottomY - listTop - 26 * u) / 1.5
    readonly property bool squeezed: flat && rowPoster < 110
    // too little even for that: the field and the chips only, the results come back when the
    // keyboard goes (a chip tap sends it away)
    readonly property bool tight: squeezed && rowPosterW < 110 * u
    readonly property real posterW: Math.max(110 * u, Math.min(230 * u, rowPosterW))
    readonly property var suggestions: {
        // typing: what people likely mean, from the core's ranking; else what's trending
        var src = searching ? suggested : popTv.map(function (x) { return x.title }), out = []
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
        if (win.page === "search") pickKeyboard()
        Api.call("home.row", { id: "popular-tv" }, function (ok, t) {
            search.popTv = ok ? t : []
            Api.call("home.row", { id: "popular-movie" }, function (ok2, m) {
                search.popMovies = ok2 ? m : []
                search.popularKnown = true
            })
        })
    }
    function focusField() {
        zone = "field"
        if (editable) { editLine.forceActiveFocus(); editLine.cursorPosition = editLine.text.length }
        else if (ime) imeOpen()
        else keys.forceActiveFocus()
    }
    // a real keyboard's first letter, typed while the bar still has the focus
    function typeFromBar(t) {
        query += t
        if (osk) { zone = "keys"; keys.forceActiveFocus() }
        else focusField()
    }
    // a key anywhere on the page: letters and backspace go to the query, and the field (or keys) take over
    function typeKey(e) {
        if (e.key === Qt.Key_Backspace) { query = query.slice(0, -1); e.accepted = true; return }
        if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & Qt.ControlModifier)) {
            typeFromBar(e.text)
            e.accepted = true
        }
    }
    // the rows: the one the focus was in, or the first that has titles
    property int lastRow: 0
    function focusRows(which) {
        var r = which !== undefined ? which : lastRow
        if (r === 1 && !movieList.length) r = 0
        if (r === 0 && !showList.length) r = 1
        if (!(r === 0 ? showList : movieList).length) return false
        zone = "rows"
        ;(r === 0 ? showsRow : moviesRow).forceActiveFocus()
        return true
    }
    // up out of the results: the chips, the field, or the bar (the keyboard column is to the right)
    function upFromRows() {
        if (osk) upFromTop()
        else if (chips.visible && !ime) { zone = "chips"; chips.forceActiveFocus() }
        else focusField()
    }
    // back from a title or the bar: where the focus was
    onActiveFocusChanged: {
        if (!activeFocus) return
        if (zone === "rows" && focusRows()) return
        if (zone === "grid" && shown.length) grid.forceActiveFocus()
        else if (zone === "suggestions" && osk && suggestions.length) sugBox.forceActiveFocus()
        else if (zone === "chips" && chips.visible && !ime) chips.forceActiveFocus()
        else if (zone === "kinds" && kinds.visible) kinds.forceActiveFocus()
        else if (osk) keys.forceActiveFocus()
        else focusField()
    }

    // busy from the first letter on: the wait isn't "no results"
    onQueryChanged: {
        var q = query.trim()
        // a new search starts on all; back from a title keeps the pick
        if (!q) kind = "all"
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

    // ---- results: shows, then movies (the column with the keyboard cuts them off on the right)
    Item {
        id: area
        visible: !search.squeezed
        y: search.areaTop
        width: search.areaRight
        height: search.bottomY - y
        clip: search.osk
        MediaRow {
            id: showsRow
            width: parent.width
            posterW: search.rowPoster
            fadeEnd: search.fadeEnd
            title: search.searching ? qsTr("Shows") : qsTr("Popular Shows")
            items: search.showList
            loading: !search.popularKnown && !search.searching
            visible: items.length > 0 || loading
            optionsEnabled: true
            menuItem: search.menuItem
            onActiveFocusChanged: if (activeFocus) { search.zone = "rows"; search.lastRow = 0 }
            onActivated: function (it) { search.open(it) }
            onMenu: function (it, index, at) { search.menu(it, "", at) }
            Keys.onUpPressed: search.upFromRows()
            Keys.onDownPressed: search.focusRows(1)
            Keys.onRightPressed: if (search.osk) search.focusColumn(showsRow.y)
            Keys.onPressed: function (e) { search.typeKey(e) }
        }
        MediaRow {
            id: moviesRow
            y: showsRow.visible ? showsRow.height : 0
            width: parent.width
            posterW: search.rowPoster
            fadeEnd: search.fadeEnd
            title: search.searching ? qsTr("Movies") : qsTr("Popular Movies")
            items: search.movieList
            loading: !search.popularKnown && !search.searching
            visible: items.length > 0 || loading
            optionsEnabled: true
            menuItem: search.menuItem
            onActiveFocusChanged: if (activeFocus) { search.zone = "rows"; search.lastRow = 1 }
            onActivated: function (it) { search.open(it) }
            onMenu: function (it, index, at) { search.menu(it, "", at) }
            Keys.onUpPressed: if (!search.focusRows(0) || !showsRow.visible) search.upFromRows()
            Keys.onRightPressed: if (search.osk) search.focusColumn(moviesRow.y)
            Keys.onPressed: function (e) { search.typeKey(e) }
        }
        // new results on the way over the old ones
        Spinner {
            anchors { right: parent.right; rightMargin: Theme.margin }
            y: 2 * search.u
            width: 30 * search.u; height: width
            color: Theme.fg2
            visible: search.busy && search.results.length > 0
            running: visible && search.visible
        }
    }

    // ---- a docked phone keyboard: one row of both, sideways, right above it
    ListWheel { view: grid; cards: true }
    GridView {
        id: grid
        x: 0
        leftMargin: Theme.margin - search.gridGap / 2
        rightMargin: leftMargin
        y: search.listTop - 8 * search.u
        width: search.width
        height: cellHeight
        flow: GridView.FlowTopToBottom
        visible: opacity > 0
        opacity: search.squeezed && !search.tight ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        cellWidth: search.posterW + search.gridGap
        cellHeight: search.posterW * 1.5 + 24 * search.u
        clip: Input.pointing
        model: search.squeezed ? search.shown.length : 0
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? GridView.NoHighlightRange : GridView.ApplyRange
        preferredHighlightBegin: 30 * search.u
        preferredHighlightEnd: width - 60 * search.u
        highlightMoveDuration: 320
        cacheBuffer: 600 * search.u
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
        Keys.onUpPressed: search.upFromRows()
        Keys.onReturnPressed: if (search.shown.length) search.open(search.shown[currentIndex])
        Keys.onMenuPressed: function (event) {
            if (!currentItem || !search.shown.length) { event.accepted = false; return }
            var w = search.posterW, h = w * 1.5
            var p = currentItem.mapToItem(null, (grid.cellWidth - w) / 2 - w * 0.05, 10 * search.u - h * 0.05)
            search.menu(search.shown[currentIndex], "", Qt.rect(p.x, p.y, w * 1.1, h * 1.1))
        }
        Keys.onPressed: function (e) { search.typeKey(e) }
    }

    // the first results on their way
    Spinner {
        x: (search.areaRight - width) / 2
        y: search.squeezed ? grid.y + grid.height / 2 - 36 * search.u : search.areaTop + 240 * search.u
        width: 72 * search.u; height: width
        visible: search.busy && search.results.length === 0 && !search.tight
        running: visible && search.visible
    }
    // nothing found: say so where the results would be
    Column {
        visible: search.searching && !search.busy && (search.squeezed ? search.shown.length : search.results.length) === 0 && !search.tight
        x: (search.areaRight - width) / 2
        y: search.areaTop + (search.squeezed ? 40 : 160) * search.u
        spacing: 22 * search.u
        Symbol {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 96 * search.u; height: width
            name: "search"; weight: 1.6
            color: Theme.fg3
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, search.areaRight - 2 * Theme.margin)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: (search.squeezed && search.kind === "show" && search.results.length ? qsTr("No shows for “%1”")
                   : search.squeezed && search.kind === "movie" && search.results.length ? qsTr("No movies for “%1”")
                   : qsTr("No results for “%1”")).arg(search.query.trim())
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
        if (suggestions.length && y < sugBox.y + sugBox.height - areaTop) { zone = "suggestions"; sugBox.forceActiveFocus() }
        else { zone = "keys"; keys.forceActiveFocus() }
    }

    // ---- the query: the column's top with the keyboard, the full width without it
    Rectangle {
        id: field
        x: search.flat ? Theme.margin : search.columnX
        y: search.topY - 8 * search.u
        width: search.flat ? search.fullW - (kinds.visible ? kinds.width + 16 * search.u : 0) : search.columnW
        height: 64 * search.u
        radius: height / 2
        color: Qt.rgba(1, 1, 1, editLine.activeFocus ? 0.14 : 0.1)
        border.width: 1 * search.u
        border.color: Qt.rgba(1, 1, 1, editLine.activeFocus ? 0.3 : 0.14)
        Symbol {
            id: glassIcon
            anchors { left: parent.left; leftMargin: 24 * search.u; verticalCenter: parent.verticalCenter }
            width: 26 * search.u; height: width; name: "search"; weight: 2.2; color: Theme.fg2
        }
        FieldText {
            visible: !search.editable
            anchors { left: glassIcon.right; leftMargin: 16 * search.u; right: parent.right; rightMargin: 24 * search.u; verticalCenter: parent.verticalCenter }
            text: search.ime ? imeIn.displayText : search.query
            placeholder: qsTr("Movies and shows")
            active: search.visible && (search.ime ? imeIn.activeFocus : keys.activeFocus)
            size: 26 * search.u
        }
        EditLine {
            id: editLine
            visible: search.editable
            enabled: visible
            anchors { left: glassIcon.right; leftMargin: 25 * search.u; right: parent.right; rightMargin: 24 * search.u; verticalCenter: parent.verticalCenter }
            value: search.query
            placeholder: qsTr("Movies and shows")
            size: 26 * search.u
            onEdited: function (t) { search.query = t }
            onActiveFocusChanged: if (activeFocus) search.zone = "field"
            onDone: search.focusRows(0)
            Keys.onUpPressed: search.upFromTop()
            Keys.onDownPressed: { if (chips.visible) { search.zone = "chips"; chips.forceActiveFocus() } else search.focusRows(0) }
        }
        ImeInput {
            id: imeIn
            value: search.query
            EnterKey.type: Qt.EnterKeySearch
            onEdited: function (t) { search.query = t }
            onDone: if (search.shown.length) { if (search.squeezed) { search.zone = "grid"; grid.forceActiveFocus() } else search.focusRows(0) }
            Keys.onUpPressed: search.upFromTop()
        }
        Pointer {
            visible: !search.editable
            okKey: false
            takesFocus: false
            cursorShape: Qt.IBeamCursor
            onTapped: { if (search.ime) search.imeOpen(); else { search.zone = "keys"; keys.forceActiveFocus() } }
        }
    }
    function imeOpen() { zone = "keys"; imeIn.open() }
    // opened by touch: typing is what search is for
    onVisibleChanged: {
        if (visible && ime) Qt.callLater(imeOpen)
    }

    // ---- small screens: all | shows | movies beside the field, same height, a white capsule on the pick
    FocusScope {
        id: kinds
        visible: search.squeezed
        x: field.x + field.width + 16 * search.u
        y: field.y
        width: kindRow.width + 2 * inset
        height: field.height
        readonly property real inset: 6 * search.u
        readonly property var order: ["all", "show", "movie"]
        readonly property int at: order.indexOf(search.kind)
        onActiveFocusChanged: if (activeFocus) search.zone = "kinds"
        function step(d) { var i = Math.max(0, Math.min(2, at + d)); search.kind = order[i] }
        Keys.onLeftPressed: step(-1)
        Keys.onRightPressed: step(1)
        Keys.onUpPressed: search.upFromTop()
        Keys.onDownPressed: { if (chips.visible && !search.ime) { search.zone = "chips"; chips.forceActiveFocus() } else if (search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() } }
        Keys.onPressed: function (e) { search.typeKey(e) }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.1)
            border.width: 1 * search.u
            border.color: Qt.rgba(1, 1, 1, kinds.activeFocus ? 0.3 : 0.14)
        }
        // the pick: slides between the segments
        // the picked segment's place (each segment hands it over while it's the pick)
        property real pickX: 0
        property real pickW: 0
        Rectangle {
            x: kinds.inset + kinds.pickX
            y: kinds.inset
            width: kinds.pickW
            height: kinds.height - 2 * kinds.inset
            radius: height / 2
            color: "white"
            opacity: Theme.touch || kinds.activeFocus || !Input.pointing ? 1 : 0.92
            Behavior on x { enabled: kinds.visible; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on width { enabled: kinds.visible; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        }
        Row {
            id: kindRow
            x: kinds.inset
            height: kinds.height
            Repeater {
                id: kindRep
                model: [qsTr("All"), qsTr("Shows"), qsTr("Movies")]
                Item {
                    id: seg
                    required property string modelData
                    required property int index
                    readonly property bool picked: kinds.at === index
                    // sized for the bold pick: nothing shifts when the pick moves
                    TextMetrics { id: segBold; text: seg.modelData; font { family: Theme.display; pixelSize: 24 * search.u; weight: Font.DemiBold } }
                    width: Math.ceil(segBold.advanceWidth) + 2 * 26 * search.u
                    height: kindRow.height
                    Binding { target: kinds; property: "pickX"; value: seg.x; when: seg.picked; restoreMode: Binding.RestoreNone }
                    Binding { target: kinds; property: "pickW"; value: seg.width; when: seg.picked; restoreMode: Binding.RestoreNone }
                    Text {
                        id: segText
                        anchors.centerIn: parent
                        text: seg.modelData
                        color: seg.picked ? Theme.focusFg : Theme.hover(segPt) ? Theme.fg : Theme.fg2
                        font { family: Theme.display; pixelSize: 24 * search.u; weight: seg.picked ? Font.DemiBold : Font.Medium }
                        Behavior on color { ColorAnimation { duration: 160 } }
                    }
                    Pointer {
                        id: segPt
                        okKey: false
                        takesFocus: false
                        onTapped: {
                            search.kind = kinds.order[seg.index]
                            // the keyboard (docked or floating) covers the results: picking means looking
                            if (search.ime) Qt.inputMethod.hide()
                        }
                    }
                }
            }
        }
    }

    // without the keyboard column: the suggestions as one row of chips under the field
    ListView {
        id: chips
        visible: search.flat && search.suggestions.length > 0
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
        keyNavigationEnabled: true
        highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
        preferredHighlightBegin: Theme.margin
        preferredHighlightEnd: width - Theme.margin
        onActiveFocusChanged: if (activeFocus) search.zone = "chips"
        Keys.onUpPressed: { if (kinds.visible) { search.zone = "kinds"; kinds.forceActiveFocus() } else search.focusField() }
        Keys.onDownPressed: { if (search.squeezed) { if (search.shown.length) { search.zone = "grid"; grid.forceActiveFocus() } } else search.focusRows(0) }
        Keys.onReturnPressed: if (currentIndex >= 0 && currentIndex < search.suggestions.length) search.query = search.suggestions[currentIndex]
        Keys.onPressed: function (e) { search.typeKey(e) }
        delegate: KeyCap {
            id: chip
            required property var modelData
            required property int index
            u: search.u / 2
            fn: true
            grow: 1.06
            radius: height / 2
            width: chipText.implicitWidth + 48 * search.u
            height: chips.height
            focused: !search.ime && Theme.lit(chips.activeFocus && chips.currentIndex === index, chipPt)
            Pointer {
                id: chipPt
                okKey: false
                onTapped: { chip.pop(); search.query = chip.modelData; if (search.ime) Qt.inputMethod.hide() }
            }
            Text {
                id: chipText
                anchors.centerIn: parent
                text: chip.modelData
                font { family: Theme.display; pixelSize: 24 * search.u; weight: Font.Medium }
                color: chip.focused ? Theme.focusFg : "white"
            }
        }
    }

    FocusScope {
        id: sugBox
        visible: search.osk
        x: search.columnX
        y: field.y + field.height + 30 * search.u
        width: search.columnW
        height: kb.y - 22 * search.u - y
        focus: search.zone === "suggestions"
        onActiveFocusChanged: if (activeFocus) search.zone = "suggestions"
        // as many as fit (all six when there's room)
        readonly property int fits: Math.max(1, Math.min(search.suggestions.length, Math.floor((height - sugTitle.height - 12 * search.u + 8 * search.u) / (46 * search.u + 8 * search.u))))
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
                focused: Theme.lit(sugBox.activeFocus && search.suggestion === index, sugPt)
                z: focused ? 1 : 0
                Pointer {
                    id: sugPt
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
        Keys.onLeftPressed: search.focusRows()
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
                if (typed && Input.realKey()) search.focusRows(0)
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
        visible: search.osk
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
            else if (name === "enter") search.focusRows(0)
        }
        onLeave: function (dir) {
            if (dir === "up") {
                if (search.suggestions.length) { search.zone = "suggestions"; search.suggestion = sugBox.fits - 1; sugBox.forceActiveFocus() }
                else search.upFromTop()
            } else if (dir === "left") {
                search.focusRows(1)
            }
        }
    }
}
