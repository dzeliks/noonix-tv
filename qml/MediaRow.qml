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
        if (Input.pointing) return Math.round((list.contentX - list.originX + list.leftMargin) / step)
        return Math.min(list.currentIndex - restSlot, Math.ceil(Math.max(0, overrun - slack) / step - 0.01))
    }
    // a new list (a removal, an undo, a refresh) keeps the focus on the same title, else the same spot
    property string keepKey: ""
    property int keepIndex: 0
    property bool restoring: false
    function keyOf(it) { return it ? [it.kind, it.id, it.show, it.season, it.episode].join(":") : "" }
    // the model is only a count: cards read their item from the js list (a js array as the model
    // goes through qvariant maps for every card, and that churn wakes the gc mid-scroll)
    onItemsChanged: {
        restoring = true
        list.model = items.length
        restore()
    }
    Component.onCompleted: list.model = items.length
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
    // a removal ran out: the home page takes the title out of its list
    signal take(var item)
    function activate() {
        if (!row.current) return
        var rec = win.removalOf(row.current)
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
        highlightRangeMode: Input.pointing ? ListView.NoHighlightRange : ListView.ApplyRange
        preferredHighlightBegin: Theme.margin + row.restSlot * (row.cardW + spacing)
        preferredHighlightEnd: preferredHighlightBegin + row.cardW
        highlightMoveDuration: 380
        highlightMoveVelocity: -1
        boundsBehavior: Flickable.StopAtBounds
        delegate: Card {
            required property int index
            media: row.items[index] || ({})
            style: row.style
            onGone: row.finishLeave(media)
            focused: ListView.isCurrentItem && (list.activeFocus || row.menuItem === media)
            z: focused ? 1 : 0
            // cards scrolled into the margin leave instead of peeking
            opacity: index < row.firstShown ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 220 } }
        }
        Keys.onReturnPressed: row.activate()
        Keys.onEnterPressed: row.activate()
        Keys.onMenuPressed: function (event) {
            if (row.current && win.removalOf(row.current)) { row.activate(); return }
            if (!row.optionsEnabled || !row.current || !list.currentItem) { event.accepted = false; return }
            var card = list.currentItem
            var p = card.mapToItem(null, -card.width * 0.05, -card.artH * 0.05)
            row.menu(row.current, list.currentIndex, Qt.rect(p.x, p.y, card.width * 1.1, card.artH * 1.1))
        }
    }

    // ---- a removal's end: the card fades out to the side and the rest slide up to fill the gap; off
    // screen nothing moves, the title is simply gone when you come back
    function indexOfKey(k) {
        for (var i = 0; i < items.length; ++i) if (keyOf(items[i]) === k) return i
        return -1
    }
    function onScreen(c) {
        for (var d = c; d; d = d.parent) if (!d.visible) return false
        var p = c.mapToItem(null, 0, 0)
        return p.x + c.width > 0 && p.x < win.width && p.y + c.height > 0 && p.y < win.height
    }
    function leave(item) {
        var i = indexOfKey(keyOf(item))
        if (i < 0) return
        var c = list.itemAtIndex(i)
        if (c && onScreen(c)) c.startLeave()
        else cut(item, false)
    }
    function finishLeave(item) { cut(item, true) }
    function cut(item, seen) {
        var before = {}, kids = list.contentItem.children, k
        for (k = 0; k < kids.length; ++k) {
            var c = kids[k]
            if (c.media !== undefined && c.visible) before[keyOf(c.media)] = c.mapToItem(row, 0, 0).x
        }
        row.take(item)
        if (!list) return
        list.forceLayout()
        var moved = []
        kids = list.contentItem.children
        for (k = 0; k < kids.length; ++k) {
            c = kids[k]
            if (c.media === undefined || !c.visible) continue
            var was = before[keyOf(c.media)]
            if (was === undefined) continue
            var d = was - c.mapToItem(row, 0, 0).x
            if (Math.abs(d) > 0.5) moved.push({ c: c, d: d })
        }
        // gone from off screen on the left with the mouse about: the view holds, nothing slides
        if (!seen && Input.pointing && moved.length && list.contentX - list.originX > 1) {
            list.contentX -= moved[0].d
            return
        }
        moved.forEach(function (m) { m.c.flip(m.d) })
    }

    ListWheel { view: list; across: true; cards: true }
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
