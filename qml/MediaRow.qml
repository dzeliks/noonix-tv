import QtQuick

// a titled horizontal row; the focus rests on the 2nd slot (3rd for posters) and the row
// slides under it, so what came before stays in view
FocusScope {
    id: row
    property string rowId: ""
    property string title: ""
    property string style: "poster"
    property var items: []
    property bool loading: false
    property bool optionsEnabled: false
    property var menuItem: null
    property alias currentIndex: list.currentIndex
    readonly property var current: items.length ? items[Math.min(list.currentIndex, items.length - 1)] : null
    readonly property real u: Theme.u
    readonly property real cardH: style === "poster" ? 214 * u * 1.5 : 400 * u * 9 / 16 + 92 * u
    readonly property real cardW: (style === "poster" ? 214 : 400) * u
    readonly property int restSlot: style === "poster" ? 2 : 1
    // a hair too wide for the screen (4 landscape cards): the margin gives way, the row stays put
    readonly property real overrun: items.length * (cardW + list.spacing) - list.spacing + 2 * Theme.margin - width
    readonly property real slack: overrun > 0 && overrun < Theme.margin / 2 ? overrun : 0
    // first card left in view: the rest slot, or less once the row has hit its end
    // (the mouse doesn't scroll the row: then it's where the row really is)
    readonly property int firstShown: {
        var step = cardW + list.spacing
        if (Input.pointing || wheel.heldAt >= 0) return Math.round((list.contentX - list.originX + list.leftMargin) / step)
        return Math.min(list.currentIndex - restSlot, Math.ceil(Math.max(0, overrun - slack) / step - 0.01))
    }
    // a new list (a removal, an undo, a refresh) keeps the focus on the same title, else the same spot
    property string keepKey: ""
    property int keepIndex: 0
    property bool restoring: false
    function keyOf(it) { return it ? [it.kind, it.id, it.show, it.season, it.episode].join(":") : "" }
    // the model holds keys only, cards read their item from byKey (a js array as the model goes
    // through qvariant maps for every card, and that churn wakes the gc mid-scroll). changes go in as
    // inserts and removes, so a refresh rebuilds nothing and a removal is a real one: the view keeps
    // what's on screen where it is when the title left from outside it
    ListModel { id: cards }
    property var byKey: ({})
    function sync() {
        var m = byKey, want = [], used = {}, count = {}, i
        for (i = 0; i < items.length; ++i) {
            var k = keyOf(items[i]), n = count[k] || 0
            count[k] = n + 1
            var id = n ? k + "#" + n : k
            m[id] = items[i]
            want.push(id)
            used[id] = true
        }
        byKey = m
        if (!cards.count) {
            cards.append(want.map(function (x) { return { cardKey: x } }))
            return
        }
        for (i = cards.count - 1; i >= 0; --i) if (!used[cards.get(i).cardKey]) cards.remove(i)
        for (i = 0; i < want.length; ++i) {
            if (i < cards.count && cards.get(i).cardKey === want[i]) continue
            var from = -1
            for (var j = i + 1; j < cards.count && from < 0; ++j) if (cards.get(j).cardKey === want[i]) from = j
            if (from >= 0) cards.move(from, i, 1)
            else cards.insert(i, { cardKey: want[i] })
        }
    }
    onItemsChanged: {
        restoring = true
        sync()
        restore()
    }
    Component.onCompleted: sync()
    // the next change is a removal: it animates (a refresh just changes)
    property bool sliding: false
    function slide() { sliding = true; slideEnd.restart() }
    Timer { id: slideEnd; interval: 700; onTriggered: row.sliding = false }
    // only the rows a removal is for
    readonly property bool undoable: ["upnext", "continue", "continue-movie", "recent"].indexOf(rowId) >= 0
    function restore() {
        var i = -1
        for (var k = 0; k < items.length && keepKey; ++k) if (keyOf(items[k]) === keepKey) { i = k; break }
        if (i < 0) i = Math.min(keepIndex, items.length - 1)
        if (i >= 0 && i !== list.currentIndex) {
            var d = list.highlightMoveDuration
            list.highlightMoveDuration = 0
            list.currentIndex = i
            list.highlightMoveDuration = d
        }
        restoring = false
        remember()
    }
    function remember() { if (!restoring && items.length) { keepIndex = list.currentIndex; keepKey = keyOf(items[list.currentIndex]) } }
    signal activated(var item)
    function activate() {
        if (!row.current) return
        var rec = row.undoable ? win.removalOf(row.current) : null
        if (rec) { if (!rec.done) win.undoRemoval(row.current); return }
        row.activated(row.current)
    }
    signal menu(var item, int index, rect at)

    // the focused card grows 10 %: leave it room under the title
    readonly property real gap: 40 * u
    height: header.height + gap + cardH + 30 * u

    Text {
        id: header
        x: Theme.margin
        text: row.title
        color: row.activeFocus ? Theme.fg : Theme.fg2
        font { family: Theme.display; pixelSize: 31 * row.u; weight: Font.DemiBold }
        Behavior on color { ColorAnimation { duration: 180 } }
    }
    // a placeholder row (no title yet) has a placeholder title
    Rectangle {
        visible: row.title === ""
        x: Theme.margin
        anchors.verticalCenter: header.verticalCenter
        width: 260 * row.u; height: 24 * row.u; radius: height / 2
        color: Theme.skeleton
    }
    // the options are one key away: say so on the focused row
    KeyHint {
        anchors { right: parent.right; rightMargin: Theme.margin; verticalCenter: header.verticalCenter }
        visible: opacity > 0
        opacity: row.optionsEnabled && row.activeFocus && row.items.length ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
        key: "MENU"
        label: qsTr("Options")
        pointLabel: Qt.platform.os === "android" ? qsTr("Hold an item for options") : qsTr("Right-click for options")
        pad: Remote.inputKind === "pad"
        u: row.u * 0.82
        labelColor: Theme.fg3
    }

    ListView {
        id: list
        y: header.height + row.gap
        width: parent.width
        height: row.cardH + 30 * row.u
        orientation: ListView.Horizontal
        focus: true
        spacing: (row.style === "poster" ? 34 : 44) * row.u
        leftMargin: Theme.margin
        rightMargin: Theme.margin - row.slack
        clip: false
        reuseItems: true
        cacheBuffer: 1200 * row.u
        keyNavigationEnabled: true
        onCurrentIndexChanged: row.remember()
        // the range would chase the current card through its slide
        highlightRangeMode: Input.pointing || row.sliding ? ListView.NoHighlightRange : ListView.ApplyRange
        preferredHighlightBegin: wheel.heldAt >= 0 ? wheel.heldAt : wheel.restX
        preferredHighlightEnd: preferredHighlightBegin + row.cardW
        highlightMoveDuration: 380
        highlightMoveVelocity: -1
        boundsBehavior: Flickable.StopAtBounds
        model: cards
        // a title leaves to the side, fading, while the others close up
        remove: Transition {
            enabled: row.sliding
            NumberAnimation { property: "leaveT"; to: 1; duration: 240; easing.type: Easing.OutQuad }
        }
        displaced: Transition {
            enabled: row.sliding
            NumberAnimation { property: "x"; duration: 320; easing.type: Easing.OutCubic }
        }
        delegate: Card {
            required property int index
            required property string cardKey
            media: row.byKey[cardKey] || ({})
            style: row.style
            undoable: row.undoable
            ListView.onReused: leaveT = 0
            focused: ListView.isCurrentItem && (list.activeFocus || row.menuItem === media)
            z: focused ? 1 : 0
            // cards scrolled into the margin leave instead of peeking
            opacity: index < row.firstShown ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 220 } }
        }
        Keys.onReturnPressed: row.activate()
        Keys.onEnterPressed: row.activate()
        Keys.onMenuPressed: function (event) {
            if (row.undoable && row.current && win.removalOf(row.current)) { row.activate(); return }
            if (!row.optionsEnabled || !row.current || !list.currentItem) { event.accepted = false; return }
            var card = list.currentItem
            var p = card.mapToItem(null, -card.width * 0.05, -card.artH * 0.05)
            row.menu(row.current, list.currentIndex, Qt.rect(p.x, p.y, card.width * 1.1, card.artH * 1.1))
        }
    }

    ListWheel { id: wheel; view: list; across: true; cards: true; restX: Theme.margin + row.restSlot * (row.cardW + list.spacing); cardW: row.cardW }
    RowArrows {
        view: list
        restSlot: row.restSlot
        cardW: row.cardW
        artH: row.style === "poster" ? row.cardH : row.cardW * 9 / 16
    }

    // placeholder cards until the row has its titles
    Row {
        x: Theme.margin
        y: list.y
        spacing: list.spacing
        visible: opacity > 0
        opacity: row.loading && row.items.length === 0 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Repeater {
            model: Math.ceil((row.width - Theme.margin) / (row.cardW + list.spacing))
            // required: the delegate's context would otherwise shadow the ids here (row)
            Skeleton { required property int index; style: row.style; cardW: row.cardW }
        }
    }

    Text {
        visible: !row.loading && row.items.length === 0
        x: Theme.margin
        y: list.y + 40 * row.u
        text: qsTr("Nothing here yet")
        color: Theme.fg3
        font { family: Theme.text; pixelSize: 24 * row.u }
    }
}
