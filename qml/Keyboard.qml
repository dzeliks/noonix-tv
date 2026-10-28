// on-screen keyboard for search: the tv terminal's ios glass keyboard without the
// terminal row (no esc / ctrl / ^c). the parent sends remote keys with key(button) and
// listens to typed(text), special(name) (backspace, enter, clear) and leave(direction, x)
import QtQuick

Item {
    id: kb
    property real u: 1
    property bool active: true                 // the remote's focus is in here
    property bool accessory: false
    property string page: "abc"
    property bool shift: false
    property bool caps: false
    property int row: 2
    property int col: 4                        // starts on "g"

    readonly property real pad: 22 * u
    readonly property real gap: 14 * u
    readonly property real unit: (width - 2 * pad - 9 * gap) / 10
    readonly property real keyH: unit * 1.36   // iPhone keys: taller than wide
    readonly property real accH: unit * 0.92
    implicitWidth: 1150 * u
    implicitHeight: 2 * pad + (accessory ? accH + gap : 0) + 4 * keyH + 3 * gap

    property string enterLabel: "return"     // what enter does here: search, done...
    signal typed(string text)
    signal special(string name)
    signal leave(string direction, real x)
    signal pointed()                       // the mouse is on a key: the parent moves its focus here

    // key: { t: label, w: width in units, k: c (character) | f (function) | gap, v: value, s: symbol }
    function c(ch, w) { return { t: ch, w: w || 1, k: "c", v: ch } }
    function f(label, w, v, sym) { return { t: label, w: w, k: "f", v: v, s: sym || "" } }
    function g(w) { return { t: "", w: w, k: "gap" } }
    function chars(s) { return s.split(" ").map(function (x) { return c(x) }) }
    readonly property var pages: ({
        "abc": [
            chars("q w e r t y u i o p"),
            [g(0.5)].concat(chars("a s d f g h j k l")).concat([g(0.5)]),
            [f("", 1.5, "shift", "shift")].concat(chars("z x c v b n m")).concat([f("", 1.5, "backspace", "backspace")]),
            [f("123", 1.5, "page:123"), f("space", 4.5, "space"), f("clear", 1.5, "clear"), f(enterLabel, 2.5, "enter")]
        ],
        "123": [
            chars("1 2 3 4 5 6 7 8 9 0"),
            chars("- / : ; ( ) $ & @ \""),
            [f("#+=", 1.5, "page:sym")].concat(chars(". , ? ! ' | ~")).concat([f("", 1.5, "backspace", "backspace")]),
            [f("ABC", 1.5, "page:abc"), f("space", 4.5, "space"), f("clear", 1.5, "clear"), f(enterLabel, 2.5, "enter")]
        ],
        "sym": [
            chars("[ ] { } # % ^ * + ="),
            chars("_ \\ < > & ` $ ~ : \""),
            [f("123", 1.5, "page:123")].concat(chars(". , ? ! ' @ %")).concat([f("", 1.5, "backspace", "backspace")]),
            [f("ABC", 1.5, "page:abc"), f("space", 4.5, "space"), f("clear", 1.5, "clear"), f(enterLabel, 2.5, "enter")]
        ]
    })
    readonly property var rows: pages[page]
    readonly property bool upper: shift || caps

    function rowY(r) {
        return pad + (accessory && r > 0 ? accH + gap + (r - 1) * (keyH + gap) : r * (keyH + gap))
    }
    function rowH(r) { return accessory && r === 0 ? accH : keyH }
    // keys of a row that take focus (not the spacers), with their centre x in units
    function keysOf(r) {
        var out = [], x = 0, l = rows[r]
        for (var i = 0; i < l.length; ++i) {
            if (l[i].k !== "gap") out.push({ i: i, cx: x + l[i].w / 2 })
            x += l[i].w
        }
        return out
    }
    function focusIndex() {
        var ks = keysOf(row)
        return ks[Math.min(col, ks.length - 1)].i
    }
    function centreX() {
        var ks = keysOf(row)
        return ks[Math.min(col, ks.length - 1)].cx
    }
    function nearestIn(r, cx) {
        var ks = keysOf(r), best = 0
        for (var i = 1; i < ks.length; ++i)
            if (Math.abs(ks[i].cx - cx) < Math.abs(ks[best].cx - cx)) best = i
        return best
    }
    // the focus comes in from outside: side = the edge it crosses, fraction = where along it
    function enterAt(side, fraction) {
        if (side === "top" || side === "bottom") {
            row = side === "top" ? 0 : rows.length - 1
            col = nearestIn(row, fraction * 10)
        } else {
            row = Math.max(0, Math.min(rows.length - 1, Math.floor(fraction * rows.length)))
            col = side === "left" ? 0 : keysOf(row).length - 1
        }
    }

    // up / down / left / right / ok -> true when handled
    function key(button) {
        var n = keysOf(row).length
        if (button === "LEFT") {
            if (col > 0) --col
            else leave("left", (row + 0.5) / rows.length)
            return true
        }
        if (button === "RIGHT") {
            if (col < n - 1) ++col
            else leave("right", (row + 0.5) / rows.length)
            return true
        }
        if (button === "UP" || button === "DOWN") {
            var r = row + (button === "UP" ? -1 : 1)
            if (r < 0 || r >= rows.length) { leave(button === "UP" ? "up" : "down", centreX() / 10); return true }
            col = nearestIn(r, centreX())
            row = r
            return true
        }
        if (button === "OK") { press(rows[row][focusIndex()]); return true }
        return false
    }

    function pointAt(r, i) {
        row = r
        col = Math.max(0, keysOf(r).findIndex(function (x) { return x.i === i }))
        pointed()
    }

    function press(k) {
        var item = rowRep.itemAt(row) ? rowRep.itemAt(row).keyAt(focusIndex()) : null
        if (item) item.pop()
        if (k.k === "c") {
            typed(upper ? k.v.toUpperCase() : k.v)
            if (shift) shift = false
            return
        }
        var v = k.v
        if (v.indexOf("page:") === 0) { page = v.slice(5); col = Math.min(col, keysOf(row).length - 1); return }
        if (v === "shift") {
            if (caps) { caps = false; shift = false }
            else if (shift) { caps = true; shift = false }
            else shift = true
            return
        }
        if (v === "space") { typed(" "); return }
        special(v)
    }

    // the glass the keys sit on
    Rectangle {
        anchors.fill: parent
        radius: 48 * kb.u
        color: Qt.rgba(1, 1, 1, 0.055)
        border.width: 2 * kb.u
        border.color: Qt.rgba(1, 1, 1, 0.10)
    }

    Repeater {
        id: rowRep
        model: kb.rows.length
        Item {
            id: rowItem
            readonly property int r: index
            readonly property var keys: kb.rows[index]
            readonly property bool acc: kb.accessory && index === 0
            x: kb.pad
            y: kb.rowY(index)
            width: kb.width - 2 * kb.pad; height: kb.rowH(index)
            function keyAt(i) { return keyRep.itemAt(i) }
            Repeater {
                id: keyRep
                model: rowItem.keys
                KeyCap {
                    readonly property var spec: modelData
                    readonly property real start: {
                        var x = 0
                        for (var i = 0; i < index; ++i) x += rowItem.keys[i].w
                        return x
                    }
                    visible: spec.k !== "gap"
                    u: kb.u
                    x: start * (kb.unit + kb.gap)
                    width: spec.w * (kb.unit + kb.gap) - kb.gap
                    height: rowItem.height
                    radius: 20 * kb.u
                    z: focused ? 1 : 0
                    fn: spec.k === "f" || rowItem.acc
                    label: spec.k === "c" ? (kb.upper ? spec.t.toUpperCase() : spec.t) : spec.t
                    symbol: spec.v === "shift" ? (kb.caps ? "capslock" : kb.shift ? "shiftfill" : "shift") : (spec.s || "")
                    symbolSize: (rowItem.acc ? 40 : 46) * kb.u
                    lit: spec.v === "shift" && (kb.shift || kb.caps)
                    focused: kb.active && rowItem.r === kb.row && index === kb.focusIndex()
                    labelSize: spec.k === "c" ? (rowItem.acc ? 42 : 54) * kb.u : (spec.t.length > 3 ? 34 * kb.u : 38 * kb.u)
                    Pointer {
                        okKey: false
                        onPointed: kb.pointAt(rowItem.r, index)
                        onTapped: kb.press(spec)
                    }
                }
            }
        }
    }
}
