import QtQuick

// library: the videos on this pc, the watchlist (noonix tv + trakt) and what was watched, in a grid

FocusScope {
    id: library
    property int profileId: 0
    property string section: "watchlist"
    property var items: []
    property var menuItem: null
    property bool busy: false
    property bool failed: false
    property bool offline: false
    property int request: 0
    property bool ready: false
    readonly property real u: Theme.u
    readonly property bool history: section === "history"
    readonly property bool files: section === "files"
    // a library with videos opens on them, until a tab is picked
    property bool picked: false
    function tab(s) { picked = true; section = s }
    signal open(var item)
    signal menu(var item, string rowId, rect at)
    signal upFromTop()

    function load() {
        if (!ready) return
        var wanted = ++request
        busy = true; failed = false; offline = false
        Api.call("library.list", { section: section }, function (ok, d) {
            if (wanted !== library.request) return
            library.busy = false
            library.failed = !ok
            if (ok) {
                library.items = d.items
                library.offline = d.traktUnavailable
            }
        })
    }
    onSectionChanged: { items = []; load() }
    onProfileIdChanged: { items = []; load() }
    onVisibleChanged: if (visible) Qt.callLater(load)
    Component.onCompleted: {
        Api.call("library.status", {}, function (ok, d) { if (ok && d.files > 0 && !library.picked) library.section = "files" })
        ready = true; Qt.callLater(load)
    }

    Text {
        x: Theme.margin; y: 174 * library.u
        text: qsTr("Library")
        color: Theme.fg
        font { family: Theme.display; pixelSize: 52 * library.u; weight: Font.Bold }
    }
    Row {
        id: tabs
        x: Theme.margin; y: 260 * library.u
        spacing: 24 * library.u
        GlassButton {
            id: filesTab
            text: (Theme.android ? qsTr("On This Device") : qsTr("On This PC"))
            primary: library.files
            onClicked: library.tab("files")
            KeyNavigation.right: watchlist
            Keys.onDownPressed: if (library.items.length) grid.forceActiveFocus(); else if (library.failed) retry.forceActiveFocus()
            Keys.onUpPressed: library.upFromTop()
        }
        GlassButton {
            id: watchlist
            text: qsTr("Watchlist")
            primary: !library.history && !library.files
            focus: true
            onClicked: library.tab("watchlist")
            KeyNavigation.left: filesTab
            KeyNavigation.right: historyTab
            Keys.onDownPressed: if (library.items.length) grid.forceActiveFocus(); else if (library.failed) retry.forceActiveFocus()
            Keys.onUpPressed: library.upFromTop()
        }
        GlassButton {
            id: historyTab
            text: qsTr("History")
            primary: library.history
            onClicked: library.tab("history")
            KeyNavigation.left: watchlist
            Keys.onDownPressed: if (library.items.length) grid.forceActiveFocus(); else if (library.failed) retry.forceActiveFocus()
            Keys.onUpPressed: library.upFromTop()
        }
    }
    Text {
        anchors { right: parent.right; rightMargin: Theme.margin; verticalCenter: tabs.verticalCenter }
        text: library.offline ? qsTr("Trakt is unavailable · showing saved titles") : library.history ? qsTr("Recently watched") : ""
        color: Theme.fg3
        font { family: Theme.text; pixelSize: 23 * library.u }
    }
    // off the grid (the tabs) the wheel still moves it
    function wheelScroll(w) { gridWheel.scroll(w) }
    ListWheel { id: gridWheel; view: grid; cards: true }
    GridView {
        id: grid
        x: Theme.margin - 20 * library.u; y: 380 * library.u
        width: parent.width - 2 * x
        height: parent.height - y - 40 * library.u
        cellWidth: library.history ? 440 * library.u : 254 * library.u
        cellHeight: library.history ? 370 * library.u : 380 * library.u
        clip: true
        // a count: cards read their item by index, the view isn't rebuilt from a copied array
        model: library.items.length
        keyNavigationEnabled: true
        cacheBuffer: height
        delegate: Item {
            required property int index
            readonly property var modelData: library.items[index] || ({})
            width: grid.cellWidth; height: grid.cellHeight
            Card {
                id: card
                x: 20 * library.u; y: 20 * library.u
                media: modelData
                style: library.history ? "landscape" : "poster"
                focused: parent.GridView.isCurrentItem && (grid.activeFocus || library.menuItem === modelData)
            }
        }
        Keys.onUpPressed: function (e) {
            if (currentIndex < Math.floor(width / cellWidth)) (library.history ? historyTab : library.files ? filesTab : watchlist).forceActiveFocus()
            else moveCurrentIndexUp()
        }
        Keys.onReturnPressed: if (currentIndex >= 0) library.open(library.items[currentIndex])
        Keys.onEnterPressed: if (currentIndex >= 0) library.open(library.items[currentIndex])
        Keys.onMenuPressed: function (event) {
            if (!currentItem || library.files) { event.accepted = false; return }
            var w = library.history ? 400 * library.u : 214 * library.u
            var h = library.history ? w * 9 / 16 : w * 1.5
            var p = currentItem.mapToItem(null, 20 * library.u - w * 0.05, 20 * library.u - h * 0.05)
            library.menu(library.items[currentIndex], "library", Qt.rect(p.x, p.y, w * 1.1, h * 1.1))
        }
    }
    // loading with nothing to show yet: placeholder cards where the grid will be
    Item {
        id: placeholders
        anchors.fill: grid
        clip: true
        visible: opacity > 0
        opacity: library.busy && library.items.length === 0 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        readonly property int cols: Math.max(1, Math.floor(width / grid.cellWidth))
        Repeater {
            model: placeholders.cols * Math.ceil(placeholders.height / grid.cellHeight)
            Skeleton {
                required property int index
                x: (index % placeholders.cols) * grid.cellWidth + 20 * library.u
                y: Math.floor(index / placeholders.cols) * grid.cellHeight + 20 * library.u
                style: library.history ? "landscape" : "poster"
                cardW: (library.history ? 400 : 214) * library.u
            }
        }
    }
    Column {
        visible: library.items.length === 0 && !library.busy
        anchors { horizontalCenter: parent.horizontalCenter; top: grid.top; topMargin: 100 * library.u }
        spacing: 28 * library.u
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: library.failed ? qsTr("Couldn't load Library")
                : library.history ? qsTr("Your watched movies and episodes will appear here")
                : library.files ? (Theme.android ? qsTr("No videos from this device yet") : qsTr("No videos from this PC yet")) : qsTr("Save something for later")
            color: Theme.fg2
            font { family: Theme.display; pixelSize: 32 * library.u; weight: Font.Medium }
        }
        Text {
            visible: !library.failed && !library.history
            anchors.horizontalCenter: parent.horizontalCenter
            text: library.files ? qsTr("Add the folders your movies and shows are in: Settings › Sources") : qsTr("Open a title's options and choose Add to Library")
            color: Theme.fg3
            font { family: Theme.text; pixelSize: 24 * library.u }
        }
        GlassButton {
            id: retry
            visible: library.failed
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Try again")
            onClicked: library.load()
            Keys.onUpPressed: (library.history ? historyTab : library.files ? filesTab : watchlist).forceActiveFocus()
        }
    }
    KeyHint {
        anchors { right: parent.right; rightMargin: Theme.margin; top: parent.top; topMargin: 190 * library.u }
        visible: grid.activeFocus && library.items.length > 0
        key: "MENU"; label: qsTr("Options"); pad: Remote.inputKind === "pad"; u: library.u * 0.82
    }
}
