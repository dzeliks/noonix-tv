import QtQuick

// the floor under a sheet: the mouse stops here, nothing behind it hovers or clicks. outside() is a
// left click or a tap on it that isn't on the sheet itself (any smaller item beside it); right click
// stays back (Main's handler), or it would close twice
MouseArea {
    id: shield
    signal outside()
    signal rightClick()
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.AllButtons
    function onSheet(item, x, y) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (c === shield || !c.visible || c.opacity === 0) continue
            if (c.width >= shield.width - 1 && c.height >= shield.height - 1) { if (onSheet(c, x, y)) return true; continue }
            var p = shield.mapToItem(c, x, y)
            if (p.x >= 0 && p.y >= 0 && p.x <= c.width && p.y <= c.height) return true
        }
        return false
    }
    onClicked: function (m) {
        if (m.button === Qt.RightButton) rightClick()
        else if (m.button === Qt.LeftButton && !onSheet(shield.parent, m.x, m.y)) outside()
    }
}
