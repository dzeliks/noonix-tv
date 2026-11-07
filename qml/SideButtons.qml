import QtQuick

// a dialog's buttons, last in its card: under it, or where the screen has no room for that (phones)
// smaller on the card's right, lined up with its bottom. the card moves left by `shift` to make room
Item {
    id: sb
    property Item card                   // the box the buttons belong to (its bottom is theirs on the side)
    property real u: Theme.u
    property int align: Qt.AlignHCenter
    property real spacing: 20 * u
    property real topPad: 0
    property real gap: 30 * u
    property real extra: 0               // room the card gives up with them (a spacer above them)
    property real inset: 0               // their bottom this far above the card's (a card without padding)
    default property alias buttons: grid.data
    // set after the layout settles: the card's height follows it (a binding would loop)
    property bool side: false
    function fit() {
        if (!card || !card.parent || !Theme.short) { side = false; return }
        // the card as it would be with the buttons under it, against the screen
        var full = side ? card.height + topPad + 76 * u + extra : card.height
        side = full > card.parent.height - 2 * 72 * u
    }
    Connections { target: sb.card; function onHeightChanged() { Qt.callLater(sb.fit) } }
    Connections { target: sb.card ? sb.card.parent : null; function onHeightChanged() { Qt.callLater(sb.fit) } }
    Component.onCompleted: Qt.callLater(fit)
    readonly property real bu: u * 0.85
    readonly property real sideW: {
        var w = 0
        // (visible is false for all while the dialog is hidden)
        for (var i = 0; i < grid.children.length; ++i) w = Math.max(w, grid.children[i].implicitWidth)
        return w
    }
    readonly property real shift: side ? (sideW + gap) / 2 : 0
    // a button's size: as the dialog has it, or the side's
    function w(x) { return side ? sideW : x }

    width: parent ? parent.width : 0
    // (1, not 0: the column doesn't draw what has no height)
    height: side ? 1 : grid.height + topPad

    // set outright: children written here would go to the default property (the grid itself)
    children: [ Grid {
        id: grid
        columns: sb.side ? 1 : 99
        spacing: sb.side ? 16 * sb.u : sb.spacing
        // the deps first: mapFromItem alone doesn't follow the layout
        x: sb.side ? (sb.y, sb.parent.x, sb.card.width, sb.mapFromItem(sb.card, sb.card.width, 0).x + sb.gap)
           : sb.align === Qt.AlignRight ? sb.width - width : sb.align === Qt.AlignLeft ? 0 : (sb.width - width) / 2
        y: sb.side ? (sb.y, sb.parent.y, sb.card.height, sb.mapFromItem(sb.card, 0, sb.card.height).y - sb.inset - height) : sb.topPad
    } ]
}
