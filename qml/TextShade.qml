import QtQuick
import QtQuick.Effects

// a soft shade behind text over artwork (tv textshade.ts): each row of text a rounded bar its own length,
// a logo by its own shape, blurred together. fill the page with it and put it under the texts.
// a wrapped Text tells its rows: property var shadeRows: [] + onLineLaidOut: TextShade.row(shadeRows, line)
Item {
    id: shade
    property real strength: 0.32
    property var texts: []
    property var images: []
    readonly property real u: Theme.u
    readonly property real padX: 18 * u
    readonly property real padY: 6 * u
    readonly property real edge: padX + 70 * u

    // a wrapped text's row, from its onLineLaidOut
    function row(rows, line) {
        if (line.number === 0) rows.length = 0
        rows.push({ x: line.x, y: line.y, w: line.implicitWidth, h: line.height })
    }

    // what moves or changes the texts: drawn again
    readonly property string watch: texts.map(function (t) {
        return !t ? "" : [t.text, t.visible, t.opacity > 0, t.width, t.contentWidth, t.contentHeight, t.x, t.y,
                          t.parent ? t.parent.x : 0, t.parent ? t.parent.y : 0].join("|")
    }).join("#") + images.map(function (i) { return !i ? "" : [i.visible, i.width, i.height, i.x, i.y].join("|") }).join("#")
    onWatchChanged: again.restart()
    Component.onCompleted: again.restart()
    Timer { id: again; interval: 0; onTriggered: shade.collect() }

    property var bars: []
    property rect box: Qt.rect(0, 0, 0, 0)

    function clipOf(t) {
        for (var p = t.parent; p && p !== shade.parent; p = p.parent)
            if (p.clip) return p.mapToItem(shade, 0, 0, p.width, p.height)
        return null
    }

    function collect() {
        var out = []
        for (var i = 0; i < texts.length; i++) {
            var t = texts[i]
            if (!t || !t.visible || t.opacity <= 0 || t.text === "") continue
            var rows = t.shadeRows && t.shadeRows.length && t.lineCount > 1 ? t.shadeRows : null
            if (!rows) {
                var cw = Math.min(t.contentWidth, t.width)
                var x = t.horizontalAlignment === Text.AlignRight ? t.width - cw : t.horizontalAlignment === Text.AlignHCenter ? (t.width - cw) / 2 : 0
                rows = [{ x: x, y: 0, w: cw, h: t.contentHeight }]
            }
            var c = clipOf(t)
            for (var k = 0; k < rows.length; k++) {
                var p = t.mapToItem(shade, rows[k].x, rows[k].y)
                var r = { x: p.x, y: p.y, w: Math.min(rows[k].w, t.width), h: rows[k].h }
                if (c) {
                    var x0 = Math.max(r.x, c.x), x1 = Math.min(r.x + r.w, c.x + c.width)
                    var y0 = Math.max(r.y, c.y), y1 = Math.min(r.y + r.h, c.y + c.height)
                    // a row mostly cut off (past the clip) isn't seen
                    if (x1 - x0 < 1 || y1 - y0 < r.h / 2) continue
                    r = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
                }
                if (r.w > 1) out.push(r)
            }
        }
        var all = out.slice()
        for (var j = 0; j < images.length; j++) {
            var im = images[j]
            if (!im || !im.visible || im.width <= 0) continue
            var q = im.mapToItem(shade, 0, 0)
            all.push({ x: q.x, y: q.y, w: im.width, h: im.height })
        }
        if (!all.length) { bars = []; box = Qt.rect(0, 0, 0, 0); return }
        var bx0 = Infinity, by0 = Infinity, bx1 = -Infinity, by1 = -Infinity
        all.forEach(function (r) { bx0 = Math.min(bx0, r.x); by0 = Math.min(by0, r.y); bx1 = Math.max(bx1, r.x + r.w); by1 = Math.max(by1, r.y + r.h) })
        box = Qt.rect(bx0 - edge, by0 - edge, bx1 - bx0 + 2 * edge, by1 - by0 + 2 * edge)
        bars = out
    }

    // the bars and the logos' shapes, black, then blurred together (the effect's opacity is the strength)
    Item {
        id: src
        x: shade.box.x
        y: shade.box.y
        width: Math.max(1, shade.box.width)
        height: Math.max(1, shade.box.height)
        visible: false
        Repeater {
            model: shade.bars
            Rectangle {
                required property var modelData
                x: modelData.x - shade.padX - src.x
                y: modelData.y - shade.padY - src.y
                width: modelData.w + 2 * shade.padX
                height: modelData.h + 2 * shade.padY
                radius: height / 2
                color: "black"
            }
        }
        // a logo a little thicker than it's drawn: thin letters still get some shade
        Repeater {
            model: shade.images.length ? [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]] : []
            ShaderEffectSource {
                required property var modelData
                readonly property var im: shade.images[0]
                readonly property point at: im ? im.mapToItem(shade, 0, 0) : Qt.point(0, 0)
                x: at.x - src.x + modelData[0] * shade.padY
                y: at.y - src.y + modelData[1] * shade.padY
                width: im ? im.width : 0
                height: im ? im.height : 0
                sourceItem: im && im.visible ? im : null
                hideSource: false
            }
        }
    }
    MultiEffect {
        source: src
        x: src.x
        y: src.y
        width: src.width
        height: src.height
        visible: shade.box.width > 0
        opacity: shade.strength
        colorization: 1.0
        colorizationColor: "black"
        brightness: -1.0
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        autoPaddingEnabled: false
    }
}
